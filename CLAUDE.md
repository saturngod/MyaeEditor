# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MyaeEditor is a native macOS block editor (SwiftUI + AppKit) that reads/writes Markdown. Most of the real code lives in a **local Swift Package `MyaeEditorKit`**; the app target (`MyaeEditor/`) is a thin shell around it. Any macOS app can `import MyaeEditorKit` and embed a `MyaeEditor` view.

## Commands

Build the app:
```bash
xcodebuild -project MyaeEditor.xcodeproj -scheme MyaeEditor -destination 'platform=macOS' build
```

Run the package tests (this is where real coverage lives):
```bash
cd MyaeEditorKit && swift test
```

Run a single test:
```bash
cd MyaeEditorKit && swift test --filter MarkdownCodecTests
```

Build a release `.dmg` (needs `brew install create-dmg`):
```bash
./build.sh              # -> MyaeEditor.dmg
./build.sh 1.2          # -> MyaeEditor-1.2.dmg
```

The app's own test targets (`MyaeEditorTests`, `MyaeEditorUITests`) are placeholders — `MyaeEditorTests/SmokeTests.swift` only asserts the target builds. Put new tests in `MyaeEditorKit/Tests/MyaeEditorKitTests/` and run with `swift test`.

## Architecture

The public API surface is exactly five types (everything else is `internal`):
- `MyaeEditor` — the SwiftUI editor view. Two forms: `MyaeEditor(controller:)` (app owns document state) and `MyaeEditor(markdown: $text)` (internal controller).
- `MyaeEditorController` (`@Observable`) — owns one document's state + all file I/O: open/save panels, explicit save, debounced autosave, dirty tracking. One controller = one view = one window. Has `onChange`/`onSave` callbacks.
- `MyaeEditorConfiguration` — feature flags + layout knobs (slash menu, format bar, drag reorder, mermaid, `isEditable`, content width). Passed to deep views via the `myaeConfiguration` `EnvironmentValues` entry — do not thread it through initializers manually.
- `MarkdownStore` + `AutosavePolicy` — autosave destination and policy (`.disabled` / `.default` / `.enabled(...)`).

Data model (`Models/Models.swift`, all `@Observable`): a document is an ordered list of `Block`s, each with a `BlockKind` (paragraph, heading1–3, bulleted, numbered, todo, quote, code, divider, table, image, equation). Note `BlockKind.inlineMath` is **not** a real block kind — it is only a slash-menu command that inserts an inline math attachment; never assign it to a block.

Markdown conversion is centralized in `Services/MarkdownCodec.swift` (blocks ↔ Markdown). `Services/SyntaxHighlighter.swift` tokenizes and highlights code blocks. When changing the block model, keep the codec round-trip stable — it is the covered contract (`MarkdownCodecTests`).

Views (`Views/`): `EditorView` is the document surface; `BlockRowView` renders one block and handles drag/multi-select; `BlockTextView` is the `NSTextView`-backed text input. Specialized block views: `TableBlockView`, `ImageBlockView`, `InlineMath`, `MermaidBlockView` (+ `MermaidWebView`, a WKWebView). Chrome: `SlashMenu`, `FormatBar`, `BlockActionMenu`.

## Conventions & gotchas

- Package builds in **Swift 5 language mode** with `defaultIsolation(MainActor.self)` — most types are implicitly main-actor isolated.
- Requires macOS 15+ (package) / macOS 26.5+ (app README). Uses Xcode synchronized project folders.
- Mermaid renders in a WKWebView. It hangs on `requestAnimationFrame` when the web view is off-screen — use `setTimeout` instead for render kicks.
