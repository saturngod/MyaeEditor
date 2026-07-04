//
//  BlockActionMenu.swift
//  MyaeEditor
//
//  The popover that opens when you click a block's drag handle ("=").
//  A searchable list of actions plus type-specific options
//  (e.g. a table's header-row / header-column toggles).
//

import SwiftUI

struct BlockActionMenu: View {
    @Bindable var document: EditorDocument
    @Bindable var block: Block
    let onDismiss: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Search actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .focused($searchFocused)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if block.kind.isTextual {
                        sectionHeader("Turn into")
                        ForEach(BlockKind.convertible.filter { $0 != block.kind }) { kind in
                            actionRow(kind.title, systemImage: kind.systemImage) {
                                document.changeKind(of: block, to: kind); onDismiss()
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }

                    if block.kind == .table, let table = block.table {
                        sectionHeader("Table")
                        toggleRow("Header row", systemImage: "tablecells",
                                  isOn: Binding(get: { table.hasHeaderRow },
                                                set: { table.hasHeaderRow = $0 }))
                        toggleRow("Header column", systemImage: "tablecells.badge.ellipsis",
                                  isOn: Binding(get: { table.hasHeaderColumn },
                                                set: { table.hasHeaderColumn = $0 }))
                        Divider().padding(.vertical, 4)
                    }

                    actionRow("Duplicate", systemImage: "plus.square.on.square") {
                        document.duplicate(block); onDismiss()
                    }
                    actionRow("Delete", systemImage: "trash", role: .destructive) {
                        document.removeBlock(block); onDismiss()
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 260)
            .frame(maxHeight: 320)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .onAppear { searchFocused = true }
    }

    // MARK: Rows

    private func matches(_ title: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || title.lowercased().contains(q)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if matchesSection(title) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)
        }
    }

    // Show section headers only when not actively filtering.
    private func matchesSection(_ title: String) -> Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty || matches(title)
    }

    @ViewBuilder
    private func toggleRow(_ title: String, systemImage: String, isOn: Binding<Bool>) -> some View {
        if matches(title) {
            Toggle(isOn: isOn) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    @ViewBuilder
    private func actionRow(_ title: String, systemImage: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        if matches(title) {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(role == .destructive ? Color.red : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
    }
}
