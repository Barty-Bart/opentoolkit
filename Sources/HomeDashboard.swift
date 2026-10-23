import SwiftUI
import Charts

/// Home: a local summary of how you used OpenToolkit (from HomeStats), with quick actions.
struct HomeDashboard: View {
    @ObservedObject var model: AppModel
    @StateObject private var stats = HomeStats()
    @AppStorage(UsageLog.enabledKey) private var enabled = true
    @State private var measuring = false
    @State private var cloudWord: String?
    private let refresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// Bigger words are said more. Click one to see the words you say near it.
    @ViewBuilder private func wordCloud(_ words: [HomeSnapshot.CloudWord]) -> some View {
        let most = Double(words.map(\.count).max() ?? 1)
        // Alphabetical order mixes large and small words, as a cloud should.
        FlowRow(words.sorted { $0.word.lowercased() < $1.word.lowercased() }) { item in
            let weight = (Double(item.count) / most).squareRoot()
            let selected = cloudWord == item.word
            Button { cloudWord = selected ? nil : item.word } label: {
                Text(item.word).font(.system(size: 11 + 13 * weight, weight: weight > 0.6 ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.5 + 0.5 * weight))
            }.buttonStyle(.plain).help("Said \(item.count.formatted()) times · click for words you say near it")
        }
        if let word = cloudWord, let item = words.first(where: { $0.word == word }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.related.isEmpty ? "Nothing said near “\(word)” yet." : "Said near “\(word)”").font(.caption).foregroundStyle(.secondary)
                if !item.related.isEmpty {
                    FlowRow(item.related) { near in
                        let inCloud = words.contains { $0.word == near }
                        Button { if inCloud { cloudWord = near } } label: {
                            Text(near).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 4).background(.white.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain).disabled(!inCloud)
                    }
                }
            }.padding(.top, 4)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 22, weight: .semibold))
                    Text(dateRange).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Period", selection: $stats.period) { ForEach(HomePeriod.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 240).labelsHidden()
            }.padding(.top, 4)
            if !enabled {
                ToolCard(title: "Usage summary is off", subtitle: "Turn it on to see your week here. It's counted on this Mac and never leaves it.") {
                    Button("Show usage on Home") { enabled = true; stats.refresh() }
                }
            } else if let s = stats.snapshot {
                if s.isEmpty {
                    ToolCard(title: "Nothing yet \(periodPhrase.lowercased())", subtitle: "Use OpenToolkit for a few days and your week appears here. Screenshots removed by retention and drawing before this update can't be counted.") { EmptyView() }
                } else { content(s) }
            } else if let failure = stats.failure {
                ToolCard(title: "Couldn't load your summary", subtitle: failure) { Button("Try again") { stats.refresh() } }
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 120) }
        }
        .sheet(isPresented: $measuring, onDismiss: { stats.refresh() }) { TypingTest() }
        .onAppear { stats.refresh() }
        .onReceive(refresh) { _ in stats.refresh() }
    }

    private var headline: String { switch stats.period { case .today: return "Today"; case .week: return "Your week"; case .month: return "This month" } }
    private var dateRange: String {
        let calendar = Calendar.current, now = Date()
        guard let interval = calendar.dateInterval(of: stats.period.component, for: now) else { return "" }
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate(stats.period == .month ? "MMMM yyyy" : "EEE d MMM")
        if stats.period == .today { return f.string(from: now) }
        if stats.period == .month { return f.string(from: now) }
        return f.string(from: interval.start) + " – " + f.string(from: interval.end.addingTimeInterval(-1))
    }
    private var periodPhrase: String { switch stats.period { case .today: return "Today"; case .week: return "This week"; case .month: return "This month" } }
    private var previousPhrase: String { switch stats.period { case .today: return "yesterday"; case .week: return "last week"; case .month: return "last month" } }

    @ViewBuilder private func content(_ s: HomeSnapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            tile("Words dictated", s.words.formatted(), change(s.words, s.previousWords), .cyan)
            tile("Typing time saved", duration(Double(s.typingMinutesSaved) * 60), "vs typing at \(Int(HomeStatsQuery.typingWordsPerMinute)) wpm", .cyan, action: ("Measure", { measuring = true }))
            tile("Screenshots", s.screenshots.formatted(), change(s.screenshots, s.previousScreenshots), .blue)
            tile("Recordings", (s.recordings + s.gifs).formatted(), s.gifs > 0 ? "\(s.gifs) GIF\(s.gifs == 1 ? "" : "s")" : (s.recordingSeconds > 0 ? duration(s.recordingSeconds) : ""), .red)
            tile("Drawing", s.drawingSessions.formatted(), s.drawingSeconds > 0 ? duration(s.drawingSeconds) + " on screen" : "sessions", .orange)
        }
        HStack(alignment: .top, spacing: 12) {
            ToolCard(title: "When you work", subtitle: busiestLine(s)) { heatmap(s) }
            ToolCard(title: "Where you dictate", subtitle: "Words by app") {
                if s.apps.isEmpty { Text("No dictation \(periodPhrase.lowercased()).").foregroundStyle(.secondary) }
                else {
                    Chart(s.apps, id: \.name) { app in
                        BarMark(x: .value("Words", app.words), y: .value("App", app.name)).foregroundStyle(Color.cyan.gradient)
                            .annotation(position: .trailing) { Text(app.words.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }.chartXAxis(.hidden).frame(height: CGFloat(s.apps.count) * 26 + 8)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 12) {
            ToolCard(title: "Words you say most", subtitle: "") {
                if s.wordCloud.isEmpty { Text("Not enough dictation yet.").foregroundStyle(.secondary) }
                else { wordCloud(s.wordCloud) }
            }
            ToolCard(title: "Dictation habits", subtitle: "") {
                fact("Dictations", s.dictations.formatted())
                fact("Speaking speed", s.wordsPerMinute.map { "\($0) wpm" } ?? "—")
                fact("Longest dictation", s.longestSeconds > 0 ? duration(s.longestSeconds) : "—")
            }
            ToolCard(title: "Tools you used", subtitle: "") {
                fact("Hey Toolkit commands", s.wakeCommands.formatted())
                fact("Screenshots copied or saved", s.exports.formatted())
                fact("Corrections learned", s.correctionsLearned.formatted())
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private func tile(_ title: String, _ value: String, _ detail: String, _ accent: Color, action: (String, () -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(title).font(.caption).foregroundStyle(.secondary); Spacer()
                if let action { Button(action.0, action: action.1).buttonStyle(.link).font(.caption2).help("Type a short paragraph to measure your real typing speed") } }
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
            Text(detail.isEmpty ? " " : detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.06), lineWidth: 1) }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.callout)
    }
    private func change(_ now: Int, _ before: Int) -> String {
        guard before > 0 else { return now > 0 ? "new \(periodPhrase.lowercased())" : "" }
        let percent = Int((Double(now - before) / Double(before) * 100).rounded())
        return percent == 0 ? "same as \(previousPhrase)" : "\(percent > 0 ? "+" : "")\(percent)% vs \(previousPhrase)"
    }
    private func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if seconds < 60 { return "\(Int(seconds.rounded())) s" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
    private func busiestLine(_ s: HomeSnapshot) -> String {
        guard let b = s.busiest else { return "Dictation and captures by hour" }
        func clock(_ hour: Int) -> String { let h = hour % 24; return h == 0 ? "12 am" : h < 12 ? "\(h) am" : h == 12 ? "12 pm" : "\(h - 12) pm" }
        return "Busiest: \(days[b.weekday]), \(clock(b.hour))–\(clock(b.hour + 1))"
    }
    private func heatCell(day: Int, hour: Int, count: Int, peak: Int) -> some View {
        let strength: Double = count == 0 ? 0 : 0.25 + 0.75 * Double(count) / Double(peak)
        let fill: Color = count == 0 ? Color.white.opacity(0.06) : Color.cyan.opacity(strength)
        let label: String = "\(days[day]) \(hour):00"
        return RoundedRectangle(cornerRadius: 3).fill(fill).frame(height: 16)
            .help("\(label) · \(count)").accessibilityLabel(label).accessibilityValue("\(count)")
    }
    private func hourLabel(_ hour: Int) -> String {
        guard hour % 3 == 1 else { return "" }
        if hour == 12 { return "12p" }
        return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }
    /// Days × hours (7 am–10 pm) as a grid of rounded cells; darker cells mean more activity.
    private func heatmap(_ s: HomeSnapshot) -> some View {
        let hours = Array(7...22), peak = max(1, s.heatmap.flatMap { $0[7...22] }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<7, id: \.self) { day in
                HStack(spacing: 3) {
                    Text(days[day]).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    ForEach(hours, id: \.self) { hour in heatCell(day: day, hour: hour, count: s.heatmap[day][hour], peak: peak) }
                }
            }
            HStack(spacing: 3) {
                Color.clear.frame(width: 28, height: 1)
                ForEach(hours, id: \.self) { hour in
                    Text(hourLabel(hour)).font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// Wrapping row of small views (words you say most).
private struct FlowRow<Item: Hashable, Content: View>: View {
    let items: [Item]; let content: (Item) -> Content
    init(_ items: [Item], @ViewBuilder content: @escaping (Item) -> Content) { self.items = items; self.content = content }
    var body: some View {
        FlowLayout(spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}
private struct FlowLayout: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400; var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews { let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height) }
        return CGSize(width: width, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // Rows are filled first, then each item is centred vertically in its row (mixed sizes in the word cloud).
        var rows: [[(LayoutSubview, CGSize)]] = [[]], x = bounds.minX
        for view in subviews { let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { rows.append([]); x = bounds.minX }
            rows[rows.count - 1].append((view, size)); x += size.width + spacing }
        var y = bounds.minY
        for row in rows {
            let height = row.map(\.1.height).max() ?? 0; x = bounds.minX
            for (view, size) in row { view.place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size)); x += size.width + spacing }
            y += height + spacing
        }
    }
}

/// Settings: turn the Home summary off, or clear its usage log (never dictations or captures).
struct UsageSettings: View {
    @AppStorage(UsageLog.enabledKey) private var enabled = true
    @State private var confirmReset = false
    @State private var measuring = false
    @State private var message = ""
    var body: some View {
        ToolCard(title: "Home summary", subtitle: "Counts what you did and when, on this Mac only. No text, file names or app content is logged.") {
            Toggle("Show usage on Home", isOn: $enabled)
            HStack {
                Text("Typing speed for \u{201C}time saved\u{201D}"); Spacer()
                Text("\(Int(HomeStatsQuery.typingWordsPerMinute)) wpm\(UserDefaults.standard.double(forKey: "typingWordsPerMinute") > 0 ? " (measured)" : " (default)")").foregroundStyle(.secondary).monospacedDigit()
                Button("Measure…") { measuring = true }
            }
            HStack {
                Button("Reset statistics…") { confirmReset = true }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .sheet(isPresented: $measuring) { TypingTest() }
        .confirmationDialog("Reset usage statistics?", isPresented: $confirmReset) {
            Button("Reset statistics", role: .destructive) {
                do { try LibraryDatabase().execute("DELETE FROM usage_events"); message = "Statistics reset. Your dictations and screenshots are unchanged." }
                catch { message = "Couldn't reset: \(error.localizedDescription)" }
            }
        } message: { Text("This clears the Home counts for screenshots, recordings and drawing. Your dictation history, screenshots and settings are not touched.") }
    }
}

/// Measures real typing speed so "time saved" compares dictation with how fast *you* type.
/// Only correctly typed characters count (5 characters = 1 word), so typos don't inflate it.
struct TypingTest: View {
    @Environment(\.dismiss) private var dismiss
    private let sample = "The quick summary is ready for review. Please send the final draft to the team before the meeting on Friday, and let me know if anything needs to change."
    @State private var typed = ""
    @State private var started: Date?
    @State private var finished: Date?
    @State private var now = Date()
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private var elapsed: Double { guard let started else { return 0 }; return (finished ?? now).timeIntervalSince(started) }
    private var result: (wpm: Int, accuracy: Int) { HomeStatsQuery.typingScore(sample: sample, typed: typed, seconds: elapsed) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Measure your typing speed").font(.title2.weight(.semibold))
            Text("Type the text below as you normally would. The timer starts with your first key.").foregroundStyle(.secondary)
            Text(sample).font(.system(.body, design: .serif)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            TextEditor(text: $typed).font(.body).frame(height: 110).scrollContentBackground(.hidden).padding(8).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: typed) { value in
                    if started == nil, !value.isEmpty { started = Date() }
                    if finished == nil, value.count >= sample.count { finished = Date() }
                }
            HStack {
                Text(started == nil ? "Waiting for your first key…" : "\(result.wpm) wpm · \(result.accuracy)% accurate · \(Int(elapsed)) s").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save \(result.wpm) wpm") { UserDefaults.standard.set(Double(result.wpm), forKey: "typingWordsPerMinute"); dismiss() }
                    .buttonStyle(.borderedProminent).disabled(elapsed < 10 || result.wpm < 10 || result.accuracy < 70)
                    .help("Type for at least 10 seconds with at least 70% accuracy")
            }
        }.padding(22).frame(width: 560).onReceive(tick) { now = $0 }
    }
}
