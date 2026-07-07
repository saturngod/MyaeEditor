//
//  MyaeEditorController.swift
//  MyaeEditorKit
//
//  Owns a single document's state and all of its file I/O: open/save panels,
//  explicit save, debounced autosave, and dirty tracking. One controller drives
//  one `MyaeEditor` view (one window). This is the public entry point apps use
//  when they want to manage documents themselves; the binding-based
//  `MyaeEditor(markdown:)` initializer creates one internally.
//

import AppKit
import Combine
import Observation

/// When and where a controller autosaves.
public struct AutosavePolicy: Sendable {
    /// Autosave after edits settle.
    public var isEnabled: Bool
    /// Idle time after the last edit before a write (seconds).
    public var debounce: TimeInterval
    /// Where to autosave a document that has no file yet. `nil` = only autosave
    /// once the document has a `fileURL`.
    public var store: MarkdownStore?

    public init(isEnabled: Bool, debounce: TimeInterval = 2, store: MarkdownStore? = nil) {
        self.isEnabled = isEnabled
        self.debounce = debounce
        self.store = store
    }

    /// No autosave; the app saves explicitly.
    public static let disabled = AutosavePolicy(isEnabled: false)
    /// Autosave enabled, 2s debounce, to the default Application Support store.
    public static let `default` = AutosavePolicy(isEnabled: true, debounce: 2, store: .default)
    /// Autosave enabled with a custom debounce and store.
    public static func enabled(debounce: TimeInterval = 2,
                               store: MarkdownStore? = .default) -> AutosavePolicy {
        AutosavePolicy(isEnabled: true, debounce: debounce, store: store)
    }
}

@Observable
public final class MyaeEditorController {

    // MARK: Public state

    /// The document title (shown above the first block; user edits are persisted
    /// to the autosave store when autosave is enabled). Programmatic sets from
    /// `load(from:)` / `newDocument()` don't persist — they must not clobber the
    /// store's scratch-document title.
    public var documentTitle: String {
        didSet {
            guard documentTitle != oldValue, !suppressTitlePersist, autosave.isEnabled else { return }
            autosave.store?.saveTitle(documentTitle)
        }
    }

    /// Set while assigning the title from a non-user source (file name, reset).
    @ObservationIgnored private var suppressTitlePersist = false

    private func setTitle(programmatic title: String) {
        suppressTitlePersist = true
        documentTitle = title
        suppressTitlePersist = false
    }

    /// The `.md` file this document is bound to, or `nil` when unsaved.
    public private(set) var fileURL: URL?

    /// `true` when there are edits not yet written to `fileURL` (or the store).
    public private(set) var isDirty: Bool = false

    /// Read or replace the whole document as Markdown. Setting decodes and
    /// replaces the blocks (normalizing via a re-encode); it does not touch
    /// `fileURL`.
    public var markdown: String {
        get { SegmentCodec.encode(document.segments) }
        set { loadContent(newValue) }
    }

    // MARK: Callbacks

    /// Fired after edits settle (debounced), with the controller.
    @ObservationIgnored public var onChange: ((MyaeEditorController) -> Void)?
    /// Fired after a document is opened from a URL.
    @ObservationIgnored public var onOpen: ((URL) -> Void)?
    /// Fired after a save. The URL is `nil` when the write went to the autosave store.
    @ObservationIgnored public var onSave: ((URL?) -> Void)?
    /// Fired when the dirty flag flips.
    @ObservationIgnored public var onDirtyChange: ((Bool) -> Void)?

    /// Autosave behavior. Changing this re-arms the autosave subscription.
    @ObservationIgnored public var autosave: AutosavePolicy {
        didSet { armAutosave() }
    }

    // MARK: Internal state

    /// The live document model. Internal — segments are not part of the API.
    let document: SegmentDocument
    /// The encoded content last written to disk (or last loaded). Drives the
    /// "did it actually change?" check so autosave doesn't rewrite unchanged text.
    var lastSaved: String

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var terminateObserver: NSObjectProtocol?

    // MARK: Lifecycle

    /// A new, blank document.
    public init(autosave: AutosavePolicy = .disabled) {
        self.autosave = autosave
        self.document = SegmentDocument(segments: MyaeEditorController.blankSegments())
        self.lastSaved = ""
        self.fileURL = nil
        self.documentTitle = ""
        configureImageBase()
        armAutosave()
    }

    /// A document initialized from Markdown text (no file binding).
    public init(markdown: String, autosave: AutosavePolicy = .disabled) {
        self.autosave = autosave
        self.document = SegmentDocument(segments: SegmentCodec.decode(markdown))
        self.lastSaved = markdown
        self.fileURL = nil
        self.documentTitle = ""
        configureImageBase()
        // Normalize lastSaved to the encoded form so autosave doesn't immediately
        // rewrite a semantically-identical file.
        self.lastSaved = SegmentCodec.encode(document.segments)
        armAutosave()
    }

    /// A document loaded from a `.md` file. Its folder becomes the base for
    /// relative image paths.
    public init(contentsOf url: URL, autosave: AutosavePolicy = .disabled) throws {
        self.autosave = autosave
        let text = try String(contentsOf: url, encoding: .utf8)
        self.document = SegmentDocument(segments: SegmentCodec.decode(text))
        self.lastSaved = text
        self.fileURL = url
        self.documentTitle = url.deletingPathExtension().lastPathComponent
        document.imageFileDirectory = url.deletingLastPathComponent()
        armAutosave()
    }

    /// Restore the autosaved document (and title) from `store`. Returns `nil` if
    /// the store is empty (first launch).
    public init?(restoringFrom store: MarkdownStore, autosave: AutosavePolicy = .default) {
        guard let markdown = store.loadMarkdown() else { return nil }
        self.autosave = autosave
        self.document = SegmentDocument(segments: SegmentCodec.decode(markdown))
        self.lastSaved = markdown
        self.fileURL = nil
        self.documentTitle = store.loadTitle()
        document.imageFallbackDirectory = store.directory
        armAutosave()
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
    }

    // MARK: Commands

    /// Reset to an empty document, dropping the file binding.
    public func newDocument() {
        fileURL = nil
        document.replaceAll(MyaeEditorController.blankSegments())
        configureImageBase()
        lastSaved = ""
        setTitle(programmatic: "")
        setDirty(false)
    }

    /// Load a `.md` file into this controller.
    public func load(from url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        fileURL = url
        document.imageFileDirectory = url.deletingLastPathComponent()   // before decode → images resolve
        document.replaceAll(SegmentCodec.decode(text))
        lastSaved = text
        setTitle(programmatic: url.deletingPathExtension().lastPathComponent)
        setDirty(false)
        onOpen?(url)
    }

    /// Present an Open panel (`.md`) and load the chosen file. Returns the URL.
    @discardableResult
    public func openWithPanel() -> URL? {
        guard let url = MyaeEditorController.presentOpenPanel() else { return nil }
        try? load(from: url)
        return url
    }

    /// Save to `fileURL`, or present a Save panel if the document has no file yet.
    public func save() {
        guard let url = fileURL else { saveAsWithPanel(); return }
        save(to: url)
    }

    /// Save to a specific URL, binding the document to it on success. Returns
    /// `false` (and leaves the document dirty and unbound) when the write fails.
    @discardableResult
    public func save(to url: URL) -> Bool {
        let markdown = SegmentCodec.encode(document.segments)
        // Through the serial queue so an older queued autosave can never land
        // after (and overwrite) this newer manual save.
        var ok = false
        MyaeEditorController.saveQueue.sync {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                ok = true
            } catch {
                NSLog("[MyaeEditorController] Save failed: %@", error.localizedDescription)
            }
        }
        guard ok else { return false }
        fileURL = url
        document.imageFileDirectory = url.deletingLastPathComponent()
        lastSaved = markdown
        setDirty(false)
        onSave?(url)
        return true
    }

    /// Present a Save panel and write Markdown to the chosen location. Returns
    /// `nil` when cancelled or when the write fails.
    @discardableResult
    public func saveAsWithPanel() -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "document.md"
        panel.allowedContentTypes = [.markdown]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return save(to: url) ? url : nil
    }

    /// Block until every queued write (including any in-flight autosave) lands on
    /// disk. Call before quitting.
    public func flushPendingWrites() {
        MyaeEditorController.saveQueue.sync {}
    }

    /// Present an Open panel scoped to Markdown files and return the chosen URL.
    /// Static so an app can pick a file before any controller/window exists.
    public static func presentOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: Autosave & dirty tracking

    private func observeEdits() {
        // Any content mutation marks the document dirty (cheap — no encode).
        document.didEdit
            .sink { [weak self] in self?.setDirty(true) }
            .store(in: &cancellables)
    }

    private func armAutosave() {
        // Rebuild the subscription set from scratch (drops the prior sinks and
        // terminate observer, then re-adds the edit observer).
        cancellables.removeAll()
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        observeEdits()

        // The debounced settle runs regardless of the autosave policy: onChange
        // (and the markdown-binding write-back that rides on it) must fire even
        // when nothing is written to disk.
        document.didEdit
            .debounce(for: .seconds(autosave.debounce), scheduler: RunLoop.main)
            .sink { [weak self] in self?.editsSettled() }
            .store(in: &cancellables)

        guard autosave.isEnabled else { return }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.editsSettled(synchronous: true) }
        }
    }

    /// Runs after edits settle (debounced): fires `onChange`, refreshes the dirty
    /// flag, and — when autosave is enabled — writes only if the Markdown actually
    /// changed. `encode` reads the live `@Observable` blocks, so it runs on the
    /// main actor; only the write is handed to `saveQueue`.
    private func editsSettled(synchronous: Bool = false) {
        let markdown = SegmentCodec.encode(document.segments)
        onChange?(self)
        guard markdown != lastSaved else {
            setDirty(false)   // edits round-tripped back to the saved text
            if synchronous { MyaeEditorController.saveQueue.sync {} }   // flush in-flight write
            return
        }
        // With autosave off (or an unsaved doc with no store) the document stays
        // dirty until an explicit save.
        guard autosave.isEnabled, fileURL != nil || autosave.store != nil else { return }
        lastSaved = markdown
        let url = fileURL
        let store = autosave.store
        // Only clear the dirty flag (and announce the save) once the write has
        // actually landed; a failed write stays dirty and retries on next settle.
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            if ok {
                self.setDirty(false)
                self.onSave?(url)
            } else {
                self.lastSaved = ""   // force the next settle to retry the write
            }
        }
        if synchronous {
            var ok = false
            MyaeEditorController.saveQueue.sync {
                ok = MyaeEditorController.write(markdown, to: url, store: store)
            }
            finish(ok)
        } else {
            MyaeEditorController.saveQueue.async {
                let ok = MyaeEditorController.write(markdown, to: url, store: store)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { finish(ok) }
                }
            }
        }
    }

    private func setDirty(_ value: Bool) {
        guard isDirty != value else { return }
        isDirty = value
        onDirtyChange?(value)
    }

    // MARK: Content loading (binding form)

    private func loadContent(_ markdown: String) {
        document.replaceAll(SegmentCodec.decode(markdown))
        lastSaved = SegmentCodec.encode(document.segments)
        setDirty(false)
    }

    private func configureImageBase() {
        document.imageFileDirectory = nil
        document.imageFallbackDirectory = autosave.store?.directory ?? MarkdownStore.default.directory
    }

    // MARK: Disk writes

    /// Serial queue for all disk writes. A single FIFO queue guarantees writes
    /// land in the order they were issued, so a slow background autosave can never
    /// overwrite a newer manual save.
    private static let saveQueue = DispatchQueue(label: "app.myanmars.myaeeditorkit.save", qos: .utility)

    /// Write `markdown` to `url` (or `store` when `url` is nil). Returns whether
    /// the write succeeded. Must run on `saveQueue`.
    nonisolated private static func write(_ markdown: String,
                                          to url: URL?,
                                          store: MarkdownStore?) -> Bool {
        if let url {
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                NSLog("[MyaeEditorController] Autosave failed: %@", error.localizedDescription)
                return false
            }
        }
        if let store { return store.saveMarkdown(markdown) }
        return false   // nowhere to write (guarded against upstream)
    }

    // MARK: Helpers

    /// A fresh, empty document: a single blank text segment the caret can land in.
    static func blankSegments() -> [Segment] {
        [Segment.emptyText()]
    }
}
