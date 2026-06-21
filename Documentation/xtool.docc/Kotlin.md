# Use Kotlin Multiplatform

Build a SwiftUI app on top of shared Kotlin Multiplatform logic.

## Overview

Many iOS apps share their business logic with Android using [Kotlin Multiplatform](https://kotlinlang.org/docs/multiplatform.html) (KMP). The Kotlin shared module is compiled by Gradle into an **XCFramework**, which the iOS app consumes like any other binary dependency.

xtool can drive this end-to-end: it runs your Gradle build to (re)produce the XCFramework, stages it at a stable path, and then builds and signs your SwiftUI app the usual way — all from a single `xtool dev`. You write Swift; the Kotlin part just happens.

> Note: This guide assumes you already have an xtool-based application (see <doc:First-app>) and a Kotlin Multiplatform module that registers an XCFramework. Concurrency and interop ergonomics (Swift `async/await` for `suspend` functions, `Flow` → `AsyncSequence`, sealed-class enums) are handled on the Kotlin side by tools like [SKIE](https://skie.touchlab.co) — xtool consumes whatever framework they produce.

> Important: Compiling Kotlin/Native for iOS requires **macOS**. On Linux/Windows the iOS targets are silently skipped and no XCFramework is produced. On those hosts, commit or cache a prebuilt XCFramework and reference it directly (see [Consuming a prebuilt XCFramework](#Consuming-a-prebuilt-XCFramework)).

## Step 1: Register an XCFramework in Gradle

In your shared module's `build.gradle.kts`, register an `XCFramework` and add each iOS target's framework to it:

```kotlin
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

kotlin {
    val xcf = XCFramework("Shared")
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "Shared"
            isStatic = false   // dynamic framework, so xtool can embed + sign it
            xcf.add(this)
        }
    }
}
```

This creates the Gradle tasks `assembleSharedDebugXCFramework` and `assembleSharedReleaseXCFramework`, which write to `shared/build/XCFrameworks/<config>/Shared.xcframework`.

> Note: A plain `binaries.framework { }` block is **not** enough — without `XCFramework("...")` there is no assemble task. The name you pass (`"Shared"`) is the `framework` value you'll put in `xtool.yml`.

## Step 2: Configure xtool.yml

Add a `kotlin` block telling xtool which XCFramework to build:

```diff
  version: 1
  bundleID: com.example.Hello
+ kotlin:
+   framework: Shared      # the name from XCFramework("Shared")
+   module: shared         # gradle module (default: "shared")
+   projectDir: .          # where ./gradlew lives (default: ".")
```

Before each build, xtool runs `:shared:assembleShared<Config>XCFramework`, verifies the framework was produced, and copies it to a stable location: `xtool/kotlin/Shared.xcframework`.

## Step 3: Reference the XCFramework from Package.swift

Declare the staged XCFramework as a binary target and depend on it from your app target:

```diff
  let package = Package(
      name: "Hello",
      platforms: [.iOS(.v17)],
      products: [
          .library(name: "Hello", targets: ["Hello"]),
      ],
      targets: [
          .target(
              name: "Hello",
+             dependencies: ["Shared"]
          ),
+         .binaryTarget(
+             name: "Shared",
+             path: "xtool/kotlin/Shared.xcframework"
+         ),
      ]
  )
```

Because xtool always stages to the same path, this declaration never changes when you switch between debug and release. Now you can `import Shared` from Swift.

## Step 4: Build and run

```bash
xtool dev
```

xtool builds the Kotlin framework (via Gradle), stages it, then builds, signs, and installs your app — embedding `Shared.framework` into the app's `Frameworks/` directory automatically.

## Consuming a prebuilt XCFramework

If you can't build Kotlin on the current host (e.g. you're on Linux), omit the `kotlin` block from `xtool.yml` and point the binary target at a committed/cached XCFramework instead:

```swift
.binaryTarget(
    name: "Shared",
    path: "Frameworks/Shared.xcframework"
)
```

xtool treats this like any other SwiftPM binary target: it embeds and ad-hoc signs the framework when packing the app.
