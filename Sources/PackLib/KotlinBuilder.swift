import Foundation
import XUtils

/// Resolved parameters for building a Kotlin Multiplatform XCFramework via Gradle.
///
/// All defaults are applied here so the logic is pure and testable: given a
/// ``PackSchemaBase/Kotlin`` and a configuration, the Gradle task name and the
/// produced/staged paths are fully determined.
public struct KotlinBuildPlan: Sendable, Equatable {
    public var framework: String
    public var module: String
    public var projectDir: String
    public var configuration: BuildConfiguration
    public var task: String

    public init(kotlin: PackSchemaBase.Kotlin, configuration: BuildConfiguration) {
        self.framework = kotlin.framework
        self.module = kotlin.module ?? "shared"
        self.projectDir = kotlin.projectDir ?? "."
        self.configuration = configuration
        let raw = configuration.rawValue
        let capitalized = raw.prefix(1).uppercased() + raw.dropFirst()
        // e.g. assembleSharedReleaseXCFramework — see spike/kmp-sample for the
        // empirically-confirmed task naming.
        self.task = kotlin.task ?? "assemble\(framework)\(capitalized)XCFramework"
    }

    /// The fully-qualified Gradle task, e.g. `:shared:assembleSharedReleaseXCFramework`.
    public var gradleTask: String {
        ":\(module):\(task)"
    }

    /// Path, relative to ``projectDir``, where Gradle writes the XCFramework.
    public var producedXCFrameworkPath: String {
        "\(module)/build/XCFrameworks/\(configuration.rawValue)/\(framework).xcframework"
    }

    /// Stable, configuration-independent location that the SwiftPM binary target
    /// should reference. xtool stages the freshly-built XCFramework here so that
    /// `Package.swift` never has to change when switching debug/release.
    public var stagedXCFrameworkPath: String {
        "xtool/kotlin/\(framework).xcframework"
    }
}

/// Builds a Kotlin Multiplatform shared module into an XCFramework via Gradle,
/// then stages it at a stable path for SwiftPM to consume as a binary target.
public struct KotlinBuilder: Sendable {
    public let plan: KotlinBuildPlan

    public init(kotlin: PackSchemaBase.Kotlin, configuration: BuildConfiguration) {
        self.plan = KotlinBuildPlan(kotlin: kotlin, configuration: configuration)
    }

    public func run() async throws {
        let fm = FileManager.default
        let projectDir = URL(fileURLWithPath: plan.projectDir, isDirectory: true)

        try await checkPrerequisites()

        let (executable, leadingArgs) = try await locateGradle(projectDir: projectDir)

        print("Building Kotlin XCFramework '\(plan.framework)' (\(plan.configuration.rawValue))...")
        print("  \(executable.lastPathComponent) \(plan.gradleTask)")

        let process = Process()
        process.executableURL = executable
        process.arguments = leadingArgs + [plan.gradleTask]
        process.currentDirectoryURL = projectDir
        // Keep stdout clean for xtool; Gradle's chatter goes to stderr.
        process.standardOutput = FileHandle.standardError
        do {
            try await process.runUntilExit()
        } catch let failure as Process.Failure {
            throw StringError("""
            Gradle failed while building the Kotlin shared framework (\(failure)).
            Task: \(plan.gradleTask)
            In:   \(projectDir.path)
            """)
        }

        // Gradle reports BUILD SUCCESSFUL even when the iOS targets are silently
        // disabled (e.g. on a non-macOS host, Kotlin/Native iOS link tasks are
        // SKIPPED and no XCFramework is produced). The exit code is therefore not
        // enough — verify the artifact actually exists.
        let produced = projectDir.appendingPathComponent(plan.producedXCFrameworkPath)
        guard fm.fileExists(atPath: produced.path) else {
            throw StringError("""
            Gradle completed but did not produce an XCFramework at:
              \(produced.path)

            Common causes:
            - Kotlin/Native iOS targets can only be compiled on macOS. On Linux/Windows the \
            iOS link tasks are silently skipped and no XCFramework is produced. Build the \
            framework on a Mac, or commit/cache a prebuilt XCFramework and point a SwiftPM \
            binary target at it directly.
            - The 'framework' name in xtool.yml ('\(plan.framework)') does not match the name \
            registered via XCFramework("...") in your Gradle build.
            - The 'module' ('\(plan.module)') or 'task' is wrong. Run \
            './gradlew \(plan.module):tasks --all' to inspect the available XCFramework tasks.
            """)
        }

        // Stage to a stable, configuration-independent path. Replace any prior copy.
        let staged = URL(fileURLWithPath: plan.stagedXCFrameworkPath)
        try fm.createDirectory(
            at: staged.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: produced, to: staged)
        print("Staged \(plan.framework).xcframework -> \(staged.path)")
    }

    /// A friendly preflight (`doctor`-style) check for the Kotlin toolchain.
    private func checkPrerequisites() async throws {
        // Gradle needs a JDK. Surface a clear message rather than a cryptic
        // gradlew failure if neither `java` nor JAVA_HOME is available.
        let hasJavaHome = ProcessInfo.processInfo.environment["JAVA_HOME"]?.isEmpty == false
        if !hasJavaHome, (try? await ToolRegistry.locate("java")) == nil {
            throw StringError("""
            Building the Kotlin shared module requires a JDK, but no 'java' executable was \
            found in PATH and JAVA_HOME is not set. Install a JDK (17+) or set JAVA_HOME.
            """)
        }
    }

    private func locateGradle(projectDir: URL) async throws -> (URL, [String]) {
        #if os(Windows)
        let wrapperName = "gradlew.bat"
        #else
        let wrapperName = "gradlew"
        #endif

        let wrapper = projectDir.appendingPathComponent(wrapperName)
        if FileManager.default.isExecutableFile(atPath: wrapper.path) {
            return (wrapper, [])
        }

        // Fall back to a system-wide Gradle.
        if let gradle = try? await ToolRegistry.locate("gradle") {
            return (gradle, [])
        }

        throw StringError("""
        Could not find a Gradle wrapper at '\(wrapper.path)', nor a 'gradle' executable in PATH. \
        Add a Gradle wrapper to your Kotlin project (run `gradle wrapper`) or install Gradle.
        """)
    }
}
