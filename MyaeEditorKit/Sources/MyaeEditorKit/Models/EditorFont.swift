//
//  EditorFont.swift
//  MyaeEditorKit
//
//  Process-wide font-family overrides for editor text, set from
//  `MyaeEditorConfiguration.fontFamilyName` / `codeFontFamilyName`. Two
//  independent families: `regular` for body/heading text, `monospaced` for
//  code blocks and inline code. `BlockKind.baseFont`, `InlineCode.font`, and
//  `TableCellTextView`'s base font all resolve through here so one setting
//  applies to every text surface. Falls back to the system font whenever no
//  family is set or the family name doesn't resolve.
//
//  NOTE: these are process-wide (the font is a global setting, not a per-view
//  style), so two `MyaeEditor` instances shown at once share one font — the
//  last configuration written wins. Host apps that want per-window fonts would
//  need to thread the family through the codec instead.
//

import AppKit

enum EditorFont {
    /// Font family name for body/heading text, or `nil` for the system font.
    static var familyName: String?
    /// Font family name for code blocks and inline code, or `nil` for the
    /// system monospaced font.
    static var codeFamilyName: String?

    static func regular(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard let familyName else {
            return .systemFont(ofSize: size, weight: weight)
        }
        // Map the requested weight to AppKit's 0–15 family weight scale so a
        // custom family keeps its semibold/bold distinction instead of every
        // heavy weight collapsing to plain bold. The manager returns the
        // closest available face when a family lacks the exact weight.
        let (familyWeight, traits): (Int, NSFontTraitMask)
        switch weight {
        case .bold:     (familyWeight, traits) = (9, .boldFontMask)
        case .semibold: (familyWeight, traits) = (8, [])
        default:        (familyWeight, traits) = (5, [])
        }
        return NSFontManager.shared.font(withFamily: familyName,
                                         traits: traits,
                                         weight: familyWeight,
                                         size: size)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    static func monospaced(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        guard let codeFamilyName, let base = NSFont(name: codeFamilyName, size: size) else {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        guard weight == .bold || weight == .semibold else { return base }
        // Synthesize a heavier face when asked; fall back to the plain face if
        // the family has no bold member.
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        return bold == base ? base : bold
    }
}
