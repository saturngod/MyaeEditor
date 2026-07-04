//
//  MyaeEditorTests.swift
//  MyaeEditorTests
//
//  Created by Bonjoy on 6/30/26.
//

import Testing
import AppKit
@testable import MyaeEditorKit

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

    // MARK: - Smart paste

    private func attr(_ s: String, kind: BlockKind = .paragraph) -> NSAttributedString {
        NSAttributedString(string: s, attributes: BlockTextView.typingAttributes(for: kind))
    }

    /// `decodeForPaste` normalizes line endings and drops trailing blank lines so a
    /// terminal/browser copy doesn't leave empty paragraphs behind.
    @Test func decodeForPasteNormalizes() {
        let blocks = MarkdownCodec.decodeForPaste("one\r\ntwo\r\n\n")
        #expect(blocks.count == 2)
        #expect(blocks[0].plainText == "one")
        #expect(blocks[1].plainText == "two")

        // A single plain line stays one paragraph (routes to the inline path).
        let one = MarkdownCodec.decodeForPaste("just text")
        #expect(one.count == 1 && one[0].kind == .paragraph)
    }

    /// `insertBlocks` keeps order and clamps an out-of-range index.
    @Test func insertBlocksClampsAndOrders() {
        let doc = EditorDocument(blocks: [Block(kind: .paragraph, text: attr("a"))])
        doc.insertBlocks([Block(text: attr("b")), Block(text: attr("c"))], at: 99)
        #expect(doc.blocks.map(\.plainText) == ["a", "b", "c"])
    }

    /// Pasting mid-text splits the host: before-text stays, pasted blocks land
    /// between, and the after-text becomes a trailing block of the same kind.
    @Test func pasteSplitsHostAtCaret() {
        let host = Block(kind: .quote, text: attr("hello world", kind: .quote), depth: 2)
        let doc = EditorDocument(blocks: [host])
        let pasted = MarkdownCodec.decodeForPaste("| a | b |\n| --- | --- |\n| 1 | 2 |")

        doc.paste(pasted, into: host,
                  textBefore: attr("hello ", kind: .quote),
                  textAfter: attr("world", kind: .quote))

        #expect(doc.blocks.count == 3)
        #expect(doc.blocks[0].plainText == "hello ")
        #expect(doc.blocks[1].kind == .table)
        // Trailing block inherits the host's kind and depth.
        #expect(doc.blocks[2].kind == .quote)
        #expect(doc.blocks[2].plainText == "world")
        #expect(doc.blocks[2].depth == 2)
        // Caret lands at the end of the last (textual) inserted block.
        #expect(doc.pendingCaretLocation?.id == doc.blocks[2].id)
        #expect(doc.pendingCaretLocation?.location == 5)
    }

    /// When before-text exists and the first pasted block is a paragraph, it merges
    /// inline into the host instead of creating a separate block (Notion-style).
    @Test func pasteMergesLeadingParagraph() {
        let host = Block(kind: .paragraph, text: attr("Start "))
        let doc = EditorDocument(blocks: [host])
        let pasted = MarkdownCodec.decodeForPaste("continued.\n# A heading")

        doc.paste(pasted, into: host, textBefore: attr("Start "), textAfter: attr(""))

        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].plainText == "Start continued.")   // merged inline
        #expect(doc.blocks[1].kind == .heading1)
    }

    /// Pasting into an empty paragraph replaces it in place (no leading blank line).
    @Test func pasteReplacesEmptyParagraph() {
        let host = Block(kind: .paragraph, text: attr(""))
        let doc = EditorDocument(blocks: [host])
        let pasted = MarkdownCodec.decodeForPaste("# Title\nBody")

        doc.paste(pasted, into: host, textBefore: attr(""), textAfter: attr(""))

        #expect(doc.blocks.map(\.kind) == [.heading1, .paragraph])
        #expect(doc.blocks[0].plainText == "Title")
    }

    /// A paste whose last block is non-textual (a divider) block-selects it rather
    /// than trying to focus a text view it doesn't have.
    @Test func pasteBlockSelectsTrailingNonTextual() {
        let host = Block(kind: .paragraph, text: attr("x"))
        let doc = EditorDocument(blocks: [host])
        let pasted = MarkdownCodec.decodeForPaste("para\n\n---")   // paragraph then divider

        doc.paste(pasted, into: host, textBefore: attr("x"), textAfter: attr(""))

        let divider = doc.blocks.last!
        #expect(divider.kind == .divider)
        #expect(doc.selectedBlockIDs == [divider.id])
        #expect(doc.focusedBlockID == nil)
    }

    /// `replaceSelectedBlocks` swaps the selected run in place and selects the result.
    @Test func replaceSelectedBlocksReplacesInPlace() {
        let a = Block(text: attr("a")), b = Block(text: attr("b")), c = Block(text: attr("c"))
        let doc = EditorDocument(blocks: [a, b, c])
        doc.selectedBlockIDs = [b.id]
        let fresh = MarkdownCodec.decodeForPaste("one\ntwo")

        doc.replaceSelectedBlocks(with: fresh)

        #expect(doc.blocks.map(\.plainText) == ["a", "one", "two", "c"])
        #expect(doc.selectedBlockIDs == Set(fresh.map(\.id)))
        #expect(doc.focusedBlockID == nil)
    }

    /// `restyled(to:)` maps text onto the target kind's base font while keeping bold
    /// runs bold and inline-code runs monospaced at the new size.
    @Test func restyledPreservesTraits() {
        let m = MarkdownCodec.decode("normal **bold** `code`")[0].text
        let styled = m.restyled(to: .heading1)
        let base = BlockKind.heading1.baseFont

        let boldRange = (styled.string as NSString).range(of: "bold")
        let boldFont = styled.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        #expect(boldFont.pointSize == base.pointSize)

        let codeRange = (styled.string as NSString).range(of: "code")
        let codeFont = styled.attribute(.font, at: codeRange.location, effectiveRange: nil) as! NSFont
        #expect(codeFont.fontName == InlineCode.font(size: base.pointSize).fontName)
        #expect(codeFont.pointSize == base.pointSize)
    }

}
