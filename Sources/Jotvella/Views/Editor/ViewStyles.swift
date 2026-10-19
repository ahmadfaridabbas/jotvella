import SwiftUI

extension View {
    /// Pill styling used for inline tags.
    func tagStyle() -> some View { self.font(.caption).foregroundStyle(Color.white).padding(.horizontal, 8).padding(.vertical, 5).background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5)) }
}
