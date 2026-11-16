import SwiftUI

/// A compact row of tag chips under the page title, with a field to add more.
struct TagBar: View {
    let tags: [String]
    let onChange: ([String]) -> Void
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text("#\(tag)").font(.caption.weight(.medium))
                    Button { onChange(tags.filter { $0 != tag }) } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Remove tag")
                    .accessibilityLabel("Remove tag \(tag)")
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 22)
                .background(Color.primary.opacity(0.07), in: Capsule())
            }
            TextField(tags.isEmpty ? "Add tag" : "+", text: $draft)
                .textFieldStyle(.plain)
                .font(.caption)
                .frame(width: tags.isEmpty ? 70 : 40)
                .focused($draftFocused)
                .onSubmit(commit)
                .help("Type a tag and press Return")
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }

    private func commit() {
        let value = TagText.normalized(draft)
        draft = ""
        guard !value.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            draftFocused = true
            return
        }
        onChange(tags + [value])
        draftFocused = true
    }
}
