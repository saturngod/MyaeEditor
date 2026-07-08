# MyaeEditor

A native macOS **continuous** editor made with SwiftUI. You write in one
flowing document — headings, lists, to-dos, tables, code, math, diagrams — and
save the file as Markdown.

![](./screenshot.png)

## Features

- **Continuous WYSIWYG editing** — the whole document is one scrolling text
  surface, not discrete block rows. Headings, lists, to-dos, and quotes are
  just styled paragraphs you type straight into; press Enter to continue a
  list, Backspace at the start of a line to merge it into the one above.
- **Rich inline formatting** — bold, italic, strikethrough, inline code, and
  inline links, plus a floating format bar that appears over a selection.
- **Slash menu** — type `/` to insert a heading, list, to-do, quote, code
  block, table, image, divider, or equation.
- **Inline & block math** — type `/` for a display equation or insert inline
  math like `$E = mc^2$`, edited live in a popover (rendered like LaTeX).
- **Code blocks** — syntax highlighting for Swift, Python, JavaScript,
  TypeScript, JSON, HTML, CSS, Shell, Go, Rust, C, C++, C#, Java, Kotlin, PHP,
  Ruby, SQL, YAML.
- **Mermaid diagrams** — set a code block's language to Mermaid to render it
  live as a diagram, with a full-size zoomable/pannable viewer sheet.
- **Tables** — add or remove rows and columns, per-column alignment
  (left/center/right), with a right-click menu on each cell; wide tables break
  out of the text column instead of clipping.
- **Images** — insert images inline; relative paths are resolved against the
  Markdown file's folder.
- **Whole-document selection** — drag or `⌘A` to select multiple
  tables/images/code blocks/etc. at once, then copy/cut/delete/paste as
  Markdown.
- **Markdown files** — Open (`⌘O`), Save (`⌘S`), Save As Markdown (`⇧⌘S`).

## Requirements

- macOS 26.5 or newer
- Xcode 16 or newer (uses synchronized project folders)
- Swift 5

## Getting Started

```bash
open MyaeEditor.xcodeproj
```

Then build and run (`⌘R`) using the **MyaeEditor** scheme. Or run it from the
terminal:

```bash
xcodebuild -project MyaeEditor.xcodeproj -scheme MyaeEditor \
  -destination 'platform=macOS' build
```

## Using MyaeEditorKit as a Swift Package

The editor is distributed as a Swift Package at the **repository root** — the
`Package.swift` lives at the top level, not in a subfolder. You can embed it in
any macOS 15+ app and `import MyaeEditorKit` to use the `MyaeEditor` view.

### Add the package

**Xcode:** File → Add Package Dependencies → choose the `MyaeEditor` repo
folder (or its git URL) → add to your target.

**`Package.swift`** (if your app is itself a package):

```swift
dependencies: [
    .package(url: "https://github.com/saturngod/MyaeEditor.git", .branch("main"))
    // or, after a tagged release:
    // .package(url: "https://github.com/saturngod/MyaeEditor.git", .upToNextMajor(from: "0.1.0"))
    // local checkout:
    // .package(path: "../MyaeEditor")
],
targets: [
    .target(name: "YourApp", dependencies: ["MyaeEditorKit"])
]
```

> Requirements: macOS 15+ (package), Xcode 16+, Swift 5 language mode. The
> package bundles `mermaid.min.js` and its HTML resources, so Mermaid rendering
> works out of the box — no extra asset copying needed.

### Use the editor

```swift
import SwiftUI
import MyaeEditorKit

struct ContentView: View {
    // Full control: your app owns the document state + file I/O
    @State private var controller = MyaeEditorController(autosave: .default)

    // Simple: bind directly to a Markdown string (internal controller)
    @State private var text: String = "# Hello\n\nStart typing…"

    var body: some View {
        VStack {
            MyaeEditor(controller: controller)   // app-owned controller
            // or: MyaeEditor(markdown: $text)  // string binding
        }
        .onAppear {
            controller.onChange = { _ in print("Edited") }
            controller.onSave   = { url in print("Saved to \(url)") }
        }
    }
}
```

The package exports exactly five public types: `MyaeEditor`,
`MyaeEditorController`, `MyaeEditorConfiguration`, `MarkdownStore`, and
`AutosavePolicy`. Everything else is `internal`.

## Architecture

The editor is a **Swift Package** at the repository root (`Package.swift`),
imported by the app. This makes it reusable — any macOS app can
`import MyaeEditorKit` and embed a `MyaeEditor` view.

```
MyaeEditor/                    (app target)
├── App/
│   ├── MyaeEditorApp.swift    App entry + menu commands (File → New/Open/Save)
│   └── ContentView.swift      Window controller + restore policy
└── Assets.xcassets

Package.swift                   (Swift 5 / macOS 15+ — package at repo root)
Sources/MyaeEditorKit/
├── MyaeEditor.swift           ← PUBLIC: two-form editor view
├── MyaeEditorController.swift ← PUBLIC: document + file I/O
├── MyaeEditorConfiguration.swift ← PUBLIC: feature flags
├── MarkdownStore.swift        ← PUBLIC: autosave store
├── Models/Segments.swift      @Observable Segment (text run / widget), ParagraphKind
│        SegmentDocument.swift Ordered segment list + focus/selection state
│        Models.swift          BlockKind, TableData, ColumnAlignment (shared by segments)
├── Services/SegmentCodec.swift   Markdown ↔ segments (the real document codec)
│           MarkdownCodec.swift   Inline Markdown ↔ attributed text (bold/italic/links, table rows)
│           SegmentStyle.swift    Paragraph attribute → NSAttributedString styling
│           SyntaxHighlighter.swift Tokenizer + code highlighting
├── Views/SegmentEditorView       Continuous document surface + widget layout
│      SegmentTextView            Multi-paragraph text run (NSTextView-backed)
│      SegmentWidgets             Code/image/equation/divider widget views
│      BlockTextView              Shared AutoSizingTextView base (bold/italic/code toggles)
│      SlashMenu                  Block type picker
│      FormatBar                  Floating inline-format toolbar
│      TableBlockView, TableCellTextView, InlineMath
│      MermaidWebView, MermaidZoomView  Diagram rendering + zoom/pan viewer (WKWebView)
└── Resources/mermaid.html, mermaid-zoom.html, mermaid.min.js
Tests/MyaeEditorKitTests/
```

### Using MyaeEditorKit

```swift
import MyaeEditorKit

// 1. Full control: app owns the controller
@State var controller = MyaeEditorController(autosave: .default)
MyaeEditor(controller: controller)

// 2. Simple: Markdown binding (internal controller)
@State var text: String = ""
MyaeEditor(markdown: $text)

// 3. Callbacks
controller.onChange = { ctrl in print("Edited") }
controller.onSave = { url in print("Saved") }
```

The package exports five types: `MyaeEditor`, `MyaeEditorController`, `MyaeEditorConfiguration`, `MarkdownStore`, `AutosavePolicy`. Everything else is internal.

### Why MV, not MVVM

`Segment`, `SegmentDocument`, and `TableData` are `@Observable` classes. Views
hold them directly. When you change a model, the screen updates by itself —
there is no `ObservableObject`, no `@Published`, and no extra ViewModel layer
in between. This keeps things simple: models hold the data, views change it,
services just do plain calculations.

## How the Editor Works

The document is an ordered list of **`Segment`s**, stored on
`SegmentDocument`. Most of the document is one `Segment.text` case: a run of
paragraphs (paragraph/heading/list/todo/quote) fused into a single
`NSTextStorage` that a text view attaches to directly — the storage *is* the
model, so there is no separate per-line block to keep in sync. Non-text
content (code blocks, tables, images, equations, dividers) is a widget segment
sitting between text runs. `SegmentEditorView` renders the segment list top to
bottom; there is no tree structure.

### The `Segment` object

A `Segment` (in `Models/Segments.swift`) is one piece of the document:

| Payload case | Meaning |
| ------------ | ------- |
| `.text(NSTextStorage)` | A run of editable paragraphs — the only kind with a text view |
| `.code(language:text:)` | A fenced code block, including Mermaid (`language == .mermaid`) |
| `.table(TableData)` | A table widget |
| `.image(path:)` | An image widget |
| `.equation(latex:)` | A centered display equation (LaTeX source) |
| `.divider` | A horizontal rule |

Inside a text segment's storage, each paragraph carries a `.paragraphKind`
attribute (a `ParagraphKind`: `BlockKind` + list `depth` + todo `checked`
state), applied across the whole paragraph including its trailing newline so
typing at the end inherits it. `BlockKind` and table types (`TableData`,
`ColumnAlignment`) still live in `Models/Models.swift`, shared by both segment
kinds.

### `SegmentDocument` — where everything is stored

`SegmentEditorView` keeps one `@State private var document`, actually the
controller's internal `SegmentDocument`. It holds:

- `segments: [Segment]` — the document content, in order.
- `focusedSegmentID` / `focusAtStart` — which text (or code) segment has the
  cursor, and whether it should land at the start.
- `selectedSegmentIDs` — whole widget/segment selection (drag, or `⌘A`).
- `pendingCaretLocation` — a one-time request to put the cursor at an exact
  spot (used when a merge crosses a widget boundary).
- `didEdit` — a Combine signal the controller debounces for autosave/dirty
  tracking.

Structural edits — converting a fenced-code paragraph into a real code
segment, splicing pasted widgets into the middle of a text run, removing a
widget and rejoining the surrounding text, moving focus across a widget — all
go through `SegmentDocument` methods (`convertParagraphToCodeBlock`,
`spliceSegments`, `removeWidget`, `focusUp`/`focusDown`, `normalize`). A
`normalize()` pass keeps the invariants: no two adjacent text segments (they
get merged), and the document always has at least one text segment.

### Focus and cursor

Views don't fight over the cursor. `SegmentDocument` sets `focusedSegmentID`
(and sometimes `focusAtStart` or `pendingCaretLocation`); `SegmentTextView`
watches these and moves the real cursor. Arrow keys at the top/bottom edge of
a text run step focus into the nearest editable neighbor (skipping over
non-editable widgets, entering a table at its first/last row).

### Selecting whole segments

Dragging, or pressing `⌘A` with no text run focused, selects whole segments
(tables, images, code blocks, etc. as units) and removes text focus. A key
monitor in `SegmentEditorView` then routes Copy/Cut/Delete/Escape/Paste to the
selection — copying turns the selected segments into Markdown text using
`SegmentCodec`.

### Popups

**The `/` menu (`SlashMenu`)** — type `/` on an empty-ish line to open a
filterable list of block types below the cursor; `↑`/`↓` to move, `Return` to
pick, `Esc` to cancel. Picking an item removes the `/query` text and either
turns the current paragraph into that kind or inserts a widget segment.

**Inline math and link popovers** — double-click an inline math attachment or
a link to edit it in a small popover anchored to the click point.

**The floating format bar (`FormatBar`)** — appears above a non-empty text
selection in a borderless, non-activating panel so its buttons never steal
focus from the text view.

### Saving files

`SegmentCodec.encode` turns `document.segments` into a Markdown file.
`SegmentCodec.decode` turns a Markdown file back into segments (using
`MarkdownCodec` for inline-formatting and table-row parsing along the way).
Autosave only writes to the `.md` file when the content has actually changed.

### Windows and opening files

The New and Open menu actions are handled in `FileCommands`
(`App/MyaeEditorApp.swift`). They work even when there is **no window open**
(for example, right after you close the last window):

- **New** opens a new window.
- **Open** shows the file picker first. If a window is already open, the file
  loads into it. If not, a new window opens and the file loads there.
- The Open picker only shows `.md` files.
- If you pick a file before any window exists, the file path is remembered in
  `AppLaunchIntent.pendingOpenURL` until a new window opens and loads it.

## Keyboard Shortcuts

| Action                         | Shortcut |
| ------------------------------- | -------- |
| Open                           | `⌘O`     |
| Save                           | `⌘S`     |
| Save As Markdown               | `⇧⌘S`    |
| Insert block                   | `/`      |
| Bold (text selected)           | `⌘B`     |
| Italic (text selected)         | `⌘I`     |
| Inline code (text selected)    | `⌘E`     |
| Strikethrough (text selected)  | `⇧⌘S`    |
| Paste as plain text            | `⇧⌘V`    |

## Tests

- `Tests/MyaeEditorKitTests/` — package unit tests (`MyaeEditorControllerTests`, `SegmentCodecTests`)
- `MyaeEditorTests/` — app smoke tests
- `MyaeEditorUITests/` — UI tests

## License

MIT — see [LICENSE](LICENSE).
