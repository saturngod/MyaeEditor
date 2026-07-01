//
//  MyaeEditorApp.swift
//  MyaeEditor
//

import SwiftUI
import AppKit

@main
struct MyaeEditorApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .frame(minWidth: 600, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .commands {
            FileCommands()
        }
    }
}

/// File menu: New / Open present at the App level so they work even when no
/// window is open (an Open with no window creates one and loads into it).
private struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                if hasDocumentWindow {
                    NotificationCenter.default.post(name: .newDocument, object: nil)
                } else {
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open…") { open() }
                .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                NotificationCenter.default.post(name: .saveMarkdown, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command])

            Button("Save As Markdown…") {
                NotificationCenter.default.post(name: .saveAsMarkdown, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }

    /// A visible editor window (the format bar is an `NSPanel`, so exclude panels).
    private var hasDocumentWindow: Bool {
        NSApp.windows.contains { $0.isVisible && !($0 is NSPanel) }
    }

    /// Present the Open panel, then load the file — into the current window if one
    /// exists, otherwise into a newly created window.
    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdown]   // Markdown editor — .md only
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if hasDocumentWindow {
            NotificationCenter.default.post(name: .openMarkdown, object: url)
        } else {
            LaunchIntent.pendingOpenURL = url
            openWindow(id: "main")
        }
    }
}
