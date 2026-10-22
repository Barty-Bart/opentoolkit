import AppKit
import SwiftUI
import Combine

struct LocalNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var text: String
    var createdAt = Date()
    var updatedAt = Date()
    var session: String? = nil
    var kind: String? = nil
}

struct LocalReminder: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var createdAt = Date()
    var dueAt: Date
    var completedAt: Date?
    var isComplete: Bool { completedAt != nil }
}

struct ReminderRequest: Equatable {
    var text: String
    var delay: TimeInterval
}

/// Deliberately bounded English parser. An unrecognised time never silently becomes a reminder.
enum ReminderParser {
    static func parse(_ input: String) -> ReminderRequest? {
        let cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let pattern = #"\b(?:in\s+|for\s+)?(\d+(?:\.\d+)?|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty[- ]five|sixty|half(?:\s+an?)?)(?:\s+)(seconds?|minutes?|hours?|days?)(?:\s+from\s+now)?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let quantityRange = Range(match.range(at: 1), in: cleaned),
              let unitRange = Range(match.range(at: 2), in: cleaned),
              let durationRange = Range(match.range, in: cleaned) else { return nil }
        let words: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty-five": 45, "forty five": 45, "sixty": 60, "half": 0.5, "half a": 0.5, "half an": 0.5]
        let value = String(cleaned[quantityRange]).lowercased()
        let preceding = cleaned[..<quantityRange.lowerBound].lowercased().trimmingCharacters(in: .whitespaces)
        guard !preceding.hasSuffix("-"), !preceding.hasSuffix("minus"), !preceding.hasSuffix("negative"), !preceding.hasSuffix("and a") else { return nil }
        let following = String(cleaned[durationRange.upperBound...])
        // Compound durations need a complete parse; reject them instead of silently scheduling too early.
        if following.range(of: #"^\s*(?:and\s+)?(?:a\s+)?half\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        if let next = regex.firstMatch(in: following, range: NSRange(following.startIndex..., in: following)), let nextRange = Range(next.range, in: following) {
            let connector = following[..<nextRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if connector.isEmpty || connector == "and" || connector == "," { return nil }
        }
        guard let quantity = Double(value) ?? words[value], quantity > 0 else { return nil }
        let unit = cleaned[unitRange].lowercased()
        let multiplier: Double = unit.hasPrefix("second") ? 1 : unit.hasPrefix("minute") ? 60 : unit.hasPrefix("hour") ? 3600 : 86400
        let delay = quantity * multiplier
        guard delay.isFinite, delay >= 1, delay <= 366 * 86400 else { return nil }
        var content = cleaned.replacingCharacters(in: durationRange, with: " ")
        let prefixes = [#"^\s*(?:please\s+)?(?:make|set|create)\s+(?:me\s+)?(?:a\s+)?reminder\b"#, #"^\s*(?:please\s+)?remind\s+me\b"#]
        for prefix in prefixes { content = content.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive]) }
        content = content.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        content = content.replacingOccurrences(of: #"^\s*(?:for\s+me\s+)?(?:to\s+|that\s+|for\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        content = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
        guard !content.isEmpty else { return nil }
        return ReminderRequest(text: content, delay: delay)
    }
}

/// Local counts and excerpts, never a claim about a person's mental state or priorities.
enum LocalDailyReview {
    static func make(transcripts: [String], notes: [LocalNote], date: Date = Date()) -> String {
        let lines = transcripts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let todayNotes = notes.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: date) }
        guard !lines.isEmpty || !todayNotes.isEmpty else {
            return "No entries to review yet. Save a note or record some dictation, then refresh. This review uses local word counts and excerpts; it does not infer what you are thinking or what needs attention."
        }
        let source = lines + todayNotes.map(\.text)
        let ignored = Set("a about above after again against all also am an and any are as at be because been before being below between both but by can cant could couldnt did didnt do does doesnt doing dont down during each few for from further get got had hadnt has hasnt have havent having he her here hers herself him himself his how i id ill im ive if in into is isnt it its itself just lets like me might more most must my myself no nor not now of off on once only or other ought our ours ourselves out over own same say says said she should shouldnt so some such than that thats the their theirs them themselves then there these they this those through to too under until up us very want was wasnt we well were werent what whats when where which while who whom why will with wont would wouldnt you your yours yourself yourselves yeah okay really thing things one know going go need make something actually um uh right well let".split(separator: " ").map(String.init))
        var counts: [String: Int] = [:]
        let expression = try! NSRegularExpression(pattern: #"[\p{L}][\p{L}'’-]+"#)
        for text in source {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text) else { continue }
                let word = text[range].lowercased().replacingOccurrences(of: "’", with: "'")
                guard word.count > 2, !ignored.contains(word) else { continue }
                counts[word, default: 0] += 1
            }
        }
        let repeated = counts.filter { $0.value >= 2 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(10)
        let candidates = source.flatMap { text -> [String] in
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
                let lower = $0.lowercased()
                return ["remember", "need to", "follow up", "todo", "to-do", "don't forget", "do not forget"].contains { lower.contains($0) }
            }
        }
        var sections = ["LOCAL ACTIVITY REVIEW\nWord counts and excerpts only. These are suggestions to inspect, not AI conclusions.", "Included: \(lines.count) supplied dictation entries and \(todayNotes.count) notes created today."]
        if !repeated.isEmpty { sections.append("Repeated words\n" + repeated.map { "• \($0.key) — \($0.value) mentions" }.joined(separator: "\n")) }
        else { sections.append("No repeated topic words found in these entries.") }
        if !candidates.isEmpty {
            var seen = Set<String>()
            let unique = candidates.filter { seen.insert($0).inserted }.prefix(6)
            sections.append("Possible follow-ups — excerpts to check\n" + unique.map { "• " + String($0.prefix(360)) + ($0.count > 360 ? "…" : "") }.joined(separator: "\n"))
        }
        if !todayNotes.isEmpty { sections.append("Notes saved today\n" + todayNotes.prefix(8).map { "• " + $0.title }.joined(separator: "\n")) }
        sections.append("Reflection\nWhat is worth continuing tomorrow? Is anything here ready to become a note or a reminder?")
        return sections.joined(separator: "\n\n")
    }
}

@MainActor
final class OrganizerStore: ObservableObject {
    @Published private(set) var notes: [LocalNote] = []
    @Published private(set) var reminders: [LocalReminder] = []
    @Published private(set) var focusTask = ""
    @Published private(set) var reviewText = ""
    @Published private(set) var status = "Saved on this Mac"
    @Published private(set) var lastSaveSucceeded = true
    @Published var reminderSoundEnabled = false { didSet { save() } }
    @Published var remindersEnabled = true {
        didSet {
            save()
            if remindersEnabled { checkDueReminders() }
            else { reminderPanel?.orderOut(nil); reminderPanel = nil; visibleReminderID = nil }
        }
    }
    var onStatus: ((String) -> Void)?
    /// Host supplies current-day transcripts on demand, rather than granting broad database access.
    var onRequestReview: (() -> [String])?
    private let file: URL
    private var library: LibraryDatabase?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var reminderPanel: NSPanel?
    private var focusPanel: NSPanel?
    private var notesWindow: NSWindow?
    private var visibleReminderID: UUID?
    private var isLoading = false
    private var storageReadFailed = false
    private struct State: Codable {
        var version = 1
        var notes: [LocalNote]
        var reminders: [LocalReminder]
        var focusTask: String
        var reviewText: String
        var reminderSoundEnabled: Bool?
        var remindersEnabled: Bool?
    }

    init(storage: URL, startMonitoring: Bool = true, libraryURL:URL?=nil) {
        self.file = storage.appendingPathComponent("organizer.json")
        do {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            library = try LibraryDatabase(url:libraryURL ?? storage.appendingPathComponent("library.sqlite"))
            isLoading = true
            let raw = try library!.value("organizer") ?? (FileManager.default.fileExists(atPath:file.path) ? String(contentsOf:file,encoding:.utf8):"")
            if !raw.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let state = try decoder.decode(State.self, from: Data(raw.utf8))
                notes = state.notes
                reminders = state.reminders
                focusTask = state.focusTask
                reviewText = state.reviewText
                reminderSoundEnabled = state.reminderSoundEnabled ?? false
                remindersEnabled = state.remindersEnabled ?? true
            }
            isLoading = false
            save()
        } catch {
            isLoading = false
            storageReadFailed = true
            lastSaveSucceeded = false
            status = "Could not open saved organizer data. The existing file has been preserved."
        }
        if startMonitoring {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkDueReminders() }
            }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkDueReminders() }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.checkDueReminders()
            }
        }
    }

    func addNote(_ text: String, title: String? = nil) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let derived = String(clean.components(separatedBy: .newlines).first!.prefix(64))
        let provided = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        notes.insert(LocalNote(title: (provided?.isEmpty == false ? provided! : derived), text: clean), at: 0)
        save(); announce("Note saved locally")
    }

    /// Each recording session becomes one note; restarting the process preserves accumulated chunks.
    func appendTranscript(_ text: String, session: String, title: String? = nil, kind:String="meeting") {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = session.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !key.isEmpty else { lastSaveSucceeded = false; return }
        if let index = notes.firstIndex(where: { $0.session == key }) {
            notes[index].text += "\n\n" + clean
            notes[index].updatedAt = Date()
        } else {
            let fallback = UUID(uuidString: key) == nil ? key : "Transcript · " + Date().formatted(date: .abbreviated, time: .shortened)
            let displayTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
            var note = LocalNote(title: String((displayTitle?.isEmpty == false ? displayTitle! : fallback).prefix(96)), text: clean)
            note.session = key
            note.kind = kind
            notes.insert(note, at: 0)
        }
        save()
    }

    func updateNote(_ id: UUID, title: String, text: String, basedOn original: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled note" : title
        if let original, notes[index].text != original, notes[index].text.hasPrefix(original) {
            // A live recording may append while its note is being edited. Preserve those new chunks.
            notes[index].text = text + notes[index].text.dropFirst(original.count)
        } else {
            notes[index].text = text
        }
        notes[index].updatedAt = Date()
        save(); announce("Note updated")
    }

    func deleteNote(_ id: UUID) { notes.removeAll { $0.id == id }; save() }

    func addReminder(_ text: String, after delay: TimeInterval) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, delay.isFinite, delay > 0, delay <= 366 * 86400 else {
            announce("Use a reminder time from one second to one year."); return
        }
        let reminder = LocalReminder(text: clean, dueAt: Date().addingTimeInterval(delay))
        reminders.insert(reminder, at: 0)
        save(); announce("Reminder set for \(reminder.dueAt.formatted(date: .omitted, time: .shortened))")
    }

    @discardableResult
    func parseReminder(_ text: String) -> Bool {
        guard let request = ReminderParser.parse(text) else {
            announce("Try: remind me in 20 minutes to take a break."); return false
        }
        addReminder(request.text, after: request.delay)
        return true
    }

    func completeReminder(_ id: UUID) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].completedAt = Date()
        dismissReminderPanel(id); save(); checkDueReminders()
    }

    func snoozeReminder(_ id: UUID, minutes: Int = 5) {
        guard let index = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[index].dueAt = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        reminders[index].completedAt = nil
        dismissReminderPanel(id); save(); checkDueReminders()
    }

    func deleteReminder(_ id: UUID) {
        reminders.removeAll { $0.id == id }
        dismissReminderPanel(id); save(); checkDueReminders()
    }

    func pendingReminders(at date: Date = Date()) -> [LocalReminder] {
        reminders.filter { !$0.isComplete && $0.dueAt <= date }.sorted { $0.dueAt < $1.dueAt }
    }

    func checkDueReminders() {
        guard remindersEnabled, !isLoading, visibleReminderID == nil, let reminder = pendingReminders().first else { return }
        visibleReminderID = reminder.id
        let panel = floatingPanel(size: NSSize(width: 380, height: 218), title: "Reminder", interactive: true)
        panel.contentView = NSHostingView(rootView: ReminderPopup(reminder: reminder, done: { [weak self] in self?.completeReminder(reminder.id) }, snooze: { [weak self] in self?.snoozeReminder(reminder.id) }))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 400, y: frame.maxY - 240))
        }
        reminderPanel = panel
        panel.orderFrontRegardless()
        if reminderSoundEnabled { NSSound(named: NSSound.Name("Glass"))?.play() }
        onStatus?("Reminder due")
    }

    func setFocusTask(_ text: String) {
        focusTask = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        save()
    }

    func showFocusPanel() {
        if let panel = focusPanel { panel.orderFrontRegardless(); return }
        let panel = floatingPanel(size: NSSize(width: 330, height: 146), title: "Current focus", interactive: true)
        panel.contentView = NSHostingView(rootView: FocusPopup(store: self, close: { [weak self] in self?.hideFocusPanel() }))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 350, y: screen.visibleFrame.minY + 24))
        }
        focusPanel = panel
        panel.orderFrontRegardless()
    }

    func hideFocusPanel() { focusPanel?.orderOut(nil); focusPanel = nil }

    @discardableResult
    func dailyReview(transcripts: [String]) -> String {
        reviewText = LocalDailyReview.make(transcripts: transcripts, notes: notes)
        save(); do {try library?.put(id:"review:daily:"+ISO8601DateFormatter().string(from:Calendar.current.startOfDay(for:Date())),kind:"review",title:"Daily review",body:reviewText)}catch{status=error.localizedDescription}; return reviewText
    }

    func refreshReview() { _ = dailyReview(transcripts: onRequestReview?() ?? []) }

    func showNotes() { showWindow(tab: .notes) }
    func presentReminderComposer() { showWindow(tab: .reminders) }

    func showWindow(tab: OrganizerSection = .notes) {
        if notesWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Pico · Organizer"
            window.minSize = NSSize(width: 680, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            notesWindow = window
        }
        notesWindow?.contentView = NSHostingView(rootView: OrganizerView(store: self, initialSection: tab))
        notesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func dismissReminderPanel(_ id: UUID) {
        guard visibleReminderID == id else { return }
        reminderPanel?.orderOut(nil); reminderPanel = nil; visibleReminderID = nil
    }

    private func save() {
        guard !isLoading else { return }
        guard !storageReadFailed else { lastSaveSucceeded = false; return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let state = State(notes: notes, reminders: reminders, focusTask: focusTask, reviewText: reviewText, reminderSoundEnabled: reminderSoundEnabled, remindersEnabled: remindersEnabled)
            guard let library else {throw LibraryFailure(message:"Library unavailable")}
            try library.atomic {
                try library.set("organizer",String(decoding:try encoder.encode(state),as:UTF8.self))
                let ids=Set(notes.map{"note:"+$0.id.uuidString}+reminders.map{"reminder:"+$0.id.uuidString})
                for row in try library.rows("SELECT id FROM items WHERE source='organizer'") where !ids.contains(row[0]) {try library.execute("DELETE FROM items WHERE id=?",[row[0]])}
                for note in notes {try library.put(id:"note:"+note.id.uuidString,kind:note.kind ?? (note.session == nil ? "note":"meeting"),title:note.title,body:note.text,source:"organizer",created:note.createdAt.timeIntervalSince1970)}
                for reminder in reminders {try library.put(id:"reminder:"+reminder.id.uuidString,kind:"reminder",title:reminder.text,body:(reminder.isComplete ? "Completed":"Due "+reminder.dueAt.formatted()),source:"organizer",created:reminder.createdAt.timeIntervalSince1970)}
            }
            status = "Saved on this Mac"
            lastSaveSucceeded = true
        } catch {
            lastSaveSucceeded = false
            status = "Could not save organizer changes. Keep this window open and check available storage."
        }
    }

    private func announce(_ text: String) {
        if !storageReadFailed && status == "Saved on this Mac" { onStatus?(text) }
        else { onStatus?(status) }
    }

    private func floatingPanel(size: NSSize, title: String, interactive: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = title
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

enum OrganizerSection: String, CaseIterable, Identifiable {
    case notes = "Notes", reminders = "Reminders", review = "Review"
    var id: String { rawValue }
    var icon: String { self == .notes ? "note.text" : self == .reminders ? "bell.badge" : "sun.max" }
}

struct OrganizerView: View {
    @ObservedObject var store: OrganizerStore
    @State private var section: OrganizerSection
    @State private var focusDraft = ""
    init(store: OrganizerStore, initialSection: OrganizerSection = .notes) {
        self.store = store
        self._section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("A little more headspace.").font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text("Keep a thought, set a reminder, come back to your focus.").foregroundStyle(.secondary)
                }
                Spacer()
                Label("LOCAL", systemImage: "lock.shield").font(.caption.weight(.semibold)).foregroundStyle(.teal).padding(8).background(Color.teal.opacity(0.10), in: Capsule())
            }.padding(24)
            Picker("Section", selection: $section) {
                ForEach(OrganizerSection.allCases) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 18)
            Group {
                switch section {
                case .notes: NotesSection(store: store)
                case .reminders: RemindersSection(store: store)
                case .review: ReviewSection(store: store)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "scope").foregroundStyle(.orange)
                TextField("What are you focusing on?", text: $focusDraft).textFieldStyle(.plain).onSubmit { saveFocus() }
                Button("Pin focus") { saveFocus(); store.showFocusPanel() }.buttonStyle(.bordered)
            }.padding(16).background(Color.primary.opacity(0.025))
            Text(store.status).font(.caption2).foregroundStyle(store.status == "Saved on this Mac" ? Color.secondary : Color.orange).padding(.horizontal, 16).padding(.bottom, 9)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { focusDraft = store.focusTask }
        .onChange(of: store.focusTask) { _, value in focusDraft = value }
    }
    private func saveFocus() { store.setFocusTask(focusDraft) }
}

private struct NotesSection: View {
    @ObservedObject var store: OrganizerStore
    @State private var selected: UUID?
    @State private var noteToDelete: UUID?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("YOUR NOTES").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { store.addNote("Start writing here…", title: "Untitled note"); selected = store.notes.first?.id } label: { Image(systemName: "plus") }.help("New note") }
                List(selection: $selected) {
                    ForEach(store.notes) { note in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(note.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(note.updatedAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 5).tag(note.id)
                        .contextMenu { Button("Delete note", role: .destructive) { noteToDelete = note.id } }
                    }
                }.listStyle(.sidebar)
            }.padding(.leading, 18).padding(.trailing, 10).frame(width: 250)
            Divider()
            if let id = selected, let note = store.notes.first(where: { $0.id == id }) {
                NoteEditor(note: note, save: { title, text, original in store.updateNote(note.id, title: title, text: text, basedOn: original) }, remove: { noteToDelete = note.id }).id(note.id)
            } else {
                OrganizerEmpty(icon: "note.text", title: "Keep the thought.", detail: "Create a note here, or use the voice command “take a note”.")
            }
        }
        .onAppear { if selected == nil { selected = store.notes.first?.id } }
        .onChange(of: store.notes.count) { _, _ in if selected == nil || !store.notes.contains(where: { $0.id == selected }) { selected = store.notes.first?.id } }
        .alert("Delete this note?", isPresented: Binding(get: { noteToDelete != nil }, set: { if !$0 { noteToDelete = nil } })) {
            Button("Cancel", role: .cancel) { noteToDelete = nil }
            Button("Delete", role: .destructive) { if let id = noteToDelete { store.deleteNote(id) }; noteToDelete = nil }
        } message: { Text("This removes the local note from this app.") }
    }
}

struct NoteEditor: View {
    var note: LocalNote
    var save: (String, String, String) -> Void
    var remove: () -> Void
    @State private var title: String
    @State private var text: String
    @State private var saved = false
    @State private var original: String
    init(note: LocalNote, save: @escaping (String, String, String) -> Void, remove: @escaping () -> Void) {
        self.note = note; self.save = save; self.remove = remove
        _title = State(initialValue: note.title); _text = State(initialValue: note.text); _original = State(initialValue: note.text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Note title", text: $title).textFieldStyle(.plain).font(.title2.weight(.semibold))
            Text("Created \(note.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }.help("Delete note")
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                Spacer()
                if saved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                Button("Save changes") { save(title, text, original); original = text; saved = true }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
            }
        }.padding(22).onChange(of: text) { _, _ in saved = false }.onChange(of: title) { _, _ in saved = false }
        .onChange(of: note.text) { _, updated in if text == original { text = updated; original = updated } }
        .onDisappear { if title != note.title || text != original { save(title, text, original) } }
    }
}

struct RemindersSection: View {
    @ObservedObject var store: OrganizerStore
    @State private var draft = ""
    @State private var error = ""
    @State private var showCompleted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "bell").font(.title3).foregroundStyle(.orange)
                TextField("Remind me in 20 minutes to take a break", text: $draft).textFieldStyle(.roundedBorder).onSubmit { add() }
                Button("Add reminder", action: add).buttonStyle(.borderedProminent).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(error.isEmpty ? "Use seconds, minutes, hours or days. Due reminders appear over your apps; missed reminders return when this app resumes." : error).font(.caption).foregroundStyle(error.isEmpty ? Color.secondary : Color.orange)
            HStack {
                Toggle("Reminders enabled", isOn: $store.remindersEnabled).toggleStyle(.checkbox)
                Toggle("Show completed", isOn: $showCompleted).toggleStyle(.checkbox)
                Spacer()
                Toggle("Reminder sound", isOn: $store.reminderSoundEnabled).toggleStyle(.checkbox)
            }.font(.caption)
            let items = store.reminders.filter { showCompleted || !$0.isComplete }.sorted { $0.dueAt < $1.dueAt }
            if items.isEmpty { OrganizerEmpty(icon: "bell.badge", title: "Let it leave your head.", detail: "Reminders are stored locally and stay here after restarting the app.") }
            else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { reminder in
                            HStack(alignment: .top, spacing: 12) {
                                Button { store.completeReminder(reminder.id) } label: { Image(systemName: reminder.isComplete ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(reminder.isComplete ? Color.teal : Color.secondary) }.buttonStyle(.plain).disabled(reminder.isComplete)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(reminder.text).font(.system(size: 14, weight: .medium)).strikethrough(reminder.isComplete)
                                    Text(reminder.dueAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if !reminder.isComplete { Button("+5 min") { store.snoozeReminder(reminder.id) }.font(.caption) }
                                Button { store.deleteReminder(reminder.id) } label: { Image(systemName: "trash") }.buttonStyle(.plain).foregroundStyle(.secondary).help("Delete reminder")
                            }.padding(15).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }
    private func add() { if store.parseReminder(draft) { draft = ""; error = "" } else { error = "Include a duration and a task, for example: in one hour, check the oven." } }
}

private struct ReviewSection: View {
    @ObservedObject var store: OrganizerStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your day, collected.").font(.title3.weight(.semibold))
                    Text("Local counts and excerpts. No cloud model or email access.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refreshReview() } label: { Label("Refresh review", systemImage: "arrow.clockwise") }.buttonStyle(.borderedProminent)
            }
            if store.reviewText.isEmpty { OrganizerEmpty(icon: "sun.max", title: "A moment to look back.", detail: "Review your notes and the dictation entries provided by this app. Repeated words are prompts for reflection, not a diagnosis or a priority score.") }
            else { ScrollView { Text(store.reviewText).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(18) }.background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12)) }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.badge").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Email watchers · not connected").font(.caption.weight(.semibold))
                    Text("No email is being read. A provider and explicit watcher rules are needed before this feature can run.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }
}

private struct OrganizerEmpty: View {
    var icon: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(.teal)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 350)
        }.padding(35).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReminderPopup: View {
    var reminder: LocalReminder
    var done: () -> Void
    var snooze: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Label("REMINDER", systemImage: "bell.badge.fill").font(.caption.weight(.bold)).foregroundStyle(.orange); Spacer(); Text(reminder.dueAt, style: .time).font(.caption).foregroundStyle(.secondary) }
            ScrollView { Text(reminder.text).font(.system(size: 18, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading) }
            HStack { Button("Snooze 5 min", action: snooze).buttonStyle(.bordered); Spacer(); Button("Done", action: done).buttonStyle(.borderedProminent).tint(.teal) }
        }.padding(20).frame(width: 380, height: 218).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.14), lineWidth: 1))
    }
}

private struct FocusPopup: View {
    @ObservedObject var store: OrganizerStore
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label("CURRENT FOCUS", systemImage: "scope").font(.caption.weight(.bold)).foregroundStyle(.teal); Spacer(); Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            Text(store.focusTask.isEmpty ? "Choose one thing to focus on." : store.focusTask).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }.padding(19).frame(width: 330, height: 146).background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18)).overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14), lineWidth: 1))
    }
}
