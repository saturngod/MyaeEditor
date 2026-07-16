# Repository Guidelines

## Project Structure & Module Organization

MyaeEditor is a native macOS editor built with SwiftUI and AppKit. The reusable library is the root Swift package: production code lives in `Sources/MyaeEditorKit/`, grouped into `Models/`, `Services/`, and `Views/`; bundled Mermaid files live in `Sources/MyaeEditorKit/Resources/`. The thin application shell is under `MyaeEditor/App/`, with Xcode assets in `MyaeEditor/Assets.xcassets/`. Put substantive unit tests in `Tests/MyaeEditorKitTests/`. `MyaeEditorTests/` and `MyaeEditorUITests/` are app-target scaffolding. Packaging assets and the DMG background are in `AppIcon.icon/` and `resources/`.

## Build, Test, and Development Commands

- `open MyaeEditor.xcodeproj` opens the app for local development; run the **MyaeEditor** scheme with Command-R.
- `swift build` compiles the reusable package.
- `swift test` runs the primary package test suite.
- `swift test --filter SegmentCodecTests` runs one test type or matching test name.
- `xcodebuild -project MyaeEditor.xcodeproj -scheme MyaeEditor -destination 'platform=macOS' build` verifies the complete app target.
- `./build.sh [version]` creates a release DMG and requires `create-dmg` (`brew install create-dmg`).

## Coding Style & Naming Conventions

Use four-space indentation and follow standard Swift API naming: types in `UpperCamelCase`, methods and properties in `lowerCamelCase`. Keep one primary type per sensibly named file. The package uses Swift 5 language mode with main-actor default isolation; preserve actor boundaries and mark tests `@MainActor` when they exercise UI-backed models. Prefer SwiftUI's model-view approach already used here, and keep Markdown conversion in codec services rather than views. No repository-wide formatter is configured, so match surrounding code and Xcode formatting.

## Testing Guidelines

Tests use Swift Testing (`import Testing`, `@Test`, and `#expect`); UI scaffolding uses XCTest. Name tests after behavior, such as `headingsRoundTrip()` or `failedSaveReportsFailureAndStaysUnbound()`. Add regression coverage for every codec or controller change, especially Markdown encode/decode round trips. There is no stated coverage threshold, but `swift test` should pass before submission.

## Commit & Pull Request Guidelines

Recent commits use short, imperative summaries, sometimes with a conventional prefix such as `docs:`. Keep each commit focused; examples include `fix cursor on code block` and `docs: update package usage`. Pull requests should explain the user-visible change, identify tests run, and link relevant issues. Include screenshots or a short recording for editor layout, interaction, or rendering changes. Call out public API or Markdown compatibility changes explicitly.
