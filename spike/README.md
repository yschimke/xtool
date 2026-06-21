# Spike: Kotlin Multiplatform support for xtool

This directory holds the exploratory work behind xtool's Kotlin Multiplatform (KMP)
support. The goal: an iOS developer working on a *part-Kotlin* project (shared
business logic in Kotlin, SwiftUI on top — the architecture used by John O'Reilly's
[PeopleInSpace](https://github.com/joreilly/PeopleInSpace), Confetti, etc.) should
get a streamlined `xtool dev` experience, without hand-running Gradle or hand-wiring
binary targets.

## How KMP reaches an iOS app

Kotlin/Native compiles the shared module into an Apple **framework**, bundled as an
**XCFramework**. The decoupled, Xcode-free way to consume it is as a **SwiftPM binary
target** — which is exactly the shape xtool already understands (`Planner.swift`
detects `BinaryTarget`s; `Packer.swift` embeds and ad-hoc signs the `.framework`).

So a joreilly-style app is, to xtool, "a SwiftPM app with one binary-target
dependency." The work is removing the *workflow* friction (the dual Gradle+Swift
build, the manual wiring), not reinventing interop. Concurrency/interop ergonomics
(Swift `async/await` for `suspend`, `Flow` → `AsyncSequence`, sealed-class enums) are
solved upstream by [SKIE](https://skie.touchlab.co) / KMP-NativeCoroutines, which run
on the Gradle side and shape the framework; xtool just consumes the result.

## What this spike validated (live, on Linux)

`kmp-sample/` is a minimal real KMP module (coroutines + a `suspend` function) used
to empirically confirm the Gradle seam — `./gradlew :shared:tasks --all`:

1. **You must register an `XCFramework`.** A plain `binaries.framework { }` block
   produces only per-target `linkXxxFrameworkIosArm64` tasks and
   `embedAndSignAppleFrameworkForXcode` — **no** assemble task. Adding
   `XCFramework("Shared")` + `xcf.add(framework)` creates the assemble tasks.

2. **Task naming:** `assemble<Name><Config>XCFramework`, e.g.
   `assembleSharedReleaseXCFramework` / `assembleSharedDebugXCFramework`
   (plus the all-configs `assembleSharedXCFramework`).

3. **Output path:** `<module>/build/XCFrameworks/<config>/<Name>.xcframework`.

4. **Critical:** on a non-macOS host, `./gradlew :shared:assembleSharedDebugXCFramework`
   reports **`BUILD SUCCESSFUL`** but **SKIPs every iOS task** (warning: "Disabled
   Kotlin/Native Targets: iosArm64, iosSimulatorArm64") and produces **no**
   XCFramework. The Gradle exit code is therefore not trustworthy — xtool must verify
   the artifact exists after the build. (See `KotlinBuilder.run()`.)

## What the spike implemented in xtool

- **`kotlin` block in `xtool.yml`** (`PackSchema.swift`): `framework`, `module`,
  `projectDir`, `task`.
- **`KotlinBuilder` / `KotlinBuildPlan`** (`Sources/PackLib/KotlinBuilder.swift`):
  derives the Gradle task + paths (defaults applied, pure & unit-tested), runs the
  Gradle wrapper (falling back to system `gradle`), **verifies the artifact exists**
  (catching the silent-skip case with an actionable error), and **stages** it to a
  stable, config-independent path `xtool/kotlin/<Name>.xcframework` so `Package.swift`
  never changes between debug/release.
- **Wired into `PackOperation.run()`** (`DevCommand.swift`) so it runs before
  planning — Stage 1 (consume) rides on the existing binary-target packing; Stage 2
  (orchestrate Gradle) is the `KotlinBuilder` step.
- **Stage 4 doctor checks**: friendly errors when no JDK / no Gradle wrapper, and the
  macOS-requirement / wrong-name diagnostics above.
- Unit tests: `Tests/XToolTests/KotlinBuildPlanTests.swift`.
- Docs: `Documentation/xtool.docc/Kotlin.md`.

## What still needs macOS to validate (out of scope on this Linux host)

The one assumption this spike could **not** exercise end-to-end here (no Swift
toolchain; no macOS; Kotlin/Native can't build iOS frameworks off-Mac):

> When SwiftPM cross-builds with the Darwin Swift SDK (`--swift-sdk arm64-apple-ios`),
> does it correctly extract the right slice from an **`.xcframework`** binary target
> and place `<name>.framework` under `.build/<triple>/<config>/` where `Packer.swift`
> expects it — for both device and simulator?

That is the make-or-break check for the consume path and should be the first thing
verified on a Mac, using `kmp-sample` as the fixture.
