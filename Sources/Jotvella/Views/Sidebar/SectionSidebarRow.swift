import SwiftUI
import UniformTypeIdentifiers

/// A reorderable sidebar row for a section, with icon picker, rename, delete,
/// export, and drag-and-drop support.
struct SectionSidebarRow: View {
    let section: NoteSection
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onSetIcon: (String) -> Void
    let onExportPDF: () -> Void
    let onDrag: () -> NSItemProvider
    let onDrop: ([NSItemProvider]) -> Bool

    @State private var isHovered = false
    @State private var isShowingIconPicker = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 22)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .help("Drag to reorder section")

            Button {
                isShowingIconPicker.toggle()
            } label: {
                Image(systemName: section.iconSymbol)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(SectionIconPalette.tint)
            }
            .buttonStyle(.plain)
            .help("Choose section icon")
            .popover(isPresented: $isShowingIconPicker) {
                SectionIconPicker(selectedSymbol: section.iconSymbol) { symbol in
                    onSetIcon(symbol)
                    isShowingIconPicker = false
                }
            }

            Button(action: onSelect) {
                Text(section.name)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onRename) {
                Image(systemName: "pencil")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Rename section")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Delete section")
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .onHover { isHovered = $0 }
        .onDrag(onDrag)
        .onDrop(of: [UTType.utf8PlainText], isTargeted: $isDropTargeted) { providers in
            onDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2)
                    .padding(.leading, 34)
                    .padding(.trailing, 17)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button("Export Section to PDF…", systemImage: "doc.richtext", action: onExportPDF)
            Button("Delete Section", systemImage: "trash", role: .destructive, action: onDelete)
                .tint(.red)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.13) : Color.clear)
                .padding(.leading, 34)
                .padding(.trailing, 17)
        )
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
