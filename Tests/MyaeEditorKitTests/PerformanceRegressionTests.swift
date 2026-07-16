import AppKit
import Testing
@testable import MyaeEditorKit

@MainActor
struct PerformanceRegressionTests {
    @Test func codeStorageIsSharedWithCodec() {
        let segments = SegmentCodec.decode("```swift\nlet x = 1\n```")
        guard let code = segments.first?.codeText else {
            Issue.record("expected shared code storage")
            return
        }
        code.replaceCharacters(in: NSRange(location: 8, length: 1), with: "2")
        #expect(SegmentCodec.encode(segments).contains("let x = 2"))
    }

    @Test(arguments: [CodeLanguage.css, CodeLanguage.html])
    func incrementalHighlightMatchesFullPass(language: CodeLanguage) {
        let source = language == .css
            ? "body { color: red; }\n.item { margin: 10px; }\nfooter { opacity: 0.5; }"
            : "<main>hello</main>\n<div>world</div>\n<footer>done</footer>"
        let incremental = NSTextStorage(string: source)
        let full = NSTextStorage(string: source)
        let font = BlockKind.code.baseFont
        SyntaxHighlighter.highlight(incremental, language: language, font: font)
        SyntaxHighlighter.highlight(full, language: language, font: font)

        let edit = NSRange(location: (source as NSString).range(of: "world").location, length: 1)
        let safeEdit = edit.location == NSNotFound
            ? NSRange(location: (source as NSString).range(of: "margin").location, length: 1)
            : edit
        incremental.replaceCharacters(in: safeEdit, with: "X")
        full.replaceCharacters(in: safeEdit, with: "X")
        SyntaxHighlighter.highlight(incremental, language: language, font: font, editedRange: safeEdit)
        SyntaxHighlighter.highlight(full, language: language, font: font)

        #expect(incremental.length == full.length)
        for index in 0 ..< full.length {
            let lhs = incremental.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            let rhs = full.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            #expect(lhs == rhs)
        }
    }

    @Test func incrementalCSSInsideBlockCommentMatchesFullPass() {
        let source = "body { color: red; }\n/* comment starts\ninside comment\nends here */\n.item { margin: 2px; }"
        let incremental = NSTextStorage(string: source)
        let full = NSTextStorage(string: source)
        let font = BlockKind.code.baseFont
        SyntaxHighlighter.highlight(incremental, language: .css, font: font)
        let edit = NSRange(location: (source as NSString).range(of: "inside").location, length: 1)
        incremental.replaceCharacters(in: edit, with: "I")
        full.replaceCharacters(in: edit, with: "I")
        SyntaxHighlighter.highlight(incremental, language: .css, font: font, editedRange: edit)
        SyntaxHighlighter.highlight(full, language: .css, font: font)
        for index in 0 ..< full.length {
            let lhs = incremental.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            let rhs = full.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
            #expect(lhs == rhs)
        }
    }

    @Test func markerNumberingCacheRebuildsEditedSuffix() {
        let storage = SegmentCodec.decode("1. a\n2. b\n3. c").first!.textStorage!
        let view = SegmentNSTextView()
        view.layoutManager?.replaceTextStorage(storage)

        #expect(view.markerOrdinalForTesting(at: 0) == 1)
        #expect(view.markerOrdinalForTesting(at: 2) == 2)
        #expect(view.markerOrdinalForTesting(at: 4) == 3)

        let attrs = SegmentStyle.attributes(for: ParagraphKind(.numbered))
        storage.insert(NSAttributedString(string: "x\n", attributes: attrs), at: 0)
        view.invalidateMarkerCache(from: 0)

        #expect(view.markerOrdinalForTesting(at: 0) == 1)
        #expect(view.markerOrdinalForTesting(at: 2) == 2)
        #expect(view.markerOrdinalForTesting(at: 4) == 3)
        #expect(view.markerOrdinalForTesting(at: 6) == 4)
    }

    @Test func emptyListMarkerCacheFollowsCaret() {
        let attrs = SegmentStyle.attributes(for: ParagraphKind(.numbered))
        let storage = NSTextStorage(string: "a\n", attributes: attrs)
        let view = SegmentNSTextView()
        view.layoutManager?.replaceTextStorage(storage)
        view.typingAttributes = attrs
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        #expect(window.makeFirstResponder(view))

        view.setSelectedRange(NSRange(location: storage.length, length: 0))
        view.invalidateMarkerCacheForCaretMove(from: nil, to: storage.length)
        #expect(view.markerKindForTesting(at: storage.length) == .numbered)
        #expect(view.markerOrdinalForTesting(at: storage.length) == 2)

        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.invalidateMarkerCacheForCaretMove(from: storage.length, to: 0)
        #expect(view.markerKindForTesting(at: storage.length) == .paragraph)
    }

    @Test func settledBindingSnapshotDoesNotReencode() {
        let controller = MyaeEditorController(
            markdown: PerformanceFixtures.largeMarkdown(minimumBytes: 20_000)
        )
        var encodes = 0
        let target = ObjectIdentifier(controller.document.segments[0])
        SegmentCodec.encodeObserver = { segments in
            if let first = segments.first, ObjectIdentifier(first) == target { encodes += 1 }
        }
        defer { SegmentCodec.encodeObserver = nil }
        var snapshots = 0
        controller.onSettledMarkdown = { _ in snapshots += 1 }

        controller.settleEditsForTesting()

        #expect(snapshots == 1)
        #expect(encodes == 1)
    }

    @Test func fixturesAreDeterministic() {
        #expect(PerformanceFixtures.mixedList(paragraphs: 8)
            == PerformanceFixtures.mixedList(paragraphs: 8))
        #expect(PerformanceFixtures.code(language: "swift", characters: 1_000).count == 1_000)
        #expect(PerformanceFixtures.table(rows: 10, columns: 4).count == 10)
    }

    @Test func imageLoaderDownsamplesAndRejectsInvalidFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyaeEditorImageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = NSImage(size: NSSize(width: 800, height: 600))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 600).fill()
        image.unlockFocus()
        let pngURL = directory.appendingPathComponent("large.png")
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        try png.write(to: pngURL)

        await ImageLoader.shared.removeAll()
        let loaded = await ImageLoader.shared.image(for: pngURL, maxPixelSize: 100)
        let maxDimension = loaded?.representations.reduce(0) {
            max($0, max($1.pixelsWide, $1.pixelsHigh))
        }
        #expect(maxDimension != nil)
        #expect((maxDimension ?? .max) <= 100)

        let invalidURL = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalidURL)
        #expect(await ImageLoader.shared.image(for: invalidURL, maxPixelSize: 100) == nil)
    }

    @Test func mermaidCacheIsBoundedAndThemeAware() {
        MermaidRenderCache.removeAll()
        let light = MermaidRenderCache.Key(source: "graph TD; A-->B", theme: .light)
        let dark = MermaidRenderCache.Key(source: "graph TD; A-->B", theme: .dark)
        MermaidRenderCache.insert("<svg>light</svg>", for: light)
        MermaidRenderCache.insert("<svg>dark</svg>", for: dark)
        #expect(MermaidRenderCache.value(for: light) == "<svg>light</svg>")
        #expect(MermaidRenderCache.value(for: dark) == "<svg>dark</svg>")

        for index in 0 ..< 80 {
            let key = MermaidRenderCache.Key(source: "graph TD; A\(index)-->B", theme: .light)
            MermaidRenderCache.insert("<svg>\(index)</svg>", for: key)
        }
        #expect(MermaidRenderCache.count == 64)
        #expect(MermaidRenderCache.value(for: light) == nil)
    }

    @Test func largeTableFixtureEncodesWithoutLosingShape() {
        let cells = PerformanceFixtures.table()
        let segment = Segment(payload: .table(TableData(cells: cells)))
        let encoded = SegmentCodec.encode([segment])
        let lines = encoded.components(separatedBy: "\n")
        #expect(lines.count == 1_001) // 1,000 rows plus the GFM separator row
        #expect(lines.first?.contains("column") == false)
        #expect(lines.last?.contains("r999c19") == true)
    }
}
