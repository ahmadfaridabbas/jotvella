import SwiftUI

/// Shared tint used across sidebar icons and labels.
enum SectionIconPalette {
    static let tint = Color.white
}

/// A compact grid for picking a section's SF Symbol icon.
struct SectionIconPicker: View {
    let selectedSymbol: String
    let onSelect: (String) -> Void

    private let symbols = [
        "briefcase", "house", "building.2", "person.2", "graduationcap", "book.closed", "lightbulb", "wrench.and.screwdriver",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Section Icon")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 5), count: 8), spacing: 5) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        onSelect(symbol)
                    } label: {
                        Image(systemName: symbol)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(SectionIconPalette.tint)
                            .frame(width: 34, height: 34)
                            .background(selectedSymbol == symbol ? SectionIconPalette.tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .help(symbol.replacingOccurrences(of: ".", with: " "))
                    .accessibilityLabel("Select \(symbol.replacingOccurrences(of: ".", with: " ")) icon")
                }
            }
        }
        .padding(14)
        .frame(width: 326)
    }
}
