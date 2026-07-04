//
//  MermaidBlockView.swift
//  MyaeEditor
//
//  The rendered face of a `.code` block whose language is `.mermaid`, shown when
//  the block is not focused. Hosts an inline WKWebView (MermaidWebView) that draws
//  the diagram live and reports its height. Tapping re-focuses the block, which
//  flips the row back to the code editor (see BlockRowView's `.code` case).
//

import SwiftUI
import AppKit

struct MermaidBlockView: View {
    @Bindable var document: EditorDocument
    @Bindable var block: Block
    @Environment(\.colorScheme) private var colorScheme

    @State private var height: CGFloat = 44
    @State private var errorMessage: String?
    @State private var hovering = false
    @State private var justCopied = false

    private var theme: MermaidTheme { MermaidTheme(colorScheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            card
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .padding(.top, 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { enterEditMode() }
        .onHover { hovering = $0 }
    }

    private var card: some View {
        ZStack(alignment: .topTrailing) {
            MermaidWebView(source: block.plainText,
                           theme: theme,
                           backgroundHex: "transparent",   // let the card fill show through
                           height: $height,
                           errorMessage: $errorMessage)
                .frame(height: max(44, height))
                .frame(maxWidth: .infinity, alignment: .leading)
                .allowsHitTesting(false)   // never let the web view grab clicks

            // Transparent catcher above the web view: a click anywhere enters edit mode.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { enterEditMode() }

            hoverControls   // on top, keeps its own buttons clickable
        }
        .padding(12)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1))
    }

    @ViewBuilder
    private var hoverControls: some View {
        if hovering {
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(block.plainText, forType: .string)
                    withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeInOut(duration: 0.2)) { justCopied = false }
                    }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(justCopied ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy code")

                Button { enterEditMode() } label: {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit diagram")
            }
            .font(.system(size: 12))
            .padding(6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .allowsHitTesting(true)   // buttons stay clickable above the tap catcher
        }
    }

    private func enterEditMode() {
        document.clearSelection()
        document.focusedBlockID = block.id
    }
}
