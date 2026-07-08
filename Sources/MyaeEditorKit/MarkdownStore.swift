//
//  MarkdownStore.swift
//  MyaeEditorKit
//
//  A location on disk where an editor's Markdown (and its title) is autosaved.
//  Replaces the old `DocumentStore` singleton with a value type so each
//  controller can point at its own store — different apps, different folders.
//

import Foundation
import UniformTypeIdentifiers

public extension UTType {
    /// The Markdown document type (`.md`). Falls back to plain text on the rare
    /// system that doesn't declare it.
    static var markdown: UTType { UTType(filenameExtension: "md") ?? .plainText }
}

/// A folder that holds the autosaved default document (`document.md`) plus a
/// `UserDefaults` key for its title. Used for the unsaved "scratch" document and
/// for restoring it on the next launch.
nonisolated public struct MarkdownStore: Sendable {
    /// Directory the document and its bundled images live in.
    public var directory: URL
    /// `UserDefaults` key the document title is persisted under.
    public var titleDefaultsKey: String

    public init(directory: URL, titleDefaultsKey: String = "MyaeEditor.documentTitle") {
        self.directory = directory
        self.titleDefaultsKey = titleDefaultsKey
    }

    /// The default store: `~/Library/Application Support/MyaeEditor`.
    public static let `default` = MarkdownStore(
        directory: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MyaeEditor", isDirectory: true)
    )

    public var fileURL: URL { directory.appendingPathComponent("document.md") }
    public var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    nonisolated public func loadMarkdown() -> String? {
        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch CocoaError.fileNoSuchFile, CocoaError.fileReadNoSuchFile {
            return nil   // first launch — no file yet
        } catch {
            NSLog("[MarkdownStore] Failed to load document: %@", error.localizedDescription)
            return nil
        }
    }

    /// Write the document. Returns whether the write succeeded.
    @discardableResult
    nonisolated public func saveMarkdown(_ markdown: String) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("[MarkdownStore] Failed to save document: %@", error.localizedDescription)
            return false
        }
    }

    public func loadTitle() -> String { UserDefaults.standard.string(forKey: titleDefaultsKey) ?? "" }
    public func saveTitle(_ title: String) { UserDefaults.standard.set(title, forKey: titleDefaultsKey) }
}
