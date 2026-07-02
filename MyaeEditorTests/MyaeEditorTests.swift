//
//  MyaeEditorTests.swift
//  MyaeEditorTests
//
//  Created by Bonjoy on 6/30/26.
//

import Testing
import AppKit
@testable import MyaeEditor

struct MyaeEditorTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    /// The single-pass numbering baked into `MarkdownCodec.encode` must match the
    /// original per-block `EditorDocument.number(for:)` for a mixed-depth list.
    @Test func encodeNumberingMatchesNumberFor() {
        func blk(_ kind: BlockKind, _ text: String, depth: Int = 0) -> Block {
            Block(kind: kind, text: NSAttributedString(string: text), depth: depth)
        }
        // A mixed list exercising: continuation, nested sublists, a bullet that
        // ends a run, a non-list block between items, and restart after outdent.
        let doc = EditorDocument(blocks: [
            blk(.numbered, "a"),
            blk(.numbered, "b"),
            blk(.numbered, "x", depth: 1),
            blk(.numbered, "y", depth: 1),
            blk(.numbered, "c"),
            blk(.bulleted, "bullet"),
            blk(.numbered, "d"),          // bullet ended the run -> restarts at 1
            blk(.paragraph, "note"),
            blk(.numbered, "e"),          // paragraph ended the run -> restarts at 1
        ])

        // Expected ordinals from the original backward-scan implementation.
        let expected = doc.blocks
            .filter { $0.kind == .numbered }
            .map { doc.number(for: $0) }

        // Ordinals as they appear in the encoded Markdown.
        let encoded = MarkdownCodec.encode(doc)
        let emitted = encoded
            .split(separator: "\n")
            .compactMap { line -> Int? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let dot = t.firstIndex(of: "."), let n = Int(t[..<dot]) else { return nil }
                return n
            }

        #expect(emitted == expected)
        #expect(expected == [1, 2, 1, 2, 3, 1, 1])
    }

    /// Inline code survives an encode → decode round trip: it emits backticks and
    /// decodes back into a run tagged with `.inlineCode`.
    @Test func inlineCodeRoundTrips() {
        let m = NSMutableAttributedString(
            string: "run code here",
            attributes: BlockTextView.typingAttributes(for: .paragraph))
        let codeRange = (m.string as NSString).range(of: "code")
        for (k, v) in InlineCode.attributes(size: 16, color: .textColor) {
            m.addAttribute(k, value: v, range: codeRange)
        }

        let md = MarkdownCodec.encode(EditorDocument(blocks: [Block(kind: .paragraph, text: m)]))
        #expect(md == "run `code` here")

        let text = MarkdownCodec.decode(md)[0].text
        let r = (text.string as NSString).range(of: "code")
        #expect(text.attribute(.inlineCode, at: r.location, effectiveRange: nil) as? Bool == true)
        #expect(text.attribute(.inlineCode, at: 0, effectiveRange: nil) as? Bool != true)
    }

    /// A ```mermaid fence decodes to a `.code` block tagged `.mermaid`, and encodes
    /// back to the same fence — so mermaid blocks persist without a codec change.
    @Test func mermaidFenceRoundTrips() {
        let md = "```mermaid\ngraph TD\n  A --> B\n```"
        let blocks = MarkdownCodec.decode(md)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code)
        #expect(blocks[0].language == .mermaid)
        #expect(blocks[0].plainText == "graph TD\n  A --> B")
        #expect(MarkdownCodec.encode(EditorDocument(blocks: blocks)) == md)
    }

    // The live diagram render runs in an inline WKWebView and is verified by
    // running the app (it needs an app event loop, which a plain `xcodebuild test`
    // host doesn't provide).

}
