import SwiftUI

/// The dark gradient backdrop shared by every screen.
struct WisprBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.27, green: 0.27, blue: 0.28),
                Color(red: 0.23, green: 0.23, blue: 0.24),
                Color(red: 0.19, green: 0.185, blue: 0.195)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

extension Color {
    /// The translucent fill used by grouped rows and note cards.
    static let wisprCard = Color.white.opacity(0.05)
    /// The hairline used between rows inside a card.
    static let wisprSeparator = Color.white.opacity(0.08)
    /// The muted tone used by section headers and secondary text.
    static let wisprSecondaryText = Color.white.opacity(0.42)
}

extension View {
    /// Wraps content in the rounded translucent card used for grouped rows and
    /// smaller surfaces inside a note.
    func wisprCardBackground(cornerRadius: CGFloat = 14) -> some View {
        background(Color.wisprCard)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The Liquid Glass surface a note card sits on.
    ///
    /// The content is clipped first so pictures follow the corners, then the
    /// glass is applied behind it, as the effect expects to come last.
    func wisprGlassCard(cornerRadius: CGFloat = 14) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }
}
