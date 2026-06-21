import Foundation
import Testing
@testable import PackLib

@Test func kotlinPlanAppliesDefaults() {
    let kotlin = PackSchemaBase.Kotlin(framework: "Shared", module: nil, projectDir: nil, task: nil)

    let debug = KotlinBuildPlan(kotlin: kotlin, configuration: .debug)
    #expect(debug.module == "shared")
    #expect(debug.projectDir == ".")
    #expect(debug.task == "assembleSharedDebugXCFramework")
    #expect(debug.gradleTask == ":shared:assembleSharedDebugXCFramework")
    #expect(debug.producedXCFrameworkPath == "shared/build/XCFrameworks/debug/Shared.xcframework")
    #expect(debug.stagedXCFrameworkPath == "xtool/kotlin/Shared.xcframework")

    let release = KotlinBuildPlan(kotlin: kotlin, configuration: .release)
    #expect(release.task == "assembleSharedReleaseXCFramework")
    #expect(release.gradleTask == ":shared:assembleSharedReleaseXCFramework")
    #expect(release.producedXCFrameworkPath == "shared/build/XCFrameworks/release/Shared.xcframework")
}

@Test func kotlinPlanHonorsOverrides() {
    let kotlin = PackSchemaBase.Kotlin(
        framework: "Core",
        module: "kmp",
        projectDir: "kotlin",
        task: "buildMyXCFramework"
    )
    let plan = KotlinBuildPlan(kotlin: kotlin, configuration: .release)
    #expect(plan.gradleTask == ":kmp:buildMyXCFramework")
    #expect(plan.producedXCFrameworkPath == "kmp/build/XCFrameworks/release/Core.xcframework")
    #expect(plan.stagedXCFrameworkPath == "xtool/kotlin/Core.xcframework")
}

@Test func kotlinSchemaDecodes() throws {
    // Validates that the `kotlin` block is wired into the schema model. Uses JSON
    // (Foundation) to avoid depending on a YAML decoder in the test target.
    let json = Data("""
    {
        "version": 1,
        "bundleID": "com.example.app",
        "kotlin": { "framework": "Shared", "module": "shared" }
    }
    """.utf8)
    let base = try JSONDecoder().decode(PackSchemaBase.self, from: json)
    let schema = try PackSchema(validating: base)
    #expect(schema.kotlin?.framework == "Shared")
    #expect(schema.kotlin?.module == "shared")
    #expect(schema.kotlin?.projectDir == nil)
}

@Test func kotlinAbsentByDefault() throws {
    let json = Data("""
    { "version": 1, "bundleID": "com.example.app" }
    """.utf8)
    let base = try JSONDecoder().decode(PackSchemaBase.self, from: json)
    #expect(base.kotlin == nil)
}
