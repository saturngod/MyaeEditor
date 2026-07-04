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

    var body: some View {
        ZStack {
            if let controller {
                MyaeEditor(controller: controller,
                           configuration: MyaeEditorConfiguration(showsTitleField: false))
            }
        }
        .onAppear {
            if controller == nil { controller = ContentView.makeController() }
        }
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
