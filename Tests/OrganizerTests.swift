import Foundation

@main
struct OrganizerTests {
    @MainActor
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            checks += 1
        }
        let cases: [(String, Double, String)] = [
            ("Remind me in one hour to stretch", 3600, "stretch"),
            ("make a reminder for 15 minutes from now for me to check the oven", 900, "check the oven"),
            ("remind me to drink water in 20 minutes", 1200, "drink water"),
            ("set a reminder for half an hour to stand up", 1800, "stand up"),
            ("create a reminder in 1.5 hours to pack", 5400, "pack"),
            ("in two days, order coffee", 172800, "order coffee"),
            ("please remind me in ten seconds to test the sound", 10, "test the sound"),
            ("Remind me in forty-five minutes to call home.", 2700, "call home")
        ]
        for (input, delay, text) in cases {
            let value = ReminderParser.parse(input)
            check(value?.delay == delay, "duration: \(input)")
            check(value?.text == text, "content: \(input)")
        }
        for input in ["", "remember coffee", "remind me in zero minutes to stand", "remind me in one hour", "remind me in 9999999 days to test", "remind me in -5 minutes to test", "remind me in one hour and thirty minutes to test", "remind me in one and a half hours to test"] {
            check(ReminderParser.parse(input) == nil, "reject invalid or incomplete reminder")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("multitool-organizer-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OrganizerStore(storage: directory, startMonitoring: false)
        store.addNote("Hello local notes", title: "Test note")
        store.addNote("  ")
        check(store.notes.count == 1, "empty notes are not added")
        store.updateNote(store.notes[0].id, title: "Renamed", text: "Updated body")
        store.appendTranscript("First chunk.", session: "Meeting test")
        check(store.lastSaveSucceeded, "transcript acknowledgment allowed after durable save")
        store.appendTranscript("Second chunk.", session: "Meeting test")
        check(store.notes.count == 2, "one note per meeting session")
        check(store.notes.first?.text == "First chunk.\n\nSecond chunk.", "meeting chunks accumulated")
        let originalMeeting = store.notes.first!
        store.appendTranscript("Third chunk.", session: "Meeting test")
        store.updateNote(originalMeeting.id, title: originalMeeting.title, text: "Edited first two chunks.", basedOn: originalMeeting.text)
        check(store.notes.first?.text == "Edited first two chunks.\n\nThird chunk.", "concurrent note edits preserve newly recorded chunks")
        check(store.parseReminder("Remind me in one hour to test persistence"), "store accepts reminder")
        check(store.pendingReminders().isEmpty, "future reminder does not fire early")
        check(store.pendingReminders(at: Date().addingTimeInterval(3605)).count == 1, "overdue reminders survive delayed checks")
        store.setFocusTask("Ship the local build")
        let loaded = OrganizerStore(storage: directory, startMonitoring: false)
        check(loaded.notes.count == 2, "notes survive relaunch")
        check(loaded.notes.last?.title == "Renamed", "edits survive relaunch")
        check(loaded.notes.first?.session == "Meeting test", "meeting session key survives relaunch")
        check(loaded.reminders.count == 1, "reminders survive relaunch")
        check(loaded.focusTask == "Ship the local build", "focus survives relaunch")
        loaded.completeReminder(loaded.reminders[0].id)
        check(loaded.pendingReminders(at: Date().addingTimeInterval(7200)).isEmpty, "completed reminders never fire")
        let reloaded = OrganizerStore(storage: directory, startMonitoring: false)
        check(reloaded.reminders[0].isComplete, "completion persists")
        reloaded.snoozeReminder(reloaded.reminders[0].id)
        check(!reloaded.reminders[0].isComplete && reloaded.reminders[0].dueAt > Date(), "snooze creates future pending reminder")
        let review = LocalDailyReview.make(transcripts: ["Remember the storyboard. The storyboard needs work.", "I need to finish the storyboard."], notes: [])
        check(review.contains("storyboard — 3 mentions"), "review counts repeated topic words")
        check(review.contains("excerpts only") && review.contains("not AI conclusions"), "review identifies its limitations")
        check(review.contains("Possible follow-ups"), "review contains action-language excerpts")
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("library.sqlite").path)
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "saved personal data has owner-only permissions")
        let corruptDirectory = directory.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: true)
        let corruptFile = corruptDirectory.appendingPathComponent("organizer.json")
        let original = Data("not valid JSON".utf8)
        try original.write(to: corruptFile)
        let corrupt = OrganizerStore(storage: corruptDirectory, startMonitoring: false)
        check(!corrupt.lastSaveSucceeded, "unreadable saved data blocks acknowledgments immediately")
        corrupt.addNote("A note that must not overwrite unreadable saved material")
        check(!corrupt.lastSaveSucceeded, "blocked save never reports success")
        let preserved = try Data(contentsOf: corruptFile)
        check(preserved == original, "unreadable existing data is preserved")
        check(corrupt.status.contains("preserved"), "unreadable-data error remains visible")
        let failingDirectory = directory.appendingPathComponent("failing")
        let failing = OrganizerStore(storage: failingDirectory, startMonitoring: false)
        let failureDB=try LibraryDatabase(url:failingDirectory.appendingPathComponent("library.sqlite"))
        try failureDB.execute("CREATE TRIGGER reject_save BEFORE UPDATE ON library_meta WHEN new.key='organizer' BEGIN SELECT RAISE(ABORT,'synthetic disk error'); END")
        failing.appendTranscript("Keep this chunk until it is durable.", session: "write-failure")
        check(!failing.lastSaveSucceeded, "write error prevents premature audio acknowledgement")
        check(failing.notes.first?.text == "Keep this chunk until it is durable.", "unsaved transcript is retained in memory")
        try failureDB.execute("DROP TRIGGER reject_save")
        failing.appendTranscript("Storage recovered.", session: "write-failure")
        check(failing.lastSaveSucceeded, "successful retry restores save status")
        let recovered = OrganizerStore(storage: failingDirectory, startMonitoring: false)
        check(recovered.notes.first?.text == "Keep this chunk until it is durable.\n\nStorage recovered.", "recovered save preserves the previously unsaved chunk")
        print("Organizer: \(checks) checks passed. No audio, notifications, email, or private user data accessed.")
    }
}
