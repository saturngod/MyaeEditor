//
//  ContentView.swift
//  MyaeEditor
//
//  Hosts one editor per window. Owns the launch/restore policy: the first window
//  of a launch restores the autosaved document (or loads a file staged by Open
//  with no window); later windows open blank.
//

import SwiftUI
import MyaeEditorKit

/// One-shot launch state shared across windows. `pendingOpenURL` stages a file
/// chosen by Open when no window exists yet; `didRestore` ensures only the first
/// window restores the autosaved document.
enum AppLaunchIntent {
    static var pendingOpenURL: URL?
    static var didRestore = false
}

struct ContentView: View {
    /// Created in onAppear, not as the @State default value — SwiftUI may build
    /// and discard view values multiple times, and makeController() has one-shot
    /// side effects (consuming pendingOpenURL, flipping didRestore) that must run
    /// exactly once per window.
    @State private var controller: MyaeEditorController?

    /// Sample font setting. `MyaeEditorKit` ships no settings UI — this shows how
    /// a host app can offer one. The editor's fonts are process-wide, so the
    /// setting is stored app-wide with `@AppStorage` (shared across every window)
    /// rather than per-window `@State`, which would let two windows fight over
    /// the one global font. Empty string means "use the system font".
    @AppStorage("myae.bodyFont") private var bodyFont = ""
    @AppStorage("myae.codeFont") private var codeFont = ""

    private static let bodyFonts = ["System", "Helvetica Neue", "Georgia", "Avenir Next"]
    private static let codeFonts = ["System Mono", "Menlo", "SF Mono", "Courier New"]

    var body: some View {
        VStack(spacing: 0) {
            fontPickerBar
            ZStack {
                if let controller {
                    MyaeEditor(controller: controller,
                               configuration: MyaeEditorConfiguration(
                                   showsTitleField: false,
                                   fontFamilyName: bodyFont.isEmpty ? nil : bodyFont,
                                   codeFontFamilyName: codeFont.isEmpty ? nil : codeFont))
                }
            }
        }
        .onAppear {
            if controller == nil { controller = ContentView.makeController() }
        }
    }

    /// Two menus that drive `MyaeEditorConfiguration.fontFamilyName` /
    /// `codeFontFamilyName` at runtime. Changing either value rebuilds the
    /// configuration passed into `MyaeEditor`, which re-decodes the open
    /// document with the new fonts baked in — no reopen required.
    private var fontPickerBar: some View {
        HStack {
            Picker("Font", selection: $bodyFont) {
                ForEach(Self.bodyFonts, id: \.self) { name in
                    Text(name).tag(name == "System" ? "" : name)
                }
            }
            Picker("Code Font", selection: $codeFont) {
                ForEach(Self.codeFonts, id: \.self) { name in
                    Text(name).tag(name == "System Mono" ? "" : name)
                }
            }
            Spacer()
        }
        .padding(8)
    }

    /// Build the controller for a new window per the restore policy.
    private static func makeController() -> MyaeEditorController {
        let autosave = AutosavePolicy.default   // ~/Library/Application Support/MyaeEditor

        if let url = AppLaunchIntent.pendingOpenURL {
            // Open was invoked with no window — load the chosen file here.
            AppLaunchIntent.pendingOpenURL = nil
            AppLaunchIntent.didRestore = true
            return (try? MyaeEditorController(contentsOf: url, autosave: autosave))
                ?? MyaeEditorController(autosave: autosave)
        }

        if !AppLaunchIntent.didRestore,
           let restored = MyaeEditorController(restoringFrom: .default, autosave: autosave) {
            // First window of the launch restores the autosaved document.
            AppLaunchIntent.didRestore = true
            return restored
        }

        // Any later window (or an empty store) starts blank.
        AppLaunchIntent.didRestore = true
        return MyaeEditorController(autosave: autosave)
    }
}

#Preview {
    ContentView().frame(width: 800, height: 700)
}
