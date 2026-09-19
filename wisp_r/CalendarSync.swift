import EventKit
import Foundation

/// Keeps event notes and the default calendar in step.
///
/// Creating an event here writes it into the default calendar, and events
/// already on that calendar come back as notes. Each synced note remembers the
/// calendar item it mirrors. `Note.calendarRevision` is that item's last
/// modified date once the two sides agree; clearing it marks local edits that
/// still need pushing, so a refresh cannot overwrite them.
@MainActor
final class CalendarSync {
    private let eventStore = EKEventStore()
    private weak var notes: NoteStore?
    private var isStarted = false
    private var isRunning = false
    private var needsAnotherPass = false
    private var didLogDeniedAccess = false
    private var observer: NSObjectProtocol?
    private var pendingRemovals: [Removal] = []

    /// How far either side of today to read. Matches how far the day view pages.
    private static let dayReach = 400

    private struct Removal {
        var id: String
        var occurrence: Date?
    }

    /// The calendar events are read from and written to: the one chosen in
    /// settings, or the system's own default when none is set or the chosen one
    /// has gone away.
    private var syncCalendar: EKCalendar? {
        if let id = AppSettings.shared.calendarID,
           let chosen = eventStore.calendar(withIdentifier: id),
           chosen.allowsContentModifications {
            return chosen
        }
        return eventStore.defaultCalendarForNewEvents
    }

    func start(with store: NoteStore) {
        guard !isStarted else { return }
        isStarted = true
        notes = store
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: .main
        ) { [weak self] _ in
            let sync = self
            Task { @MainActor in
                sync?.notesDidChange()
            }
        }
        notesDidChange()
    }

    func notesDidChange() {
        guard isStarted else { return }
        needsAnotherPass = true
        guard !isRunning else { return }
        isRunning = true
        Task { await self.drain() }
    }

    /// The note is gone, so its calendar event should go too.
    func remove(_ notes: [Note]) {
        guard isStarted else { return }
        for note in notes {
            guard let id = note.calendarEventID else { continue }
            pendingRemovals.append(Removal(id: id, occurrence: note.calendarOccurrence))
        }
        notesDidChange()
    }

    // MARK: - Passes

    private func drain() async {
        while needsAnotherPass {
            needsAnotherPass = false
            await perform()
        }
        isRunning = false
        if needsAnotherPass { notesDidChange() }
    }

    private func perform() async {
        guard let notes else { return }
        guard await ensureAccess() else { return }
        deletePending()
        push(notes)
        pull(notes)
    }

    private func ensureAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            do {
                return try await eventStore.requestFullAccessToEvents()
            } catch {
                print("Wispr: could not ask for calendar access — \(error)")
                return false
            }
        default:
            if !didLogDeniedAccess {
                didLogDeniedAccess = true
                print("Wispr: calendar sync needs full calendar access. Allow it in Settings to sync events.")
            }
            return false
        }
    }

    // MARK: - App to calendar

    private func deletePending() {
        let removals = pendingRemovals
        pendingRemovals.removeAll()
        for removal in removals {
            guard let event = findEvent(id: removal.id, occurrence: removal.occurrence) else { continue }
            do {
                try eventStore.remove(event, span: .thisEvent)
            } catch {
                print("Wispr: could not remove calendar event — \(error)")
            }
        }
    }

    private func push(_ store: NoteStore) {
        guard syncCalendar != nil else { return }
        // A copy, because stamping a link mutates the store mid-pass.
        let snapshot = store.notesByDay
        for (key, dayNotes) in snapshot {
            guard let day = NoteStore.date(forKey: key) else { continue }
            for note in dayNotes {
                push(note, storedOn: day, store: store)
            }
        }
    }

    private func push(_ note: Note, storedOn day: Date, store: NoteStore) {
        guard note.schedule?.isEvent == true else {
            clearCalendarEvent(for: note, store: store)
            return
        }
        guard let schedule = note.schedule,
              let interval = schedule.calendarInterval(storedOn: day)
        else { return }

        let title = note.calendarTitle
        if let id = note.calendarEventID,
           let event = findEvent(id: id, occurrence: note.calendarOccurrence) {
            if matches(event, title: title, interval: interval) {
                if note.calendarRevision == nil {
                    stamp(event, on: note.id, title: title, schedule: schedule, store: store)
                }
                return
            }
            // A clean note loses to a newer calendar edit; the pull applies it.
            if let revision = note.calendarRevision,
               let modified = event.lastModifiedDate,
               modified.timeIntervalSince(revision) > 1 {
                return
            }
            write(interval, title: title, to: event)
            guard save(event) else { return }
            stamp(event, on: note.id, title: title, schedule: schedule, store: store)
            return
        }

        // The event used to be there and the note hasn't changed: it was deleted
        // in the calendar, and the pull removes the note.
        if note.calendarEventID != nil, note.calendarRevision != nil { return }

        guard let calendar = syncCalendar else { return }
        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        write(interval, title: title, to: event)
        guard save(event) else { return }
        if !stamp(event, on: note.id, title: title, schedule: schedule, store: store),
           let id = event.eventIdentifier {
            // The note changed while we were writing. Keep the link so the next
            // pass updates this event instead of creating a second one.
            store.attachCalendarEvent(id: id, occurrence: occurrenceDate(of: event), for: note.id)
        }
    }

    private func clearCalendarEvent(for note: Note, store: NoteStore) {
        guard let id = note.calendarEventID else { return }
        if let event = findEvent(id: id, occurrence: note.calendarOccurrence) {
            do {
                try eventStore.remove(event, span: .thisEvent)
            } catch {
                print("Wispr: could not remove calendar event — \(error)")
            }
        }
        _ = store.stampCalendarLink(
            id: nil,
            occurrence: nil,
            revision: nil,
            for: note.id,
            title: note.calendarTitle,
            schedule: note.schedule
        )
    }

    private func write(_ interval: NoteSchedule.CalendarInterval, title: String, to event: EKEvent) {
        event.title = title
        event.isAllDay = interval.isAllDay
        event.startDate = interval.start
        event.endDate = interval.end
        event.timeZone = interval.isAllDay ? nil : .current
    }

    @discardableResult
    private func save(_ event: EKEvent) -> Bool {
        do {
            try eventStore.save(event, span: .thisEvent)
            return true
        } catch {
            print("Wispr: could not save calendar event — \(error)")
            return false
        }
    }

    @discardableResult
    private func stamp(
        _ event: EKEvent,
        on noteID: UUID,
        title: String,
        schedule: NoteSchedule,
        store: NoteStore
    ) -> Bool {
        guard let id = event.eventIdentifier else { return false }
        return store.stampCalendarLink(
            id: id,
            occurrence: occurrenceDate(of: event),
            revision: event.lastModifiedDate ?? .now,
            for: noteID,
            title: title,
            schedule: schedule
        )
    }

    // MARK: - Calendar to app

    private func pull(_ store: NoteStore) {
        guard let calendar = syncCalendar else { return }
        let window = syncWindow()
        let predicate = eventStore.predicateForEvents(
            withStart: window.start,
            end: window.end,
            calendars: [calendar]
        )
        let events = eventStore.events(matching: predicate)
        var seen = Set<String>()

        for event in events {
            guard event.status != .canceled,
                  let id = event.eventIdentifier,
                  event.startDate != nil
            else { continue }

            let occurrence = occurrenceDate(of: event)
            seen.insert(linkKey(id: id, occurrence: occurrence))

            let imported = importedSchedule(from: event)
            let title = normalizedTitle(event.title)
            if let note = note(matching: id, occurrence: occurrence, in: store) {
                apply(event, title: title, imported: imported, to: note, forceLink: false, store: store)
            } else if let note = unlinkedNote(title: title, schedule: imported.schedule, on: imported.day, in: store) {
                apply(event, title: title, imported: imported, to: note, forceLink: true, store: store)
            } else {
                var note = Note(blocks: [NoteBlock(text: AttributedString(title))])
                note.schedule = imported.schedule
                note.calendarEventID = id
                note.calendarOccurrence = occurrence
                note.calendarRevision = event.lastModifiedDate ?? .now
                store.applyCalendarNote(note, on: imported.day)
            }
        }

        removeMissing(seen: seen, window: window, store: store)
    }

    private func apply(
        _ event: EKEvent,
        title: String,
        imported: (day: Date, schedule: NoteSchedule),
        to note: Note,
        forceLink: Bool,
        store: NoteStore
    ) {
        let modified = event.lastModifiedDate ?? .now
        if !forceLink,
           let revision = note.calendarRevision,
           modified.timeIntervalSince(revision) <= 1 {
            return
        }
        // Local edits were pushed at the start of this pass. Don't overwrite them.
        if !forceLink, note.calendarRevision == nil, note.calendarEventID != nil {
            return
        }

        var updated = note
        if updated.calendarTitle != title {
            updated.setCalendarTitle(title)
        }
        updated.schedule = imported.schedule
        updated.calendarEventID = event.eventIdentifier
        updated.calendarOccurrence = occurrenceDate(of: event)
        updated.calendarRevision = modified
        store.applyCalendarNote(updated, on: imported.day)
    }

    private func removeMissing(
        seen: Set<String>,
        window: (start: Date, end: Date),
        store: NoteStore
    ) {
        var doomed: [(UUID, Date)] = []
        for (key, dayNotes) in store.notesByDay {
            guard let day = NoteStore.date(forKey: key) else { continue }
            for note in dayNotes {
                guard let id = note.calendarEventID,
                      let schedule = note.schedule,
                      schedule.isEvent,
                      note.calendarRevision != nil,
                      intersects(day, schedule: schedule, window: window)
                else { continue }
                if seen.contains(linkKey(id: id, occurrence: note.calendarOccurrence)) { continue }
                // Still on another calendar, or outside this fetch: keep the note.
                // Only a missing event means it was deleted.
                guard findEvent(id: id, occurrence: note.calendarOccurrence) == nil else { continue }
                doomed.append((note.id, day))
            }
        }
        for (id, day) in doomed {
            store.removeCalendarNote(id, on: day)
        }
    }

    // MARK: - Events

    private func findEvent(id: String, occurrence: Date?) -> EKEvent? {
        guard let occurrence else { return eventStore.event(withIdentifier: id) }
        let predicate = eventStore.predicateForEvents(
            withStart: occurrence.addingTimeInterval(-86_400),
            end: occurrence.addingTimeInterval(86_400 * 2),
            calendars: nil
        )
        return eventStore.events(matching: predicate).first { event in
            guard event.eventIdentifier == id else { return false }
            if let eventOccurrence = event.occurrenceDate {
                return abs(eventOccurrence.timeIntervalSince(occurrence)) < 2
            }
            guard let start = event.startDate else { return false }
            return abs(start.timeIntervalSince(occurrence)) < 2
        }
    }

    private func occurrenceDate(of event: EKEvent) -> Date? {
        if let occurrence = event.occurrenceDate { return occurrence }
        if let rules = event.recurrenceRules, !rules.isEmpty { return event.startDate }
        return nil
    }

    private func matches(
        _ event: EKEvent,
        title: String,
        interval: NoteSchedule.CalendarInterval
    ) -> Bool {
        guard normalizedTitle(event.title) == title, event.isAllDay == interval.isAllDay else { return false }
        guard let start = event.startDate, let end = event.endDate else { return false }
        if interval.isAllDay {
            return sameAllDay(start, interval.start) && sameAllDay(end, interval.end)
        }
        return abs(start.timeIntervalSince(interval.start)) < 2
            && abs(end.timeIntervalSince(interval.end)) < 2
    }

    private func sameAllDay(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(
            NoteSchedule.localDay(fromAllDayBoundary: lhs),
            inSameDayAs: NoteSchedule.localDay(fromAllDayBoundary: rhs)
        )
    }

    private func importedSchedule(from event: EKEvent) -> (day: Date, schedule: NoteSchedule) {
        let calendar = Calendar.current
        guard let startDate = event.startDate else {
            let today = calendar.startOfDay(for: .now)
            return (today, NoteSchedule(startMinute: 0, isAllDay: true))
        }

        if event.isAllDay {
            let startDay = NoteSchedule.localDay(fromAllDayBoundary: startDate)
            let endDate = event.endDate ?? calendar.date(byAdding: .day, value: 1, to: startDate) ?? startDate
            let endDay = NoteSchedule.localDay(fromAllDayBoundary: endDate)
            let last = calendar.date(byAdding: .day, value: -1, to: endDay) ?? startDay
            let offset = max(0, calendar.dateComponents([.day], from: startDay, to: last).day ?? 0)
            return (startDay, NoteSchedule(startMinute: 0, endDayOffset: offset, isAllDay: true))
        }

        let startDay = calendar.startOfDay(for: startDate)
        let endDate = event.endDate ?? startDate.addingTimeInterval(3600)
        var offset = max(0, calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: endDate)).day ?? 0)
        let startMinute = NoteSchedule.minute(of: startDate)
        var endMinute = NoteSchedule.minute(of: endDate)
        if offset == 0, endMinute <= startMinute {
            endMinute = startMinute + 1
            if endMinute >= 24 * 60 {
                endMinute = 0
                offset = 1
            }
        }
        return (
            startDay,
            NoteSchedule(startMinute: startMinute, endMinute: endMinute, endDayOffset: offset)
        )
    }

    private func note(matching id: String, occurrence: Date?, in store: NoteStore) -> Note? {
        for dayNotes in store.notesByDay.values {
            if let note = dayNotes.first(where: { matches($0, id: id, occurrence: occurrence) }) {
                return note
            }
        }
        return nil
    }

    private func matches(_ note: Note, id: String, occurrence: Date?) -> Bool {
        guard note.calendarEventID == id else { return false }
        switch (note.calendarOccurrence, occurrence) {
        case (nil, nil):
            return true
        case let (stored?, event?):
            return abs(stored.timeIntervalSince(event)) < 2
        default:
            return false
        }
    }

    /// A note we already wrote out, before its calendar identifier was stored.
    private func unlinkedNote(
        title: String,
        schedule: NoteSchedule,
        on day: Date,
        in store: NoteStore
    ) -> Note? {
        (store.notesByDay[NoteStore.key(for: day)] ?? []).first { note in
            note.calendarEventID == nil && note.schedule == schedule && note.calendarTitle == title
        }
    }

    private func normalizedTitle(_ title: String?) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "New Event" : trimmed
    }

    private func linkKey(id: String, occurrence: Date?) -> String {
        guard let occurrence else { return id }
        return "\(id)|\(Int((occurrence.timeIntervalSince1970 / 60).rounded()))"
    }

    private func intersects(
        _ day: Date,
        schedule: NoteSchedule,
        window: (start: Date, end: Date)
    ) -> Bool {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let last = calendar.date(byAdding: .day, value: schedule.endDayOffset + 1, to: start) ?? start
        return start < window.end && last > window.start
    }

    private func syncWindow() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -Self.dayReach, to: today) ?? today
        let end = calendar.date(byAdding: .day, value: Self.dayReach + 1, to: today) ?? today
        return (start, end)
    }
}
