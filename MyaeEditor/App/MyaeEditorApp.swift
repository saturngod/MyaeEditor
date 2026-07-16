//
//  MyaeEditorApp.swift
//  MyaeEditor
//

import SwiftUI
import AppKit
import MyaeEditorKit

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

/// File menu: New / Open / Save routed to the focused window's editor controller
/// via `@FocusedValue`. New / Open still work with no window open (Open with no
/// window stages the file and creates one).
private struct FileCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.myaeEditor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") {
                if let editor {
                    editor.newDocument()
                } else {
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Open…") {
                guard let url = MyaeEditorController.presentOpenPanel() else { return }
                if let editor {
                    try? editor.load(from: url)
                } else {
                    AppLaunchIntent.pendingOpenURL = url
                    openWindow(id: "main")
                }
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                if let editor { Task { await editor.saveAsync() } }
            }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(editor == nil)

            Button("Save As Markdown…") {
                if let editor { Task { await editor.saveAsWithPanelAsync() } }
            }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(editor == nil)
        }
    }
}
