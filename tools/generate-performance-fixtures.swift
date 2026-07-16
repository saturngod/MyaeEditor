#!/usr/bin/env swift

import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/MyaeEditorPerformance",
                 isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func write(_ name: String, _ contents: String) throws {
    try contents.write(to: output.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

let mixedList = (0 ..< 10_000).map { index in
    switch index % 4 {
    case 0: return "- bullet \(index)"
    case 1: return "\(index + 1). numbered \(index)"
    case 2: return "- [ ] task \(index)"
    default: return "> quote \(index)"
    }
}.joined(separator: "\n")
try write("large-mixed-list.md", mixedList)

func code(_ line: String, characters: Int = 100_000) -> String {
    String(String(repeating: line, count: characters / line.count + 1).prefix(characters))
}
try write("large-swift.md", "```swift\n\(code("let value = 42 // representative source\n"))\n```")
try write("large-css.md", "```css\n\(code(".item { color: #123456; margin: 10px; }\n"))\n```")
try write("large-html.md", "```html\n\(code("<div class=\"item\">content</div>\n"))\n```")

let section = "# Section\n\nParagraph with **bold**, *italic*, and `code`.\n\n"
let largeDocument = String(String(repeating: section, count: 1_000_000 / section.utf8.count + 1)
    .prefix(1_000_000))
try write("large-document.md", largeDocument)

let columns = 20
var tableLines = [
    "| " + (0 ..< columns).map { "column \($0)" }.joined(separator: " | ") + " |",
    "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |",
]
for row in 0 ..< 1_000 {
    tableLines.append("| " + (0 ..< columns).map { "r\(row)c\($0)" }.joined(separator: " | ") + " |")
}
try write("large-table.md", tableLines.joined(separator: "\n"))

let mermaid = (0 ..< 20).map { index in
    "```mermaid\ngraph TD\nA\(index)-->B\(index)\n```"
}.joined(separator: "\n\n")
try write("mermaid-heavy.md", mermaid)

let imagesDirectory = output.appendingPathComponent("images", isDirectory: true)
try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
for index in 0 ..< 10 {
    autoreleasepool {
        let width = 6_000, height = 4_000
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedHue: CGFloat(index) / 10, saturation: 0.7,
                brightness: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? data.write(to: imagesDirectory.appendingPathComponent("photo-\(index).jpg"))
        }
    }
}
let imageMarkdown = (0 ..< 10).map { "![](images/photo-\($0).jpg)" }.joined(separator: "\n\n")
try write("image-heavy.md", imageMarkdown)

print("Generated performance fixtures at \(output.path)")
