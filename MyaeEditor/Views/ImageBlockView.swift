//
//  ImageBlockView.swift
//  MyaeEditor
//
//  An image block. Empty state shows an "Add an image" picker; once set, the
//  image renders inline with a context menu to replace or remove it.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ImageBlockView: View {
    @Bindable var document: EditorDocument
    @Bindable var block: Block

    @State private var hovering = false
    /// Decoded once per image path — never re-read from disk during body eval
    /// (hover, selection, etc.), which for a multi-MB image would hitch.
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 400, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topTrailing) {
                        if hovering {
                            Button { block.imagePath = nil; document.markEdited() } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.5))
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                            .help("Remove image")
                        }
                    }
                    .onHover { hovering = $0 }
                    .contextMenu {
                        Button("Replace…") { pickImage() }
                        Button("Remove", role: .destructive) { block.imagePath = nil; document.markEdited() }
                    }
            } else {
                placeholder
            }
        }
        // Reload only when the path actually changes.
        .task(id: block.imagePath) {
            if let path = block.imagePath {
                image = NSImage(contentsOf: DocumentStore.imageURL(for: path))
            } else {
                image = nil
            }
        }
    }

    private var placeholder: some View {
        Button { pickImage() } label: {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                Text("Add an image")
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4])))
        }
        .buttonStyle(.plain)
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Reference the picked file in place (relative when near the document,
        // absolute otherwise) — don't copy it into the app's store.
        block.imagePath = DocumentStore.referencePath(for: url)
        document.markEdited()
    }
}
