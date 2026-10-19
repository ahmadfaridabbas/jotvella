import SwiftUI

/// The label row for a notebook disclosure group, with star, rename, delete,
/// and "open in Finder" actions.
struct NotebookSidebarLabel: View {
    let notebook: Notebook
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggleStar: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onOpenInFinder: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                Label(notebook.name, systemImage: "books.vertical")
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tint(SectionIconPalette.tint)

            HStack(spacing: 2) {
                Button(action: onToggleStar) {
                    Image(systemName: notebook.isStarred ? "star.fill" : "star")
                        .foregroundStyle(notebook.isStarred ? Color.yellow : Color.secondary)
                        .frame(width: 22, height: 22)
                }
                .help(notebook.isStarred ? "Unstar notebook" : "Star notebook")
                Button(action: onRename) {
                    Image(systemName: "pencil").frame(width: 22, height: 22)
                }
                .help("Rename notebook")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.red).frame(width: 22, height: 22)
                }
                .help("Delete notebook")
            }
            .buttonStyle(.borderless)
            .opacity(isHovered || notebook.isStarred ? 1 : 0)
            .allowsHitTesting(isHovered || notebook.isStarred)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(notebook.isStarred ? "Unstar Notebook" : "Star Notebook", systemImage: notebook.isStarred ? "star.slash" : "star", action: onToggleStar)
            Button("Open in Finder", systemImage: "folder", action: onOpenInFinder)
            Button("Rename Notebook", systemImage: "pencil", action: onRename)
            Button("Delete Notebook", systemImage: "trash", role: .destructive, action: onDelete)
                .tint(.red)
        }
    }
}
