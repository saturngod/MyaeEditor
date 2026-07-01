//
//  MyaeEditorApp.swift
//  MyaeEditor
//

import SwiftUI

@main
struct MyaeEditorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") {
                    NotificationCenter.default.post(name: .openMarkdown, object: nil)
                }
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
    }
}
