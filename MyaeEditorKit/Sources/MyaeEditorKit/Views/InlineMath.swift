//
//  InlineMath.swift
//  MyaeEditor
//
//  Inline math ($E = mc^2$). Math lives inside a paragraph's attributed string
//  as a `MathAttachment` (an NSTextAttachment that renders a small image of the
//  formula). `MathRenderer` turns a LaTeX-ish subset into that image. The
//  `MathEditor` popover lets the user type/edit the LaTeX.
//

import SwiftUI
import AppKit

// MARK: - Attachment

/// An inline text attachment that carries its LaTeX source and renders it.
final class MathAttachment: NSTextAttachment {
    var latex: String
    var fontSize: CGFloat

    init(latex: String, fontSize: CGFloat) {
        self.latex = latex
        self.fontSize = fontSize
        super.init(data: nil, ofType: nil)
        refresh()
    }

    required init?(coder: NSCoder) {
        self.latex = coder.decodeObject(forKey: "latex") as? String ?? ""
        self.fontSize = coder.decodeObject(forKey: "fontSize") as? CGFloat ?? 15
        super.init(coder: coder)
        refresh()
    }

    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        coder.encode(latex, forKey: "latex")
        coder.encode(fontSize, forKey: "fontSize")
    }

    func refresh() {
        let (img, bounds) = MathRenderer.render(latex, fontSize: fontSize)
        self.image = img
        self.bounds = bounds
    }
}

// MARK: - Building inline attributed strings

enum InlineMath {
    static let placeholder = "\u{FFFC}"   // object-replacement char used by attachments

    /// An attributed string holding a single math attachment, styled to sit on
    /// the given block kind's text line.
    static func attributedString(latex: String, fontSize: CGFloat, kind: BlockKind) -> NSAttributedString {
        let att = MathAttachment(latex: latex, fontSize: fontSize)
        let s = NSMutableAttributedString(attachment: att)
        let range = NSRange(location: 0, length: s.length)
        s.addAttribute(.font, value: kind.baseFont, range: range)
        return s
    }
}

// MARK: - Renderer

enum MathRenderer {

    /// Cache of rendered formulas. Rendering allocates a bitmap via
    /// lockFocus/unlockFocus, so repeated renders of the same formula (e.g. every
    /// `MathPreview.updateNSView`, or two blocks with the same equation) are wasteful.
    private static var cache: [String: (NSImage, CGRect)] = [:]
    /// Keys in insertion order, so we can evict the oldest one at a time instead of
    /// dropping the whole cache at the size limit (which re-renders everything).
    private static var cacheOrder: [String] = []

    /// Render `latex` to an image plus the attachment bounds (baseline aligned).
    static func render(_ latex: String, fontSize: CGFloat, background: Bool = true) -> (NSImage, CGRect) {
        let key = "\(latex)|\(fontSize)|\(background)"
        if let hit = cache[key] { return hit }

        let result = renderUncached(latex, fontSize: fontSize, background: background)
        if cache.count >= 256, let oldest = cacheOrder.first {
            cache.removeValue(forKey: oldest)
            cacheOrder.removeFirst()
        }
        cache[key] = result
        cacheOrder.append(key)
        return result
    }

    private static func renderUncached(_ latex: String, fontSize: CGFloat, background: Bool) -> (NSImage, CGRect) {
        let attr = attributed(latex, fontSize: fontSize)
        let textSize = attr.size()
        let padX: CGFloat = background ? 4 : 1, padY: CGFloat = 2
        let imgSize = NSSize(width: ceil(textSize.width) + padX * 2,
                             height: ceil(textSize.height) + padY * 2)

        let image = NSImage(size: imgSize)
        image.lockFocus()
        if background {
            let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: imgSize), xRadius: 3, yRadius: 3)
            NSColor.secondaryLabelColor.withAlphaComponent(0.10).setFill()
            bg.fill()
        }
        attr.draw(at: NSPoint(x: padX, y: padY))
        image.unlockFocus()

        // Align the image so its text baseline lands on the surrounding baseline.
        let base = mathFont(fontSize, italic: false)
        let descent = -base.descender
        let bounds = CGRect(x: 0, y: -(descent + padY), width: imgSize.width, height: imgSize.height)
        return (image, bounds)
    }

    // MARK: LaTeX-subset → attributed string

    private static func mathFont(_ size: CGFloat, italic: Bool) -> NSFont {
        let base = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        return italic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
    }

    /// Convert the LaTeX subset to a styled attributed string (single level of
    /// super/subscripts, Greek letters, common operators; italic variables).
    static func attributed(_ latex: String, fontSize: CGFloat) -> NSAttributedString {
        let chars = Array(latex)
        let out = NSMutableAttributedString()
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "^", "_":
                i += 1
                let (glyphs, next) = readGroup(chars, from: i, fontSize: fontSize)
                i = next
                appendScript(glyphs, sup: c == "^", fontSize: fontSize, into: out)
            case "\\":
                let (sym, next) = readCommand(chars, from: i + 1, fontSize: fontSize)
                i = next
                out.append(sym)
            case "{", "}":
                i += 1   // grouping braces are layout-only
            default:
                out.append(atom(String(c), fontSize: fontSize))
                i += 1
            }
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: " ", attributes: [.font: mathFont(fontSize, italic: false)]))
        }
        return out
    }

    /// One atom: italic for a letter (variable), regular otherwise.
    private static func atom(_ s: String, fontSize: CGFloat) -> NSAttributedString {
        let isLetter = s.count == 1 && s.first!.isLetter
        let font = mathFont(fontSize, italic: isLetter)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.textColor])
    }

    /// Read the argument of a ^ / _ or a command: either `{...}` or one token.
    private static func readGroup(_ chars: [Character], from start: Int, fontSize: CGFloat) -> (NSAttributedString, Int) {
        guard start < chars.count else { return (NSAttributedString(string: ""), start) }
        if chars[start] == "{" {
            var depth = 1, j = start + 1
            var inner = ""
            while j < chars.count && depth > 0 {
                if chars[j] == "{" { depth += 1 }
                else if chars[j] == "}" { depth -= 1; if depth == 0 { break } }
                inner.append(chars[j]); j += 1
            }
            return (attributed(inner, fontSize: fontSize), j + 1)
        }
        if chars[start] == "\\" {
            let (sym, next) = readCommand(chars, from: start + 1, fontSize: fontSize)
            return (sym, next)
        }
        return (atom(String(chars[start]), fontSize: fontSize), start + 1)
    }

    /// Read a `\command` name and map it to a symbol (or leave it as text).
    private static func readCommand(_ chars: [Character], from start: Int, fontSize: CGFloat) -> (NSAttributedString, Int) {
        var j = start
        var name = ""
        while j < chars.count && chars[j].isLetter { name.append(chars[j]); j += 1 }
        if name.isEmpty, j < chars.count {   // escaped symbol like \{ or \,
            let ch = chars[j]
            if ch == "," || ch == " " {
                return (NSAttributedString(string: " ", attributes: [.font: mathFont(fontSize, italic: false)]), j + 1)
            }
            return (atom(String(ch), fontSize: fontSize), j + 1)
        }
        if name == "sqrt" {
            let (inner, next) = readGroup(chars, from: j, fontSize: fontSize)
            let s = NSMutableAttributedString(string: "√", attributes: [.font: mathFont(fontSize, italic: false), .foregroundColor: NSColor.textColor])
            s.append(inner)
            return (s, next)
        }
        if name == "frac" {
            let (num, n1) = readGroup(chars, from: j, fontSize: fontSize)
            let (den, n2) = readGroup(chars, from: n1, fontSize: fontSize)
            let s = NSMutableAttributedString(attributedString: num)
            s.append(NSAttributedString(string: "/", attributes: [.font: mathFont(fontSize, italic: false)]))
            s.append(den)
            return (s, n2)
        }
        let glyph = symbols[name] ?? name
        return (NSAttributedString(string: glyph, attributes: [.font: mathFont(fontSize, italic: false), .foregroundColor: NSColor.textColor]), j)
    }

    private static func appendScript(_ glyphs: NSAttributedString, sup: Bool, fontSize: CGFloat, into out: NSMutableAttributedString) {
        let small = fontSize * 0.72
        let m = NSMutableAttributedString(attributedString: glyphs)
        let range = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: range) { value, sub, _ in
            let italic = (value as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false
            m.addAttribute(.font, value: mathFont(small, italic: italic), range: sub)
        }
        m.addAttribute(.baselineOffset, value: sup ? fontSize * 0.35 : -fontSize * 0.12, range: range)
        out.append(m)
    }

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ",
        "sigma": "σ", "tau": "τ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ",
        "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "infty": "∞", "sum": "∑", "prod": "∏", "int": "∫", "partial": "∂",
        "nabla": "∇", "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "leq": "≤", "geq": "≥", "neq": "≠", "approx": "≈", "equiv": "≡",
        "propto": "∝", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "to": "→", "angle": "∠", "degree": "°", "in": "∈", "notin": "∉",
        "subset": "⊂", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃",
        "sqrt": "√",
    ]
}

// MARK: - Editor popover

/// The little bar for typing/editing a formula (with a live preview).
struct MathEditor: View {
    @Binding var latex: String
    var fontSize: CGFloat
    let onDone: (String) -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !latex.isEmpty {
                MathPreview(latex: latex, fontSize: fontSize)
            }
            HStack(spacing: 8) {
                TextField("E = mc^2", text: $latex)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, design: .monospaced))
                    .focused($focused)
                    .onSubmit { onDone(latex) }
                    .frame(minWidth: 220)

                Button { onDone(latex) } label: {
                    HStack(spacing: 4) { Text("Done"); Image(systemName: "return") }
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}

/// Renders the formula image inside SwiftUI (used by the editor preview and the
/// display-equation block).
struct MathPreview: NSViewRepresentable {
    var latex: String
    var fontSize: CGFloat
    var background: Bool = true

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyDown
        v.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = MathRenderer.render(latex, fontSize: fontSize, background: background).0
    }
}

// (The display-equation widget lives in SegmentWidgets.swift as SegmentEquationView.)
