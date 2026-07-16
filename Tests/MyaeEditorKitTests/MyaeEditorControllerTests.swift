//
//  MyaeEditorControllerTests.swift
//  MyaeEditorKitTests
//
//  Exercises the public document API: open, save, new, restore, dirty tracking,
//  and per-document image path resolution.
//

import Testing
import Foundation
@testable import MyaeEditorKit

@MainActor
struct MyaeEditorControllerTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyaeEditorKitTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func markdownRoundTrips() {
        let controller = MyaeEditorController(markdown: "# Hello\n\nWorld")
        #expect(controller.markdown.contains("# Hello"))
        #expect(controller.markdown.contains("World"))
        #expect(controller.fileURL == nil)
    }

    @Test func saveToWritesFileAndBinds() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("note.md")
        let controller = MyaeEditorController(markdown: "# Title\n\nBody")
        controller.save(to: url)

        #expect(controller.fileURL == url)
        #expect(!controller.isDirty)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk.contains("# Title"))
        #expect(onDisk.contains("Body"))
    }

    @Test func asyncSaveWritesFileAndBindsAfterCompletion() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("async-note.md")
        let controller = MyaeEditorController(markdown: "# Async\n\nBody")

        #expect(await controller.saveAsync(to: url))
        #expect(controller.fileURL == url)
        #expect(!controller.isDirty)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# Async\n\nBody")
    }

    @Test func editDuringAsyncSaveRemainsDirty() async throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("large.md")
        let content = String(repeating: "A reasonably long line of Markdown.\n", count: 2_000)
        let controller = MyaeEditorController(markdown: content)
        controller.beforeAsyncWriteForTesting = { try? await Task.sleep(for: .milliseconds(40)) }
        controller.document.markEdited()

        let save = Task { await controller.saveAsync(to: url) }
        while !controller.isSaving { await Task.yield() }
        controller.document.markEdited()

        #expect(await save.value)
        #expect(controller.isDirty)
    }

    @Test func loadSupersedesAsyncSaveStateUpdate() async throws {
        let dir = tempDir()
        let saveURL = dir.appendingPathComponent("old.md")
        let loadURL = dir.appendingPathComponent("new.md")
        try "new document".write(to: loadURL, atomically: true, encoding: .utf8)
        let content = String(repeating: "old document line\n", count: 2_000)
        let controller = MyaeEditorController(markdown: content)
        controller.beforeAsyncWriteForTesting = { try? await Task.sleep(for: .milliseconds(40)) }

        let save = Task { await controller.saveAsync(to: saveURL) }
        while !controller.isSaving { await Task.yield() }
        try controller.load(from: loadURL)

        #expect(await save.value == false)
        #expect(controller.fileURL == loadURL)
        #expect(controller.markdown == "new document")
    }

    @Test func failedLoadDoesNotSupersedeAsyncSave() async throws {
        let dir = tempDir()
        let saveURL = dir.appendingPathComponent("saved.md")
        let missingURL = dir.appendingPathComponent("missing.md")
        let controller = MyaeEditorController(markdown: "content to save")
        controller.beforeAsyncWriteForTesting = { try? await Task.sleep(for: .milliseconds(40)) }

        let save = Task { await controller.saveAsync(to: saveURL) }
        while !controller.isSaving { await Task.yield() }

        var loadFailed = false
        do {
            try controller.load(from: missingURL)
        } catch {
            loadFailed = true
        }

        #expect(loadFailed)
        #expect(await save.value)
        #expect(controller.fileURL == saveURL)
        #expect(try String(contentsOf: saveURL, encoding: .utf8) == "content to save")
    }

    @Test func autosaveToOldURLDoesNotCleanConcurrentSaveAs() async throws {
        let dir = tempDir()
        let oldURL = dir.appendingPathComponent("old.md")
        let newURL = dir.appendingPathComponent("new.md")
        try "before edit".write(to: oldURL, atomically: true, encoding: .utf8)
        let controller = try MyaeEditorController(
            contentsOf: oldURL,
            autosave: .enabled(debounce: 60, store: nil)
        )
        controller.beforeAsyncWriteForTesting = { try? await Task.sleep(for: .milliseconds(40)) }

        let saveAs = Task { await controller.saveAsync(to: newURL) }
        while !controller.isSaving { await Task.yield() }
        guard let storage = controller.document.segments.first?.textStorage else {
            Issue.record("expected text storage")
            return
        }
        storage.setAttributedString(NSAttributedString(string: "edit during save as"))
        controller.document.markEdited()
        controller.settleEditsForTesting()

        #expect(await saveAs.value)
        controller.flushPendingWrites()
        await Task.yield()

        #expect(controller.fileURL == newURL)
        #expect(controller.isDirty)
        #expect(try String(contentsOf: newURL, encoding: .utf8) == "before edit")
        #expect(try String(contentsOf: oldURL, encoding: .utf8) == "edit during save as")
    }

    @Test func loadFromReadsFileAndTitle() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("MyDoc.md")
        try "# Loaded\n\nfrom disk".write(to: url, atomically: true, encoding: .utf8)

        let controller = MyaeEditorController()
        try controller.load(from: url)

        #expect(controller.fileURL == url)
        #expect(controller.documentTitle == "MyDoc")
        #expect(controller.markdown.contains("# Loaded"))
        #expect(!controller.isDirty)
    }

    @Test func newDocumentResets() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("x.md")
        let controller = try {
            try "content".write(to: url, atomically: true, encoding: .utf8)
            let c = MyaeEditorController()
            try c.load(from: url)
            return c
        }()
        controller.newDocument()

        #expect(controller.fileURL == nil)
        #expect(controller.documentTitle == "")
        #expect(!controller.isDirty)
    }

    @Test func restoreFromStore() {
        let dir = tempDir()
        let store = MarkdownStore(directory: dir, titleDefaultsKey: "test.title.\(UUID().uuidString)")
        store.saveMarkdown("# Restored\n\ntext")
        store.saveTitle("RestoredTitle")

        let controller = MyaeEditorController(restoringFrom: store, autosave: .disabled)
        #expect(controller != nil)
        #expect(controller?.markdown.contains("# Restored") == true)
        #expect(controller?.documentTitle == "RestoredTitle")

        // Empty store → nil.
        let emptyStore = MarkdownStore(directory: tempDir())
        #expect(MyaeEditorController(restoringFrom: emptyStore, autosave: .disabled) == nil)
    }

    @Test func editingMarksDirty() {
        let controller = MyaeEditorController(markdown: "hi")
        #expect(!controller.isDirty)
        controller.document.markEdited()
        #expect(controller.isDirty)
    }

    @Test func loadDoesNotClobberStoredTitle() throws {
        let dir = tempDir()
        let store = MarkdownStore(directory: dir, titleDefaultsKey: "test.title.\(UUID().uuidString)")
        store.saveTitle("Scratch Notes")

        let fileURL = dir.appendingPathComponent("report.md")
        try "# Report".write(to: fileURL, atomically: true, encoding: .utf8)

        let controller = MyaeEditorController(autosave: .enabled(store: store))
        try controller.load(from: fileURL)

        // The programmatic title from the file name must not overwrite the
        // store's persisted scratch title.
        #expect(controller.documentTitle == "report")
        #expect(store.loadTitle() == "Scratch Notes")

        controller.newDocument()
        #expect(store.loadTitle() == "Scratch Notes")

        UserDefaults.standard.removeObject(forKey: store.titleDefaultsKey)
    }

    @Test func failedSaveReportsFailureAndStaysUnbound() {
        let controller = MyaeEditorController(markdown: "content")
        let badURL = URL(fileURLWithPath: "/nonexistent-dir-\(UUID().uuidString)/x.md")
        #expect(controller.save(to: badURL) == false)
        #expect(controller.fileURL == nil)   // failed save must not bind the file
    }

    @Test func imagePathAbsoluteWhenUnsaved() {
        let controller = MyaeEditorController(markdown: "text")
        let img = URL(fileURLWithPath: "/tmp/pics/photo.png")
        // Unsaved documents always store absolute image paths.
        #expect(controller.document.referencePath(for: img).hasPrefix("/"))
    }

    @Test func imagePathRelativeWhenSavedNearby() throws {
        let dir = tempDir()
        let docURL = dir.appendingPathComponent("doc.md")
        let controller = MyaeEditorController(markdown: "text")
        controller.save(to: docURL)

        // An image in the same folder resolves to a "./" relative path.
        let img = dir.appendingPathComponent("photo.png")
        let ref = controller.document.referencePath(for: img)
        #expect(ref.hasPrefix("./"))
        #expect(ref.contains("photo.png"))

        // And it resolves back to the same file.
        let resolved = controller.document.imageURL(for: ref)
        #expect(resolved.standardizedFileURL.path == img.standardizedFileURL.path)
    }
}
