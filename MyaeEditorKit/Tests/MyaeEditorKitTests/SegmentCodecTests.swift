//
//  SegmentCodecTests.swift
//  MyaeEditorKitTests
//
//  Round-trip coverage for the continuous (segment) codec: text paragraphs, all
//  block kinds, links, and rendered widgets.
//

import Testing
import AppKit
@testable import MyaeEditorKit

@MainActor
struct SegmentCodecTests {

    /// encode(decode(md)) == md for a wide mix of constructs.
    private func roundTrips(_ md: String, _ sourceLocation: SourceLocation = #_sourceLocation) {
        let segments = SegmentCodec.decode(md)
        let out = SegmentCodec.encode(segments)
        #expect(out == md, "round-trip mismatch", sourceLocation: sourceLocation)
    }

    @Test func paragraphsRoundTrip() {
        roundTrips("Hello world")
        roundTrips("Line one\nLine two")
        roundTrips("Para one\n\nPara two")
    }

    @Test func headingsRoundTrip() {
        roundTrips("# H1\n## H2\n### H3\n#### H4\n##### H5\n###### H6")
    }

    @Test func listsRoundTrip() {
        roundTrips("- one\n- two\n- three")
        roundTrips("1. one\n2. two\n3. three")
        roundTrips("- [ ] todo\n- [x] done")
    }

    @Test func nestedNumberingRoundTrips() {
        // Mixed depths: counters reset per depth, continue across nesting.
        roundTrips("1. a\n2. b\n    1. b1\n    2. b2\n3. c")
    }

    @Test func quoteAndInlineRoundTrip() {
        roundTrips("> a quote")
        roundTrips("Some **bold** and *italic* and ~~strike~~ text")
        roundTrips("Inline `code` here")
    }

    @Test func linkRoundTrips() {
        roundTrips("A [link](https://example.com) inline")
        roundTrips("Bold **[link](https://example.com)** here")
    }

    @Test func linkDecodesToAttribute() {
        let segments = SegmentCodec.decode("see [docs](https://example.com/x)")
        guard let storage = segments.first?.textStorage else {
            Issue.record("expected a text segment"); return
        }
        var found: URL?
        storage.enumerateAttribute(.myaeLink, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let url = v as? URL { found = url }
        }
        #expect(found?.absoluteString == "https://example.com/x")
    }

    @Test func codeFenceRoundTrips() {
        roundTrips("```swift\nlet x = 1\nprint(x)\n```")
        roundTrips("```\nplain code\n```")
    }

    @Test func mermaidFenceRoundTrips() {
        let md = "```mermaid\ngraph TD\nA-->B\n```"
        let segments = SegmentCodec.decode(md)
        if case .code(let lang, _)? = segments.first?.payload {
            #expect(lang == .mermaid)
        } else {
            Issue.record("expected a code segment")
        }
        #expect(SegmentCodec.encode(segments) == md)
    }

    @Test func tableRoundTrips() {
        roundTrips("| a | b |\n| --- | --- |\n| 1 | 2 |")
        roundTrips("| left | center | right |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |")
    }

    @Test func imageAndEquationAndDividerRoundTrip() {
        roundTrips("![](images/pic.png)")
        roundTrips("$$E = mc^2$$")
        roundTrips("---")
    }

    @Test func mixedDocumentRoundTrips() {
        let md = """
        # Title

        Intro paragraph with **bold**.

        - one
        - two

        | a | b |
        | --- | --- |
        | 1 | 2 |

        ```swift
        let x = 1
        ```

        > a quote

        ![](pic.png)

        $$x^2$$

        Done.
        """
        roundTrips(md)
    }

    @Test func widgetsSplitTextSegments() {
        // A divider between two paragraphs yields text / divider / text.
        let segments = SegmentCodec.decode("before\n\n---\n\nafter")
        #expect(segments.count == 3)
        #expect(segments[0].isText)
        if case .divider = segments[1].payload {} else { Issue.record("expected divider") }
        #expect(segments[2].isText)
    }

    @Test func emptyInputYieldsOneTextSegment() {
        let segments = SegmentCodec.decode("")
        #expect(segments.count == 1)
        #expect(segments[0].isText)
    }

    /// Pasteboard text: CRLF/CR normalize to LF and trailing newlines are
    /// stripped (they'd otherwise decode into trailing empty paragraphs).
    @Test func decodeForPasteNormalizes() {
        let segments = SegmentCodec.decodeForPaste("a\r\nb\rc\n\n")
        #expect(segments.count == 1)
        #expect(segments[0].textStorage?.string == "a\nb\nc")
    }

    /// The single-pass numbered ordinals in encode: continuation, nesting,
    /// interruption, and restart after outdent.
    @Test func encodeNumberingRunsPerDepth() {
        let md = "1. a\n2. b\n    1. b1\n    2. b2\n3. c\nplain\n1. restart"
        #expect(SegmentCodec.encode(SegmentCodec.decode(md)) == md)
    }

    /// Inline code survives a round trip with the `.inlineCode` attribute.
    @Test func inlineCodeRoundTrips() {
        let segments = SegmentCodec.decode("before `code` after")
        guard let storage = segments.first?.textStorage else {
            Issue.record("expected a text segment"); return
        }
        var found = false
        storage.enumerateAttribute(.inlineCode, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if (v as? Bool) == true { found = true }
        }
        #expect(found)
        #expect(SegmentCodec.encode(segments) == "before `code` after")
    }

    /// A math attachment that also carries `.inlineCode` (e.g. the user selected
    /// across inline math and pressed Cmd+E) must still encode as `$latex$` — the
    /// math branch is checked before inline code so the latex is never dropped.
    @Test func mathWithInlineCodeEncodesAsLatex() {
        let s = NSMutableAttributedString(
            attributedString: InlineMath.attributedString(latex: "x^2", fontSize: 16, kind: .paragraph))
        s.addAttribute(.inlineCode, value: true, range: NSRange(location: 0, length: s.length))
        #expect(MarkdownCodec.inlineMarkdown(from: s, baseFont: BlockKind.paragraph.baseFont) == "$x^2$")
    }
}
