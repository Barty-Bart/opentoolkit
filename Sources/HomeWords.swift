import SwiftUI
import AppKit

/// Home's "Your words": the period's most-said words as a cloud. Click a word for its uses per day
/// and the latest dictations that contain it; right-click to hide it. Everything is counted on this Mac.
struct YourWords: View {
    let snapshot: HomeSnapshot
    @ObservedObject var stats: HomeStats
    @ObservedObject var model: AppModel
    let periodPhrase: String
    @State private var selected: String?
    @State private var matches: [HomeStatsQuery.WordMatch] = []
    @State private var lookup: Task<Void, Never>?

    private var words: [HomeSnapshot.CloudWord] { snapshot.wordCloud }
    private var item: HomeSnapshot.CloudWord? { words.first { $0.key == selected } }
    private var appChoices: [String] { snapshot.apps.map(\.name).filter { $0 != "Other" && $0 != "Unknown" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your words").font(.system(size: 14, weight: .semibold))
                    Text("The \(words.count) words you said most \(periodPhrase) · click one to see where").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu(stats.wordsApp ?? "All apps") {
                    Button("All apps") { stats.wordsApp = nil }
                    if !appChoices.isEmpty { Divider() }
                    ForEach(appChoices, id: \.self) { app in Button(app) { stats.wordsApp = app } }
                }.menuStyle(.borderlessButton).fixedSize().help("Show words from one app only")
            }
            if words.isEmpty {
                Text(stats.wordsApp == nil ? "Dictate a little more and your words appear here." : "No words from \(stats.wordsApp!) \(periodPhrase).")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                cloud.frame(maxWidth: .infinity)
                if let item { Divider(); detail(item).transition(.opacity.combined(with: .move(edge: .top))) }
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.06), lineWidth: 1) }
        .onAppear { if selected != nil { load() } }
        .onChange(of: snapshot) { _ in if selected != nil, item == nil { close() } else if selected != nil { load() } }
    }

    /// Sorted by count, then laid out from the middle outwards so the biggest words sit in the centre rows.
    private var arranged: [HomeSnapshot.CloudWord] {
        var left: [HomeSnapshot.CloudWord] = [], right: [HomeSnapshot.CloudWord] = []
        for (index, word) in words.enumerated() { if index.isMultiple(of: 2) { right.append(word) } else { left.insert(word, at: 0) } }
        return left + right
    }
    private var cloud: some View {
        let low = Double(words.map(\.count).min() ?? 1).squareRoot(), high = Double(words.map(\.count).max() ?? 1).squareRoot()
        let topTen = Set(words.prefix(10).map(\.key))
        return FlowLayout(spacing: 14, centred: true) {
            ForEach(arranged) { word in
                let size = 13 + 27 * (high > low ? (Double(word.count).squareRoot() - low) / (high - low) : 1)
                let isSelected = selected == word.key, prominent = topTen.contains(word.key)
                Button { toggle(word) } label: {
                    Text(word.word).font(.system(size: size, weight: prominent ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.cyan : prominent ? Color.primary : Color.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(isSelected ? Color.cyan.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("\(word.word) · \(times(word.count)) · \(change(word.change)) vs \(previousPhrase)")
                .accessibilityLabel("\(word.word), \(times(word.count))")
                .contextMenu { Button("Hide this word") { hide(word) } }
            }
        }
    }

    @ViewBuilder private func detail(_ word: HomeSnapshot.CloudWord) -> some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(word.word).font(.title2.weight(.semibold)).foregroundStyle(.cyan)
                Text("\(times(word.count)) \(periodPhrase)").font(.callout)
                Text("\(change(word.change)) vs \(previousPhrase)").font(.caption.weight(.medium))
                    .foregroundStyle(word.change > 0 ? .green : word.change < 0 ? .red : .secondary)
                bars(word.daily).padding(.top, 4)
                if !word.apps.isEmpty { Text("Mostly in " + word.apps.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).padding(.top, 2) }
                if !word.related.isEmpty {
                    Text("Said with").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    FlowRow(word.related) { near in
                        let target = words.first { $0.word == near }
                        Button { if let target { toggle(target, keepOpen: true) } } label: {
                            Text(near).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.08), in: Capsule())
                        }.buttonStyle(.plain).disabled(target == nil)
                    }
                }
            }.frame(width: 230, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Latest dictations with “\(word.word)”").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Show in history") { model.historyFilter = word.key; model.page = .history }.buttonStyle(.link)
                    Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction).help("Close (Escape)")
                }
                if matches.isEmpty { Text("Looking…").font(.caption).foregroundStyle(.secondary) }
                ForEach(matches) { match in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(highlighted(match)).font(.callout).lineLimit(1).truncationMode(.tail)
                            Text("\(match.app.isEmpty ? "Unknown app" : match.app) · \(when(match.date))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(match.text, forType: .string) }.controlSize(.small)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Uses per day (per hour for Today) as small bars.
    private func bars(_ counts: [Int]) -> some View {
        let top = Double(max(counts.max() ?? 0, 1))
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(counts.enumerated()), id: \.offset) { _, n in
                RoundedRectangle(cornerRadius: 2).fill(n > 0 ? Color.cyan.opacity(0.8) : Color.white.opacity(0.08))
                    .frame(width: counts.count > 10 ? 4 : 18, height: max(3, 34 * Double(n) / top))
            }
        }.frame(height: 34, alignment: .bottom).accessibilityHidden(true)
    }

    private func highlighted(_ match: HomeStatsQuery.WordMatch) -> AttributedString {
        guard let range = match.highlight else { return AttributedString(match.snippet) }
        var text = AttributedString(String(match.snippet[..<range.lowerBound]))
        var word = AttributedString(String(match.snippet[range])); word.font = .callout.bold()
        text += word; text += AttributedString(String(match.snippet[range.upperBound...]))
        return text
    }

    private func toggle(_ word: HomeSnapshot.CloudWord, keepOpen: Bool = false) {
        withAnimation(.easeOut(duration: 0.18)) { selected = selected == word.key && !keepOpen ? nil : word.key }
        if selected == nil { close() } else { load() }
    }
    private func close() { lookup?.cancel(); withAnimation(.easeOut(duration: 0.18)) { selected = nil }; matches = [] }
    private func load() {
        guard let key = selected else { return }
        lookup?.cancel(); matches = []
        let period = snapshot.period, app = stats.wordsApp
        lookup = Task {
            let found = await Task.detached(priority: .userInitiated) { (try? HomeStatsQuery.dictations(db: LibraryDatabase(), containing: key, in: period, app: app)) ?? [] }.value
            if !Task.isCancelled, selected == key { matches = found }
        }
    }
    private func hide(_ word: HomeSnapshot.CloudWord) {
        HomeStatsQuery.setHidden(word.key, true)
        if selected == word.key { close() }
        stats.refresh()
    }

    private var previousPhrase: String { switch stats.period { case .today: return "yesterday"; case .week: return "last week"; case .month: return "last month" } }
    private func times(_ n: Int) -> String { n == 1 ? "once" : "\(n.formatted()) times" }
    private func change(_ n: Int) -> String { n == 0 ? "no change" : (n > 0 ? "+" : "−") + abs(n).formatted() }
    private func when(_ date: Date) -> String {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate(stats.period == .today ? "HH:mm" : "EEE HH:mm"); return f.string(from: date)
    }
}

/// Settings › Dictation: words hidden from Home's word cloud, each with Show to bring it back.
struct HiddenWordsSettings: View {
    @State private var words = HomeStatsQuery.hiddenWords.sorted()
    @State private var open = false
    var body: some View {
        HStack {
            Text("Words hidden from Home: \(words.isEmpty ? "none" : words.count.formatted())").foregroundStyle(.secondary)
            Spacer()
            Button("Hidden words…") { words = HomeStatsQuery.hiddenWords.sorted(); open = true }.disabled(words.isEmpty)
        }
        .onAppear { words = HomeStatsQuery.hiddenWords.sorted() }
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hidden from Your words").font(.headline)
                if words.isEmpty { Text("No hidden words.").foregroundStyle(.secondary) }
                ForEach(words, id: \.self) { word in
                    HStack { Text(word); Spacer(); Button("Show") { HomeStatsQuery.setHidden(word, false); words = HomeStatsQuery.hiddenWords.sorted() } }
                }
            }.padding(14).frame(width: 260)
        }
    }
}
