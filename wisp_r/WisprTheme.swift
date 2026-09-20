import SwiftUI

/// The looks the app can wear.
enum WisprThemeKind: String, CaseIterable, Identifiable {
    /// Soft grey, rounded glass cards.
    case standard
    /// wspr as it was: black, hairlines, and a bitmap terminal font.
    case legacy
    /// Ink on newsprint: serif type, squared columns and printed rules.
    case newspaper

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Default"
        case .legacy: "Legacy"
        case .newspaper: "Newspaper"
        }
    }

    var blurb: String {
        switch self {
        case .standard: "Soft grey with rounded glass cards."
        case .legacy: "Black, hairline rules and a bitmap terminal font."
        case .newspaper: "Ink on newsprint: serif type and squared columns."
        }
    }

    /// The only light theme so far, so everything system-drawn — keyboards,
    /// pickers, the text cursor — has to be told.
    var colorScheme: ColorScheme {
        switch self {
        case .standard, .legacy: .dark
        case .newspaper: .light
        }
    }
}

// MARK: - Type

extension WisprThemeKind {
    func font(size: CGFloat, weight: Font.Weight) -> Font {
        switch self {
        case .standard:
            .system(size: size, weight: weight)
        case .legacy:
            // A terminal font has one weight, and asking for another only
            // smears it. Gohu also runs small for its point size, hence the
            // nudge upwards.
            .custom(Self.legacyFaceName(for: size), size: size * 1.02)
        case .newspaper:
            .system(size: size, weight: weight, design: .serif)
        }
    }

    /// Gohu is a bitmap face drawn at two sizes; picking the nearer of the two
    /// keeps small text from turning to mush.
    private static func legacyFaceName(for size: CGFloat) -> String {
        size < 15 ? "GohuFont11NFM" : "GohuFont14NFM"
    }
}

/// The kinds of text that can be sized apart from one another.
enum WisprTextRole: String, CaseIterable, Identifiable {
    /// Buttons, rows and captions: the app's furniture, left at one size.
    case interface
    /// The name of the day, the moment, the app.
    case header
    /// What is being written, inside the note editor.
    case editor
    /// A note as it reads on the day view.
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interface: "Interface"
        case .header: "Headers"
        case .editor: "Editor"
        case .note: "Notes"
        }
    }
}

/// Metrics shared by editable note text and its rendered day-card form.
enum NoteTextMetrics {
    static let bodySize: CGFloat = 17
    static let titleSize: CGFloat = 20
    static let lineSpacing: CGFloat = 2
    static let blockSpacing: CGFloat = 2
    static let checklistMarkSize: CGFloat = 23
    /// The ballot-box glyph needs a larger em square than the drawn checkbox
    /// on a day card to have the same visible footprint inside TextEditor.
    static let editorChecklistMarkSize: CGFloat = 32
    static let checklistSpacing: CGFloat = 10
    static let checklistVerticalPadding: CGFloat = 6
    static let indentWidth: CGFloat = 18
    /// Text controls render the bitmap face smaller than static `Text` at the
    /// same point size. This keeps their visible cap height aligned.
    static var editorOpticalScale: CGFloat {
        AppSettings.shared.theme == .legacy ? 1.4 : 1
    }

    static var editorChecklistAdvance: CGFloat {
        editorChecklistMarkSize * AppSettings.shared.textSize(for: .note).scale
            + checklistSpacing
    }
}

/// How much larger or smaller than drawn one kind of text is set.
enum WisprTextSize: String, CaseIterable, Identifiable {
    case smaller
    case small
    case standard
    case large
    case larger
    case largest

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .smaller: 0.85
        case .small: 0.92
        case .standard: 1
        case .large: 1.12
        case .larger: 1.25
        case .largest: 1.4
        }
    }

    var title: String {
        switch self {
        case .smaller: "Smaller"
        case .small: "Small"
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        case .largest: "Largest"
        }
    }
}

extension Font {
    /// The app's type, in whichever theme is on and at whatever size that kind
    /// of text has been set to.
    static func wispr(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        role: WisprTextRole = .interface
    ) -> Font {
        let settings = AppSettings.shared
        return settings.theme.font(size: size * settings.textSize(for: role).scale, weight: weight)
    }
}

// MARK: - Palette

extension WisprThemeKind {
    /// What text, symbols and rules are drawn in. Every foreground in the app
    /// goes through this rather than naming a colour, so a light theme is a
    /// matter of the palette rather than of every view.
    var ink: Color {
        switch self {
        case .standard, .legacy: .white
        case .newspaper: Color(red: 0.11, green: 0.10, blue: 0.09)
        }
    }

    /// Text and symbols drawn over the fixed dark timeline colours.
    var onAccent: Color { .white }

    /// The fill behind grouped rows and note cards.
    var cardFill: Color {
        switch self {
        case .standard: Color.white.opacity(0.05)
        case .legacy: Color.white.opacity(0.03)
        // A cleaner sheet laid on the newsprint, not a shade of it.
        case .newspaper: Color(red: 0.97, green: 0.96, blue: 0.93)
        }
    }

    /// Legacy and newspaper draw boxes rather than filling them.
    var cardBorder: Color? {
        switch self {
        case .standard: nil
        case .legacy: Color.white.opacity(0.22)
        case .newspaper: ink.opacity(0.26)
        }
    }

    /// Legacy outlines a sheet the way it outlines a note, so the sheet reads
    /// as a box laid over the day rather than a panel floating above it.
    var sheetCornerRadius: CGFloat? {
        switch self {
        case .standard: nil
        case .legacy, .newspaper: 0
        }
    }

    var separator: Color {
        switch self {
        case .standard: Color.white.opacity(0.08)
        case .legacy: Color.white.opacity(0.18)
        // The printed rule between columns.
        case .newspaper: ink.opacity(0.28)
        }
    }

    var secondaryText: Color {
        switch self {
        case .standard: Color.white.opacity(0.42)
        case .legacy: Color.white.opacity(0.45)
        case .newspaper: ink.opacity(0.55)
        }
    }

    /// Legacy keeps its corners nearly square; a newspaper has none at all.
    func cornerRadius(_ requested: CGFloat) -> CGFloat {
        switch self {
        case .standard: requested
        case .legacy: min(requested, 4)
        case .newspaper: 0
        }
    }

    var usesGlass: Bool { self == .standard }
}

/// The backdrop shared by every screen.
struct WisprBackground: View {
    private var theme: WisprThemeKind { AppSettings.shared.theme }

    var body: some View {
        Group {
            switch theme {
            case .standard:
                LinearGradient(
                    colors: [
                        Color(red: 0.27, green: 0.27, blue: 0.28),
                        Color(red: 0.23, green: 0.23, blue: 0.24),
                        Color(red: 0.19, green: 0.185, blue: 0.195)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .legacy:
                Color.black
            case .newspaper:
                // Newsprint is never one flat colour; the page is slightly
                // warmer where it has been handled.
                LinearGradient(
                    colors: [
                        Color(red: 0.94, green: 0.93, blue: 0.89),
                        Color(red: 0.91, green: 0.89, blue: 0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
    }
}

extension Color {
    /// What text, symbols and rules are drawn in, whichever theme is on.
    static var wisprInk: Color { AppSettings.shared.theme.ink }
    /// Foreground used on the app's fixed dark accent colours.
    static var wisprOnAccent: Color { AppSettings.shared.theme.onAccent }
    /// The translucent fill used by grouped rows and note cards.
    static var wisprCard: Color { AppSettings.shared.theme.cardFill }
    /// The hairline used between rows inside a card.
    static var wisprSeparator: Color { AppSettings.shared.theme.separator }
    /// The muted tone used by section headers and secondary text.
    static var wisprSecondaryText: Color { AppSettings.shared.theme.secondaryText }
}

// MARK: - Surfaces

extension View {
    /// Wraps content in the card used for grouped rows and smaller surfaces
    /// inside a note.
    func wisprCardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(WisprCard(cornerRadius: cornerRadius, isGlass: false))
    }

    /// The surface a note card sits on: Liquid Glass, or a drawn box.
    ///
    /// The content is clipped first so pictures follow the corners, then the
    /// glass is applied behind it, as the effect expects to come last.
    func wisprGlassCard(cornerRadius: CGFloat = 14) -> some View {
        modifier(WisprCard(cornerRadius: cornerRadius, isGlass: true))
    }
}

extension View {
    /// How a sheet meets the screen. The default theme keeps the system's
    /// rounded corners; legacy squares the top off and draws the same hairline
    /// a note card wears, so the sheet stands apart from the black behind it.
    func wisprSheetEdge(cornerRadius: CGFloat = 20) -> some View {
        modifier(WisprSheetEdge(cornerRadius: cornerRadius))
    }
}

private struct WisprSheetEdge: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let theme = AppSettings.shared.theme

        content
            .overlay {
                if theme.sheetCornerRadius != nil, let border = theme.cardBorder {
                    SheetOutline()
                        .stroke(border, lineWidth: 1)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .presentationCornerRadius(theme.sheetCornerRadius ?? cornerRadius)
            .presentationDragIndicator(.hidden)
    }
}

/// Three sides of a sheet. The bottom runs off the screen, so it is left open.
private struct SheetOutline: Shape {
    func path(in rect: CGRect) -> Path {
        // Half a point in, so the full width of the line lands inside the sheet
        // rather than half of it being clipped away.
        let inset: CGFloat = 0.5
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        return path
    }
}

private struct WisprCard: ViewModifier {
    let cornerRadius: CGFloat
    let isGlass: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let theme = AppSettings.shared.theme
        let radius = theme.cornerRadius(cornerRadius)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        if isGlass, theme.usesGlass {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: .rect(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(theme.cardFill)
                .clipShape(shape)
                .overlay {
                    if let border = theme.cardBorder {
                        shape.stroke(border, lineWidth: 1)
                    }
                }
        }
    }
}
