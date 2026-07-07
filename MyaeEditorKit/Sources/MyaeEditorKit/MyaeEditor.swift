//
//  MyaeEditor.swift
//  MyaeEditorKit
//
//  The public editor component. Two ways to use it:
//
//    // Simple — a Markdown binding:
//    MyaeEditor(markdown: $text)
//
//    // Full control — an app-owned controller with file I/O, autosave, dirty state:
//    @State var controller = MyaeEditorController(autosave: .default)
//    MyaeEditor(controller: controller)
//

import SwiftUI

public struct MyaeEditor: View {
    private let externalController: MyaeEditorController?
    private let configuration: MyaeEditorConfiguration

    /// Controller for the binding-based initializer, created once on first
    /// appearance and persisted across re-renders by @State.
    @State private var ownedController: MyaeEditorController?

    /// Optional two-way Markdown binding (binding initializer only).
    private let markdownBinding: Binding<String>?
    private let onChange: ((String) -> Void)?

    // MARK: Initializers

    /// Drive the editor with an app-owned controller. Use this to open/save files,
    /// observe `isDirty`, wire menu commands, or configure autosave.
    public init(controller: MyaeEditorController,
                configuration: MyaeEditorConfiguration = MyaeEditorConfiguration()) {
        self.externalController = controller
        self.configuration = configuration
        self.markdownBinding = nil
        self.onChange = nil
    }

    /// Drive the editor with a plain Markdown binding. A controller is created and
    /// held internally; external writes to `markdown` reload the document, and
    /// edits are written back after they settle (~2s debounce). Note the
    /// round-trip normalizes Markdown via a re-encode.
    public init(markdown: Binding<String>,
                configuration: MyaeEditorConfiguration = MyaeEditorConfiguration(),
                onChange: ((String) -> Void)? = nil) {
        self.externalController = nil
        self.configuration = configuration
        self.markdownBinding = markdown
        self.onChange = onChange
    }

    private var controller: MyaeEditorController? { externalController ?? ownedController }

    // MARK: Body

    public var body: some View {
        ZStack {
            if let controller {
                SegmentEditorView(controller: controller, configuration: configuration)
                    .focusedSceneValue(\.myaeEditor, controller)
                    .modifier(BindingSyncModifier(controller: controller,
                                                  markdown: markdownBinding,
                                                  onChange: onChange))
            }
        }
        .onAppear {
            // Create the owned controller exactly once; @State keeps it across
            // struct re-inits so the live document survives parent re-renders.
            if externalController == nil, ownedController == nil {
                ownedController = MyaeEditorController(markdown: markdownBinding?.wrappedValue ?? "")
            }
        }
    }
}

/// Keeps the optional external Markdown binding in sync with the controller,
/// guarding against feedback loops via the last value the editor pushed.
private struct BindingSyncModifier: ViewModifier {
    let controller: MyaeEditorController
    let markdown: Binding<String>?
    let onChange: ((String) -> Void)?

    @State private var lastPushed: String = ""

    func body(content: Content) -> some View {
        guard markdown != nil || onChange != nil else { return AnyView(content) }
        return AnyView(content.onAppear {
            controller.onChange = { c in
                let encoded = c.markdown
                onChange?(encoded)
                if let markdown, markdown.wrappedValue != encoded {
                    lastPushed = encoded
                    markdown.wrappedValue = encoded
                }
            }
        }
        .onChange(of: markdown?.wrappedValue ?? "") { _, newValue in
            // Only reload when the change originated outside the editor.
            guard newValue != lastPushed, newValue != controller.markdown else { return }
            controller.markdown = newValue
        })
    }
}

public extension FocusedValues {
    /// The focused editor's controller — lets `Commands` (New / Open / Save) target
    /// the key window's document without any NotificationCenter plumbing.
    @Entry var myaeEditor: MyaeEditorController?
}
