import SwiftUI

// MARK: - Marks

/// A timeline's icon on its coloured ground, as it reads in the menu.
struct TimelineMark: View {
    let timeline: NoteTimeline
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: timeline.icon)
            .font(.wispr(size * 0.55))
            .foregroundStyle(Color.wisprOnAccent)
            .frame(width: size, height: size)
            .background(timeline.tint.fill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A group's folder, with its own symbol set inside it.
struct TimelineGroupMark: View {
    let icon: String
    var size: CGFloat = 26

    var body: some View {
        ZStack {
            Image(systemName: "folder.fill")
                .font(.wispr(size * 0.82))
                .foregroundStyle(Color.wisprInk.opacity(0.85))

            // Sits in the body of the folder rather than its centre, which the
            // tab above pulls upwards.
            Image(systemName: icon)
                .font(.wispr(size * 0.3, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.7))
                .offset(y: size * 0.09)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Pickers

/// The symbols a timeline or group can be marked with.
enum TimelineIconCatalogue {
    static let all: [String] = [
        "circle.fill", "star.fill", "heart.fill", "bolt.fill", "flame.fill", "leaf.fill",
        "person.2.fill", "figure.walk", "house.fill", "building.2.fill", "airplane", "car.fill",
        "map.fill", "mappin", "globe", "sun.max.fill", "moon.fill", "cloud.fill",
        "book.fill", "graduationcap.fill", "briefcase.fill", "hammer.fill", "wrench.fill", "paintbrush.fill",
        "chevron.left.forwardslash.chevron.right", "terminal.fill", "desktopcomputer", "gamecontroller.fill", "camera.fill", "photo.fill",
        "music.note", "headphones", "mic.fill", "film.fill", "fork.knife", "cup.and.saucer.fill",
        "cart.fill", "creditcard.fill", "gift.fill", "bag.fill", "dumbbell.fill", "bicycle",
        "pawprint.fill", "tree.fill", "drop.fill", "pills.fill", "cross.case.fill", "checkmark.seal.fill"
    ]
}

/// A grid of symbols, one of which is chosen.
struct TimelineIconPicker: View {
    @Binding var icon: String
    var tint: Color = Color.wisprInk.opacity(0.14)

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(TimelineIconCatalogue.all, id: \.self) { candidate in
                Button {
                    icon = candidate
                } label: {
                    Image(systemName: candidate)
                        .font(.wispr(16))
                        .foregroundStyle(Color.wisprInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            candidate == icon ? tint : Color.wisprInk.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay {
                            if candidate == icon {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.wisprInk.opacity(0.7), lineWidth: 1.5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate)
                .accessibilityAddTraits(candidate == icon ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// The colours a timeline can be given.
struct TimelineTintPicker: View {
    @Binding var tint: TimelineTint

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(TimelineTint.allCases) { candidate in
                Button {
                    tint = candidate
                } label: {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(candidate.fill)
                        .frame(height: 38)
                        .overlay {
                            if candidate == tint {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.wisprInk, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(candidate.rawValue)
                .accessibilityAddTraits(candidate == tint ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

// MARK: - Timeline editor

/// Creates a timeline, or edits one that exists: its name, colour, symbol and
/// the group it is filed under.
struct TimelineEditorSheet: View {
    /// The timeline being edited; `nil` creates a new one.
    var editing: NoteTimeline?
    /// Called with the saved timeline, for callers that want to use it straight
    /// away — assigning it to the note that created it, say.
    var onSave: ((NoteTimeline) -> Void)?

    @Environment(TimelineStore.self) private var timelines
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String
    @State private var tint: TimelineTint
    @State private var groupID: UUID?

    init(editing: NoteTimeline? = nil, onSave: ((NoteTimeline) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _icon = State(initialValue: editing?.icon ?? "circle.fill")
        _tint = State(initialValue: editing?.tint ?? .slate)
        _groupID = State(initialValue: editing?.groupID)
    }

    private var preview: NoteTimeline {
        NoteTimeline(
            id: editing?.id ?? UUID(),
            name: name,
            icon: icon,
            tint: tint,
            groupID: groupID
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TimelineRowPreview(timeline: preview)

                    field("Name") {
                        TextField("Timeline", text: $name)
                            .font(.wispr(17))
                            .foregroundStyle(Color.wisprInk)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .wisprCardBackground(cornerRadius: 10)
                    }

                    field("Colour") {
                        TimelineTintPicker(tint: $tint)
                    }

                    field("Symbol") {
                        TimelineIconPicker(icon: $icon, tint: tint.fill)
                    }

                    if !timelines.groups.isEmpty {
                        field("Group") {
                            groupPicker
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WisprBackground())
            .navigationTitle(editing == nil ? "New timeline" : "Edit timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.wisprInk)
        .presentationDetents([.large])
        .wisprSheetEdge()
        .preferredColorScheme(.dark)
    }

    private var groupPicker: some View {
        VStack(spacing: 0) {
            groupChoice(nil, title: "No group", icon: nil)

            ForEach(timelines.groups) { group in
                Rectangle()
                    .fill(Color.wisprSeparator)
                    .frame(height: 1)

                groupChoice(group.id, title: group.displayName, icon: group.icon)
            }
        }
        .wisprCardBackground(cornerRadius: 10)
    }

    private func groupChoice(_ id: UUID?, title: String, icon: String?) -> some View {
        Button {
            groupID = id
        } label: {
            HStack(spacing: 12) {
                if let icon {
                    TimelineGroupMark(icon: icon, size: 22)
                } else {
                    Image(systemName: "tray")
                        .font(.wispr(15))
                        .foregroundStyle(Color.wisprSecondaryText)
                        .frame(width: 22, height: 22)
                }

                Text(title)
                    .font(.wispr(16))
                    .foregroundStyle(Color.wisprInk)

                Spacer(minLength: 0)

                if groupID == id {
                    Image(systemName: "checkmark")
                        .font(.wispr(14, weight: .semibold))
                        .foregroundStyle(Color.wisprInk)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func save() {
        var saved = preview
        saved.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        timelines.save(saved)
        onSave?(saved)
        dismiss()
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.wispr(12, weight: .medium))
                .kerning(0.6)
                .foregroundStyle(Color.wisprSecondaryText)
            content()
        }
    }
}

/// The row as it will look in the menu, so a colour and symbol can be judged
/// before they are saved.
private struct TimelineRowPreview: View {
    let timeline: NoteTimeline

    var body: some View {
        HStack(spacing: 12) {
            TimelineMark(timeline: timeline)

            Text(timeline.displayName)
                .font(.wispr(18))
                .foregroundStyle(Color.wisprOnAccent)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(timeline.tint.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Group editor

/// Creates or renames a group, and picks the symbol drawn inside its folder.
struct TimelineGroupEditorSheet: View {
    var editing: TimelineGroup?
    var onSave: ((TimelineGroup) -> Void)?

    @Environment(TimelineStore.self) private var timelines
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String

    init(editing: TimelineGroup? = nil, onSave: ((TimelineGroup) -> Void)? = nil) {
        self.editing = editing
        self.onSave = onSave
        _name = State(initialValue: editing?.name ?? "")
        _icon = State(initialValue: editing?.icon ?? "folder")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        TimelineGroupMark(icon: icon, size: 34)

                        Text(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name)
                            .font(.wispr(18))
                            .foregroundStyle(Color.wisprInk)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .wisprCardBackground(cornerRadius: 12)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("NAME")
                            .font(.wispr(12, weight: .medium))
                            .kerning(0.6)
                            .foregroundStyle(Color.wisprSecondaryText)

                        TextField("Group", text: $name)
                            .font(.wispr(17))
                            .foregroundStyle(Color.wisprInk)
                            .textInputAutocapitalization(.words)
                            .padding(.horizontal, 14)
                            .frame(height: 44)
                            .wisprCardBackground(cornerRadius: 10)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("SYMBOL")
                            .font(.wispr(12, weight: .medium))
                            .kerning(0.6)
                            .foregroundStyle(Color.wisprSecondaryText)

                        TimelineIconPicker(icon: $icon)
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WisprBackground())
            .navigationTitle(editing == nil ? "New group" : "Edit group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        var saved = TimelineGroup(
                            id: editing?.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            icon: icon
                        )
                        saved.name = saved.displayName
                        timelines.save(saved)
                        onSave?(saved)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .tint(Color.wisprInk)
        .presentationDetents([.large])
        .wisprSheetEdge()
        .preferredColorScheme(.dark)
    }
}

// MARK: - Assigning a note

/// Files a note under a timeline, with room to make a new one on the spot.
struct NoteTimelineSheet: View {
    let selection: UUID?
    let onSelect: (UUID?) -> Void

    @Environment(TimelineStore.self) private var timelines
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    choice(
                        title: "No timeline",
                        isSelected: selection == nil,
                        mark: {
                            Image(systemName: "tray")
                                .font(.wispr(15))
                                .foregroundStyle(Color.wisprSecondaryText)
                                .frame(width: 26, height: 26)
                        },
                        action: { pick(nil) }
                    )

                    ForEach(timelines.groups) { group in
                        let members = timelines.timelines(in: group.id)
                        if !members.isEmpty {
                            HStack(spacing: 8) {
                                TimelineGroupMark(icon: group.icon, size: 18)
                                Text(group.displayName.uppercased())
                                    .font(.wispr(12, weight: .medium))
                                    .kerning(0.6)
                                    .foregroundStyle(Color.wisprSecondaryText)
                            }
                            .padding(.top, 6)

                            ForEach(members) { timeline in
                                timelineChoice(timeline)
                            }
                        }
                    }

                    let loose = timelines.ungroupedTimelines
                    if !loose.isEmpty {
                        if !timelines.groups.isEmpty {
                            Text("UNGROUPED")
                                .font(.wispr(12, weight: .medium))
                                .kerning(0.6)
                                .foregroundStyle(Color.wisprSecondaryText)
                                .padding(.top, 6)
                        }

                        ForEach(loose) { timeline in
                            timelineChoice(timeline)
                        }
                    }

                    Button {
                        isCreating = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.wispr(15, weight: .semibold))
                                .foregroundStyle(Color.wisprInk)
                                .frame(width: 26, height: 26)

                            Text("New timeline")
                                .font(.wispr(17))
                                .foregroundStyle(Color.wisprInk)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .wisprCardBackground(cornerRadius: 12)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WisprBackground())
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.wisprInk)
        .presentationDetents([.medium, .large])
        .wisprSheetEdge()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isCreating) {
            // A timeline made here is the one the note wanted.
            TimelineEditorSheet { created in
                pick(created.id)
            }
        }
    }

    private func timelineChoice(_ timeline: NoteTimeline) -> some View {
        choice(
            title: timeline.displayName,
            isSelected: selection == timeline.id,
            mark: { TimelineMark(timeline: timeline) },
            action: { pick(timeline.id) },
            fill: timeline.tint.fill
        )
    }

    private func choice<Mark: View>(
        title: String,
        isSelected: Bool,
        @ViewBuilder mark: () -> Mark,
        action: @escaping () -> Void,
        fill: Color? = nil
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                mark()

                Text(title)
                    .font(.wispr(17))
                    .foregroundStyle(fill == nil ? Color.wisprInk : Color.wisprOnAccent)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.wispr(15, weight: .semibold))
                        .foregroundStyle(fill == nil ? Color.wisprInk : Color.wisprOnAccent)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background {
                if let fill {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(fill)
                }
            }
            .wisprCardBackground(cornerRadius: 12)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            fill == nil ? Color.wisprInk.opacity(0.75) : Color.wisprOnAccent.opacity(0.75),
                            lineWidth: 1.5
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func pick(_ id: UUID?) {
        onSelect(id)
        dismiss()
    }
}

#if DEBUG
#Preview("New timeline") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            TimelineEditorSheet()
                .environment(TimelineStore.previewSeeded())
        }
}

#Preview("Assign") {
    Color.black
        .sheet(isPresented: .constant(true)) {
            NoteTimelineSheet(selection: nil) { _ in }
                .environment(TimelineStore.previewSeeded())
        }
}
#endif
