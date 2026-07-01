//
//  SyntaxHighlighter.swift
//  MyaeEditor
//
//  A small, dependency-free syntax highlighter. A single-pass scanner tokenises
//  comments, strings, numbers, keywords and (capitalised) types, then applies
//  colors directly to an NSTextStorage so the caret is preserved while typing.
//

import AppKit

enum CodeLanguage: String, CaseIterable, Identifiable, Codable {
    case plain, swift, python, javascript, typescript, json, html, css
    case bash, go, rust, c, cpp, java, ruby, sql, yaml

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plain:      "Plain Text"
        case .swift:      "Swift"
        case .python:     "Python"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .json:       "JSON"
        case .html:       "HTML"
        case .css:        "CSS"
        case .bash:       "Shell"
        case .go:         "Go"
        case .rust:       "Rust"
        case .c:          "C"
        case .cpp:        "C++"
        case .java:       "Java"
        case .ruby:       "Ruby"
        case .sql:        "SQL"
        case .yaml:       "YAML"
        }
    }

    var lineComment: String? {
        switch self {
        case .python, .bash, .ruby, .yaml: "#"
        case .sql: "--"
        case .json, .html, .css, .plain: nil
        default: "//"
        }
    }

    var blockComment: (open: String, close: String)? {
        switch self {
        case .swift, .javascript, .typescript, .c, .cpp, .java, .go, .rust, .css, .sql:
            ("/*", "*/")
        case .html: ("<!--", "-->")
        default: nil
        }
    }

    var stringDelimiters: Set<Character> {
        switch self {
        case .javascript, .typescript, .go: ["\"", "'", "`"]
        case .json: ["\""]
        case .yaml, .bash, .ruby, .python: ["\"", "'"]
        default: ["\"", "'"]
        }
    }

    var caseInsensitiveKeywords: Bool { self == .sql }

    var keywords: Set<String> {
        switch self {
        case .swift:
            ["func","let","var","if","else","for","while","return","struct","class",
             "enum","protocol","extension","import","guard","switch","case","default",
             "break","continue","public","private","internal","fileprivate","static",
             "self","Self","init","deinit","throws","throw","try","catch","do","defer",
             "async","await","in","where","as","is","nil","true","false","some","any",
             "weak","unowned","lazy","mutating","override","final","typealias",
             "associatedtype","inout","repeat","fallthrough","subscript","operator",
             "convenience","required","indirect","open","get","set","willSet","didSet"]
        case .python:
            ["def","class","if","elif","else","for","while","return","import","from",
             "as","pass","break","continue","try","except","finally","raise","with",
             "lambda","yield","global","nonlocal","del","in","is","not","and","or",
             "None","True","False","async","await","assert"]
        case .javascript, .typescript:
            ["function","var","let","const","if","else","for","while","return","class",
             "extends","new","this","super","import","export","from","default","try",
             "catch","finally","throw","switch","case","break","continue","typeof",
             "instanceof","in","of","do","yield","async","await","null","undefined",
             "true","false","void","delete","interface","type","enum","implements",
             "public","private","protected","readonly","namespace","as","declare"]
        case .go:
            ["func","var","const","if","else","for","range","return","package","import",
             "type","struct","interface","map","chan","go","defer","select","switch",
             "case","default","break","continue","fallthrough","goto","nil","true",
             "false","iota"]
        case .rust:
            ["fn","let","mut","if","else","for","while","loop","return","struct","enum",
             "impl","trait","pub","use","mod","match","as","ref","move","self","Self",
             "where","async","await","dyn","const","static","unsafe","crate","super",
             "type","true","false","break","continue","in"]
        case .java:
            ["public","private","protected","class","interface","extends","implements",
             "static","final","void","int","long","double","float","boolean","char",
             "new","return","if","else","for","while","switch","case","break","continue",
             "try","catch","finally","throw","throws","import","package","this","super",
             "abstract","enum","null","true","false","instanceof","synchronized"]
        case .c, .cpp:
            ["int","char","float","double","void","long","short","unsigned","signed",
             "struct","union","enum","typedef","const","static","extern","return","if",
             "else","for","while","switch","case","break","continue","do","sizeof",
             "goto","class","public","private","protected","namespace","template","new",
             "delete","this","nullptr","true","false","auto","using","virtual","override",
             "include","define"]
        case .bash:
            ["if","then","else","elif","fi","for","while","do","done","case","esac",
             "function","return","in","echo","export","local","read","exit","break",
             "continue","source"]
        case .sql:
            ["SELECT","FROM","WHERE","INSERT","UPDATE","DELETE","CREATE","TABLE","DROP",
             "ALTER","JOIN","LEFT","RIGHT","INNER","OUTER","FULL","ON","AND","OR","NOT",
             "NULL","AS","ORDER","BY","GROUP","HAVING","LIMIT","OFFSET","INTO","VALUES",
             "SET","DISTINCT","COUNT","SUM","AVG","MIN","MAX","PRIMARY","KEY","FOREIGN",
             "REFERENCES","INDEX","UNION","ALL","IN","LIKE","BETWEEN","IS","ASC","DESC"]
        case .ruby:
            ["def","end","if","elsif","else","unless","while","until","for","in","do",
             "return","class","module","require","require_relative","attr_accessor",
             "attr_reader","attr_writer","yield","begin","rescue","ensure","raise",
             "then","case","when","nil","true","false","self","super","new","lambda",
             "proc","puts"]
        case .json, .yaml:
            ["true","false","null"]
        default:
            []
        }
    }
}

enum TokenKind {
    case keyword, type, string, number, comment

    var color: NSColor {
        switch self {
        case .keyword: .systemPurple
        case .type:    .systemTeal
        case .string:  .systemRed
        case .number:  .systemOrange
        case .comment: .systemGreen
        }
    }
}

enum SyntaxHighlighter {

    /// Recolor `storage` in place. Only attributes change, so the selection /
    /// caret are preserved.
    ///
    /// Pass `editedRange` (the char range of the last edit) to recolor only the
    /// affected line(s) instead of the whole storage — O(line) per keystroke
    /// rather than O(document). If the edited line touches a multi-line construct
    /// (block comment or a backtick string) the whole document may need recoloring,
    /// so we fall back to a full pass. Omit `editedRange` (or pass nil) for the
    /// initial paint, a paste, or a language change to force a full pass.
    static func highlight(_ storage: NSTextStorage, language: CodeLanguage, font: NSFont, editedRange: NSRange? = nil) {
        let s = storage.string as NSString
        let scan = scanRange(s, editedRange, language)
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.45

        storage.beginEditing()
        storage.setAttributes(
            [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: para],
            range: scan)
        if language != .plain {
            for (range, kind) in tokens(in: s, language: language, scan: scan)
            where NSIntersectionRange(range, scan).length > 0 {
                storage.addAttribute(.foregroundColor, value: kind.color, range: range)
            }
        }
        storage.endEditing()
    }

    /// The character range to re-scan: the edited line(s), or the whole string
    /// when there's no edit context or the edit could affect coloring elsewhere.
    private static func scanRange(_ s: NSString, _ edited: NSRange?, _ language: CodeLanguage) -> NSRange {
        let full = NSRange(location: 0, length: s.length)
        guard let edited, edited.location != NSNotFound, edited.location <= s.length else { return full }
        let clamped = NSRange(location: edited.location, length: min(edited.length, s.length - edited.location))
        let line = s.lineRange(for: clamped)
        let text = s.substring(with: line)
        // Multi-line constructs can change coloring past the edited line.
        if let bc = language.blockComment, text.contains(bc.open) || text.contains(bc.close) { return full }
        if language.stringDelimiters.contains("`"), text.contains("`") { return full }
        return line
    }

    /// Keyword lookup set per language, memoized. `keywords` builds a fresh Set on
    /// every access, and case-insensitive languages additionally uppercase it —
    /// wasteful to redo on every keystroke, so resolve it once per language here.
    /// Only touched from the main thread (text editing), matching MathRenderer's cache.
    private static var keywordCache: [CodeLanguage: Set<String>] = [:]
    private static func lookupKeywords(_ language: CodeLanguage) -> Set<String> {
        if let cached = keywordCache[language] { return cached }
        let set = language.caseInsensitiveKeywords
            ? Set(language.keywords.map { $0.uppercased() }) : language.keywords
        keywordCache[language] = set
        return set
    }

    // MARK: Scanner

    /// Tokenise `s` within `scan` (start..<end). Comments/strings are still bounded
    /// to `scan`; callers only recolor within `scan`, and `scanRange` guarantees no
    /// multi-line construct crosses the boundary in the incremental path.
    private static func tokens(in s: NSString, language: CodeLanguage, scan: NSRange) -> [(NSRange, TokenKind)] {
        // CSS doesn't fit the keyword model — use a dedicated regex pass.
        if language == .css { return cssTokens(in: s) }

        var result: [(NSRange, TokenKind)] = []
        let end = scan.location + scan.length
        var i = scan.location
        let keywordsUpper = lookupKeywords(language)

        func emit(_ start: Int, _ stop: Int, _ kind: TokenKind) {
            result.append((NSRange(location: start, length: stop - start), kind))
        }

        while i < end {
            let c = s.character(at: i)

            // whitespace
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }

            // block comment
            if let bc = language.blockComment, matches(s, i, bc.open) {
                let start = i
                i += (bc.open as NSString).length
                while i < end && !matches(s, i, bc.close) { i += 1 }
                if i < end { i += (bc.close as NSString).length }
                emit(start, i, .comment); continue
            }

            // line comment
            if let lc = language.lineComment, matches(s, i, lc) {
                let start = i
                while i < end && s.character(at: i) != 10 { i += 1 }
                emit(start, i, .comment); continue
            }

            // string
            if let scalar = UnicodeScalar(c), language.stringDelimiters.contains(Character(scalar)) {
                let quote = c
                let start = i
                i += 1
                while i < end {
                    let d = s.character(at: i)
                    if d == 92 && quote != 96 { i += 2; continue }  // backslash escape (not in backticks)
                    i += 1
                    if d == quote { break }
                    if d == 10 && quote != 96 { break }             // unterminated on newline
                }
                emit(start, i, .string); continue
            }

            // number — hex only with a 0x prefix; otherwise digits/./_/exponent.
            if c >= 48 && c <= 57 {
                let start = i
                if c == 48, i + 1 < end, s.character(at: i + 1) == 120 || s.character(at: i + 1) == 88 {
                    i += 2
                    while i < end && isHexDigit(s.character(at: i)) { i += 1 }
                } else {
                    while i < end {
                        let d = s.character(at: i)
                        if (d >= 48 && d <= 57) || d == 46 || d == 95 || d == 101 || d == 69 {
                            i += 1   // 0-9 . _ e E
                        } else { break }
                    }
                }
                emit(start, i, .number); continue
            }

            // identifier / keyword / type
            if isIdentStart(c) {
                let start = i
                while i < end && isIdentChar(s.character(at: i)) { i += 1 }
                let word = s.substring(with: NSRange(location: start, length: i - start))
                let lookup = language.caseInsensitiveKeywords ? word.uppercased() : word
                if keywordsUpper.contains(lookup) {
                    emit(start, i, .keyword)
                } else if let f = word.first, f.isUppercase, f.isLetter {
                    emit(start, i, .type)
                }
                continue
            }

            i += 1
        }

        // Light HTML tag coloring on top of the generic pass.
        if language == .html {
            highlightHTMLTags(in: s, into: &result)
        }
        return result
    }

    /// A CSS token rule: a precompiled regex plus how it interacts with earlier
    /// matches. Compiled once (pattern compilation isn't cheap) and reused.
    private struct CSSRule {
        let regex: NSRegularExpression
        let kind: TokenKind
        let skipCovered: Bool
        let mark: Bool
        init?(_ pattern: String, _ kind: TokenKind, skipCovered: Bool, mark: Bool) {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            self.regex = re; self.kind = kind; self.skipCovered = skipCovered; self.mark = mark
        }
    }

    private static let cssRules: [CSSRule] = [
        CSSRule("/\\*[\\s\\S]*?\\*/", .comment, skipCovered: false, mark: true),       // comments
        CSSRule("\"[^\"]*\"|'[^']*'", .string, skipCovered: true, mark: true),         // strings
        CSSRule("@[A-Za-z-]+", .keyword, skipCovered: true, mark: true),               // @media, @import
        CSSRule("#[0-9A-Fa-f]{3,8}\\b", .number, skipCovered: true, mark: true),       // hex colors
        CSSRule("[.#][A-Za-z_][\\w-]*", .type, skipCovered: true, mark: true),         // .class / #id
        CSSRule("[A-Za-z-]+(?=\\s*:)", .keyword, skipCovered: true, mark: true),       // properties
        CSSRule("\\b\\d+(\\.\\d+)?(px|em|rem|%|vh|vw|fr|pt|deg|s|ms)?", .number, skipCovered: true, mark: true),
        CSSRule("!important", .keyword, skipCovered: true, mark: false),
    ].compactMap { $0 }

    private static let htmlTagRegex = try? NSRegularExpression(pattern: "</?[A-Za-z][\\w:-]*")

    /// CSS: comments, strings, at-rules, hex colors, selectors, properties, units.
    private static func cssTokens(in s: NSString) -> [(NSRange, TokenKind)] {
        var result: [(NSRange, TokenKind)] = []
        var covered = IndexSet()
        let whole = NSRange(location: 0, length: s.length)
        let str = s as String

        for rule in cssRules {
            for m in rule.regex.matches(in: str, range: whole) {
                let r = m.range
                guard r.location != NSNotFound, r.length > 0 else { continue }
                let candidate = IndexSet(integersIn: r.location ..< (r.location + r.length))
                if rule.skipCovered, !covered.intersection(candidate).isEmpty { continue }
                result.append((r, rule.kind))
                if rule.mark { covered.formUnion(candidate) }
            }
        }
        return result
    }

    private static func highlightHTMLTags(in s: NSString, into result: inout [(NSRange, TokenKind)]) {
        guard let regex = htmlTagRegex else { return }
        regex.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
            if let r = m?.range { result.append((r, .keyword)) }
        }
    }

    /// True if `token` appears at index `i`. Compares unichar-by-unichar (called
    /// per character while scanning, so avoid the per-call substring allocation).
    private static func matches(_ s: NSString, _ i: Int, _ token: String) -> Bool {
        let t = token as NSString
        guard i + t.length <= s.length else { return false }
        for k in 0 ..< t.length where s.character(at: i + k) != t.character(at: k) {
            return false
        }
        return true
    }

    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
    }
    private static func isIdentChar(_ c: unichar) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }
    private static func isHexDigit(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) // 0-9 a-f A-F
    }
}
