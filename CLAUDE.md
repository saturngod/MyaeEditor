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
swift test
```

Run a single test:
```bash
swift test --filter MarkdownCodecTests
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

## Line height & cursor centering

Vertical centering of text **and the caret** is done with geometry, not text attributes: `Views/CenteringLayoutManager.swift` (TextKit 1, `NSLayoutManagerDelegate` on itself).

- `shouldSetLineFragmentRect` forces every line fragment to a fixed height — `BlockTextView.lineHeightMultiple(for:) × defaultLineHeight(baseFont)` per paragraph kind (read from the `.paragraphKind` attribute) — and sets `baselineOffset` so the base font's ascender→descender box is centered in the fragment. AppKit derives the insertion point from that reported baseline, so the caret centers for free.
- Height always comes from the kind's **base font**, never the rendered fonts — Myanmar/CJK fallback fonts can't change line height or move the caret.
- `setExtraLineFragmentRect` override fixes the empty last line.
- Lines containing attachments (inline math) are left to default layout (`return false`) so they aren't clipped.
- Views whose storage has no `.paragraphKind` (table cells, code widget) set `overrideFont`/`overrideMultiple` on the layout manager instead.
- It is installed with `tv.textContainer?.replaceLayoutManager(CenteringLayoutManager())` **before** any storage swap, in three places: `SegmentTextView.makeNSView`, `TableCellTextView.makeNSView`, `CodeSegmentEditor.makeNSView`. Any new NSTextView-based editor surface must do the same.
- Do NOT reintroduce `.baselineOffset` attributes or `lineSpacing` for centering — marker drawing (`SegmentNSTextView.drawMarkers`) assumes the fixed-fragment geometry and reads `BlockTextView.centeringShift(for:)` = `(fixedHeight − fontLineHeight)/2` to align bullets/numbers/checkboxes; strikethrough and the quote bar use the used rect's `midY`/full height directly.

## Conventions & gotchas

- Package builds in **Swift 5 language mode** with `defaultIsolation(MainActor.self)` — most types are implicitly main-actor isolated.
- Requires macOS 15+ (package) / macOS 26.5+ (app README). Uses Xcode synchronized project folders.
- Mermaid renders in a WKWebView. It hangs on `requestAnimationFrame` when the web view is off-screen — use `setTimeout` instead for render kicks.
