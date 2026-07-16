//
//  PerformanceFixtures.swift
//  MyaeEditorKitTests
//
//  Deterministic workload generators used by regression tests and by manual
//  Instruments runs. Keeping them generated avoids committing multi-megabyte
//  Markdown fixtures to the repository.
//

enum PerformanceFixtures {
    static func mixedList(paragraphs: Int = 10_000) -> String {
        (0 ..< paragraphs).map { index in
            switch index % 4 {
            case 0: return "- bullet \(index)"
            case 1: return "\(index + 1). numbered \(index)"
            case 2: return "- [ ] task \(index)"
            default: return "> quote \(index)"
            }
        }.joined(separator: "\n")
    }

    static func code(language: String, characters: Int = 100_000) -> String {
        let line: String
        switch language {
        case "css": line = ".item { color: #123456; margin: 10px; }\n"
        case "html": line = "<div class=\"item\">content</div>\n"
        default: line = "let value = 42 // representative source\n"
        }
        let repetitions = max(1, characters / line.count + 1)
        return String(String(repeating: line, count: repetitions).prefix(characters))
    }

    static func largeMarkdown(minimumBytes: Int = 1_000_000) -> String {
        let section = "# Section\n\nParagraph with **bold**, *italic*, and `code`.\n\n"
        return String(String(repeating: section, count: minimumBytes / section.utf8.count + 1)
            .prefix(minimumBytes))
    }

    static func table(rows: Int = 1_000, columns: Int = 20) -> [[String]] {
        (0 ..< rows).map { row in
            (0 ..< columns).map { column in "r\(row)c\(column)" }
        }
    }
}
