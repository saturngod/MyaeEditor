//
//  SlashMenu.swift
//  MyaeEditor
//
//  The "/" command menu for picking a block type. Filters as you type.
//

import SwiftUI

struct SlashMenu: View {
    @Binding var query: String
    /// Hoisted to the owning row: keyboard focus stays in the block's text view
    /// while this popover is open, so Enter/arrows arrive there — the row drives
    /// this selection and chooses from `results(for:)` itself.
    @Binding var selection: Int
    let onSelect: (BlockKind) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool

    static func results(for query: String) -> [BlockKind] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return BlockKind.allCases }
        return BlockKind.allCases.filter {
            $0.title.lowercased().contains(q) || $0.rawValue.lowercased().contains(q)
        }
    }

    private var results: [BlockKind] { Self.results(for: query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Filter…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .focused($searchFocused)
                .onSubmit { choose() }
                .onChange(of: query) { selection = 0 }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, kind in
                            row(kind, selected: idx == selection)
                                .id(kind.id)
                                .onTapGesture { onSelect(kind) }
                                .onHover { if $0 { selection = idx } }
                        }
                        if results.isEmpty {
                            Text("No results")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(width: 300, height: 260)
                .onChange(of: selection) {
                    if results.indices.contains(selection) {
                        proxy.scrollTo(results[selection].id, anchor: .center)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onAppear { searchFocused = true }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) { choose(); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private func row(_ kind: BlockKind, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title)
                    .font(.system(size: 13, weight: .medium))
                Text(kind.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func choose() {
        guard results.indices.contains(selection) else { return }
        onSelect(results[selection])
    }
}
