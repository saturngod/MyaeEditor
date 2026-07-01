# MyaeEditor

A native macOS block editor made with SwiftUI. You write in
blocks — headings, lists, to-dos, tables, code, math — and save the file as
Markdown.

![](./screenshot.png)

## Features

- **Block-based editing** — paragraphs, H1–H3 headings, bullet / numbered /
  to-do lists, quotes, dividers.
- **Slash menu** — type `/` to add any block type.
- **Floating format bar** — select text to make it bold, italic, strikethrough,
  or inline code.
- **Code blocks** — syntax highlighting for Swift, Python, JavaScript,
  TypeScript, JSON, HTML, CSS, Shell, Go, Rust, C, C++, Java, Ruby, SQL, YAML.
- **Tables** — add or remove rows and columns with a right-click menu on each
  cell.
- **Math** — inline math and math blocks (rendered like LaTeX).
- **Images** — add images as blocks.
- **Drag to reorder** — grab a block and move it; select many blocks at once
  by dragging over them.
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

## Architecture

This app uses SwiftUI **MV (Model-View)** style — there are no ViewModels.
`@Observable` model classes hold all the data, and views read that data
directly through `@State`. Simple logic that doesn't need state (like
converting Markdown, or coloring code) lives in `Services/`.

```
MyaeEditor/
├── App/        MyaeEditorApp.swift          App entry + menu commands
├── Models/     Models.swift                    @Observable: Block, TableData, EditorDocument
├── Services/   MarkdownCodec.swift             Markdown <-> blocks, document store
│               SyntaxHighlighter.swift         Tokenizer + code highlighting
└── Views/      ContentView, EditorView         Main editor surface
                BlockRowView, BlockTextView     Block rendering + text input (NSTextView)
                BlockActionMenu, SlashMenu      Block insertion / actions
                FormatBar                       Floating inline-format toolbar
                TableBlockView, ImageBlockView  Rich block types
                InlineMath                       Math editing + rendering
```

### Why MV, not MVVM

`Block`, `TableData`, and `EditorDocument` are `@Observable` classes. Views
hold them directly (`@State private var document: EditorDocument`). When you
change a model, the screen updates by itself — there is no `ObservableObject`,
no `@Published`, and no extra ViewModel layer in between. This keeps things
simple: models hold the data, views change it, services just do plain
calculations.

## How the Editor Works

The whole document is just an **ordered list of `Block` objects**, stored on
`EditorDocument`. `EditorView` shows that list and changes it — there is no
tree structure, just this one list. Everything below is built on top of these
two types.

### The `Block` object

A `Block` (in `Models/Models.swift`) is one line or element you can edit. It
is an `@Observable` class, so changing one field only redraws the parts of the
screen that show that field:

| Field       | Meaning                                             |
| ----------- | --------------------------------------------------- |
| `id`        | A unique `UUID` — used for lists, dragging, selection |
| `kind`      | The block type (paragraph, heading, list, code, …)  |
| `text`      | `NSAttributedString` — the styled text (bold/italic) |
| `checked`   | Whether a to-do box is checked                       |
| `depth`     | How indented the block is (0 = top level)            |
| `language`  | Code language, used for syntax highlighting          |
| `table`     | `TableData`, only used when `kind == .table`         |
| `imagePath` | Path to the image, only used when `kind == .image`   |

A block does **not** store its own position — its order just comes from its
place in `document.blocks`. This makes reordering easy.

### `EditorDocument` — where everything is stored

`EditorView` keeps one `@State private var document: EditorDocument`. This
document holds:

- `blocks: [Block]` — the list of content, in order.
- `focusedBlockID` / `focusAtStart` — which block has the cursor, and whether
  the cursor should go to the start (used after merging or deleting blocks).
- `selectedBlockIDs` — which whole blocks are selected (by dragging, or
  `⌘A`).
- `pendingCaretLocation` — a one-time request to put the cursor at an exact
  spot (used when Backspace joins two blocks together).
- `autosaveSignal` — waits about 2 seconds after your last edit, then saves.
  Every change calls `markEdited()`, which starts this timer.

Every edit goes through document methods like `insertBlock`,
`deleteAndFocusPrevious`, `mergeIntoPrevious`, `changeKind`, `duplicate`,
`indent`/`outdent`, and `move…`. Views always call these methods — they never
change the block list directly.

### Reordering blocks (drag and drop)

Reordering just moves items around in `document.blocks`, based on where you
drag:

1. Each visible row reports its position on screen (using SwiftUI's
   `RowFramePreference`), stored in `rowFrames: [UUID: CGRect]`. To save
   performance, this is only tracked while you are dragging or selecting.
2. While dragging, `reorder(toY:)` checks the other blocks and finds the
   first one whose middle is below your pointer — that spot becomes the drop
   location.
3. If the drop location hasn't changed, nothing happens (to avoid extra
   updates). Otherwise it calls `document.move(id:toIndexAmongOthers:)` with
   an animation.
4. `move(id:toIndexAmongOthers:)` takes the block out and puts it back in at
   the new spot. Since the list order *is* the display order, the screen
   updates automatically.

Because rows use a `LazyVStack`, only rows currently on screen have known
positions — you can only drop a block where you can see it (there's no
auto-scroll while dragging).

### Focus and cursor

Views don't fight over the cursor. When something changes, it sets
`focusedBlockID` (and sometimes `focusAtStart` or `pendingCaretLocation`).
`BlockTextView` watches these values and moves the real cursor. Example:
pressing Backspace at the start of a block joins it with the block above,
removes the empty block, and places the cursor exactly where the two blocks
met.

### Selecting whole blocks

Dragging across the left margin, or pressing `⌘A`, selects whole blocks (not
just text) and removes text focus. A key listener in `EditorView` then sends
Copy/Cut/Delete/Escape to these selected blocks — copying turns the selected
blocks into Markdown text using `MarkdownCodec`.

You can also start a normal text selection and turn it into a block
selection: if you drag past the edge of the current block, it switches from
selecting characters to selecting whole blocks (like Notion). Dragging back
switches back to character selection, without losing your starting point.

### Popups

Each block row (`BlockRowView`) can show two small popup menus that appear
next to it and close when you click outside.

**The `/` menu (`SlashMenu`)** — used to add a new block type:

- Typing `/` on an empty-ish line opens this menu below the cursor.
- As you keep typing, the text after `/` filters the list live — even though
  your cursor stays in the block, not in the popup.
- You can filter by name, and use `↑`/`↓` to move, `Return` to pick, and
  `Esc` to cancel. The list wraps around at the top/bottom.
- Picking an item removes the `/query` text and turns the block into that
  type. Each row shows an icon, a name, and a short description.

**The block action menu (`BlockActionMenu`)** — used to act on a block that
already exists:

- Hover over a row to see a drag handle (`=`). **Click** it to open this
  menu; **drag** it to reorder the block.
- It's a searchable list of actions: **"Turn into"** (change the block type),
  **Duplicate**, and **Delete**.
- It changes based on block type — for example, a table block also shows
  toggles for a header row or header column.
- Typing in the search box filters the list.

Both popups look the same (frosted background, rounded corners, soft shadow)
and put the cursor in the search box automatically when opened.

### Saving files

`MarkdownCodec.encode` turns `document.blocks` into a Markdown file.
`MarkdownCodec.decode` turns a Markdown file back into blocks. Autosave only
writes to the `.md` file when the content has actually changed.

### Windows and opening files

The New and Open menu actions are handled in `FileCommands`
(`App/MyaeEditorApp.swift`). They work even when there is **no window open**
(for example, right after you close the last window):

- **New** opens a new window.
- **Open** shows the file picker first. If a window is already open, the file
  loads into it. If not, a new window opens and the file loads there.
- The Open picker only shows `.md` files.
- If you pick a file before any window exists, the file path is remembered in
  `LaunchIntent.pendingOpenURL` until a new window opens and loads it.

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

## Tests

- `MyaeEditorTests/` — unit tests
- `MyaeEditorUITests/` — UI tests

## License

MIT — see [LICENSE](LICENSE).
