//
//  MyaeEditorConfiguration.swift
//  MyaeEditorKit
//
//  Feature flags and layout knobs for a `MyaeEditor`. Every flag maps to a cheap
//  guard at an existing call site — nothing here changes the document model.
//

import SwiftUI

public struct MyaeEditorConfiguration: Sendable {
    /// Show the large document-title field above the first block.
    public var showsTitleField: Bool
    /// Let the editor update its hosting window's title and proxy icon.
    public var managesWindowTitle: Bool

    /// Maximum width of the text column (points).
    public var maxContentWidth: CGFloat
    /// Horizontal inset around the text column (points).
    public var horizontalPadding: CGFloat
    /// Vertical inset around the text column (points).
    public var verticalPadding: CGFloat

    /// Enable the "/" slash command menu.
    public var showsSlashMenu: Bool
    /// Enable the floating bold/italic/strike/code format bar on selection.
    public var showsFormatBar: Bool
    /// Enable drag-to-reorder of blocks.
    public var allowsDragReorder: Bool
    /// Enable the drag-handle block action menu ("Turn into", duplicate, …).
    public var showsBlockActionMenu: Bool
    /// Render mermaid code blocks as diagrams. When off they stay as code blocks.
    public var rendersMermaid: Bool

    /// Whether the document can be edited. `false` = read-only viewer.
    public var isEditable: Bool

    /// Font family name used for body/heading text, or `nil` for the system font.
    /// Applied process-wide (see `EditorFont`); when several editors are shown
    /// at once the last configuration written wins.
    public var fontFamilyName: String?
    /// Font family name used for code blocks and inline code, or `nil` for the
    /// system monospaced font. Applied process-wide, like `fontFamilyName`.
    public var codeFontFamilyName: String?

    public init(
        showsTitleField: Bool = true,
        managesWindowTitle: Bool = true,
        maxContentWidth: CGFloat = 720,
        horizontalPadding: CGFloat = 60,
        verticalPadding: CGFloat = 40,
        showsSlashMenu: Bool = true,
        showsFormatBar: Bool = true,
        allowsDragReorder: Bool = true,
        showsBlockActionMenu: Bool = true,
        rendersMermaid: Bool = true,
        isEditable: Bool = true,
        fontFamilyName: String? = nil,
        codeFontFamilyName: String? = nil
    ) {
        self.showsTitleField = showsTitleField
        self.managesWindowTitle = managesWindowTitle
        self.maxContentWidth = maxContentWidth
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.showsSlashMenu = showsSlashMenu
        self.showsFormatBar = showsFormatBar
        self.allowsDragReorder = allowsDragReorder
        self.showsBlockActionMenu = showsBlockActionMenu
        self.rendersMermaid = rendersMermaid
        self.isEditable = isEditable
        self.fontFamilyName = fontFamilyName
        self.codeFontFamilyName = codeFontFamilyName
    }
}

/// Internal environment plumbing so deep block views (slash menu, format bar,
/// mermaid, editability) can read the configuration without threading it through
/// every view initializer.
extension EnvironmentValues {
    @Entry var myaeConfiguration: MyaeEditorConfiguration = MyaeEditorConfiguration()
}
