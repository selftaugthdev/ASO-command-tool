import SwiftUI
import Charts
import ASOCore
import ASOStore
import KeywordKit

struct KeywordsView: View {
    @Environment(AppState.self) private var state
    @State private var newTerms = ""
    @State private var showingImport = false
    @State private var showingChart = true
    @State private var selection: Set<Int64> = []
    // Popularity descending by default: on a list of a few hundred imported
    // terms, alphabetical order buries the handful actually worth working on.
    @State private var sortOrder: [KeyPathComparator<TrackedKeyword>] = [
        .init(\.sortPopularity, order: .reverse)
    ]

    private var sortedKeywords: [TrackedKeyword] {
        state.keywords.sorted(using: sortOrder)
    }

    var body: some View {
        // The add bar sits in the VStack rather than as a safeAreaInset so it
        // occupies real layout space; as an inset the table scrolled beneath it
        // and hid its own column headers.
        // Deliberately not a VSplitView. That control asks its children for an
        // ideal height and autosaves the result against the window; once a tall
        // value was persisted it forced the whole detail pane past the window
        // height on every later launch, pushing the toolbar and column headers
        // off the top of the screen. A fixed-height, collapsible chart cannot
        // report a height the window does not have.
        VStack(spacing: 0) {
            addBar
            Divider()
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showingChart {
                Divider()
                chart
                    .frame(height: 200)
            }
        }
        .sheet(isPresented: $showingImport) { ImportView() }
    }

    // MARK: Add bar

    private var addBar: some View {
        HStack(spacing: 10) {
            TextField("Add keywords, comma separated", text: $newTerms)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            Button("Research", action: submit)
                .disabled(newTerms.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy)

            Divider().frame(height: 20)

            Button {
                showingImport = true
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .disabled(state.isBusy)
            .help("Import a keyword list exported from another ASO tool")

            Button {
                state.start { await state.refreshRanks() }
            } label: {
                Label("Refresh Ranks", systemImage: "arrow.clockwise")
            }
            .disabled(state.keywords.isEmpty || state.isBusy)
            .help(refreshEstimateHelp)

            Button {
                showingChart.toggle()
            } label: {
                Label("Chart", systemImage: showingChart
                      ? "chart.xyaxis.line" : "chart.xyaxis.line")
                    .foregroundStyle(showingChart ? Color.accentColor : .secondary)
            }
            .help(showingChart ? "Hide the rank trend chart" : "Show the rank trend chart")
        }
        .padding(12)
        .background(.bar)
    }

    /// Sets expectations before the click, not after: a few hundred keywords is
    /// a genuinely long run and the button should say so.
    private var refreshEstimateHelp: String {
        guard !state.keywords.isEmpty else {
            return "Re-check the store position of every tracked keyword"
        }
        let seconds = OperationProgress.initialEstimate(
            itemCount: state.keywords.count,
            secondsPerItem: KeywordResearcher.secondsPerKeywordLookup)
        return "Re-check all \(state.keywords.count) keywords — "
             + "takes \(OperationProgress.describe(seconds)). You can stop part way; "
             + "whatever finished is saved."
    }

    private func submit() {
        let terms = newTerms
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }
        newTerms = ""
        state.start { await state.research(terms: terms) }
    }

    // MARK: Table

    private var table: some View {
        Table(sortedKeywords, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Keyword", value: \.term) { keyword in
                Text(keyword.term)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(keyword.term)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Rank", value: \.sortRank) { keyword in
                if let rank = keyword.currentRank {
                    Text("#\(rank)")
                        .monospacedDigit()
                        .foregroundStyle(rank <= 10 ? .green : rank <= 50 ? .primary : .secondary)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .help("Not in the top 100 results")
                }
            }
            .width(60)

            TableColumn("Δ", value: \.sortDelta) { keyword in
                RankDeltaBadge(delta: keyword.rankDelta)
            }
            .width(56)

            TableColumn("Popularity", value: \.sortPopularity) { keyword in
                let source = MetricSource(rawValue: keyword.popularitySource) ?? .unknown
                if let popularity = keyword.popularity {
                    // Source is carried by tint and tooltip rather than a
                    // stacked caption: a two-line cell overflows the fixed row
                    // height and clips against its neighbours.
                    MetricBar(value: popularity,
                              tint: source == .appleSearchAds ? .blue : .purple)
                        .help(source.explanation)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help(MetricSource.unknown.explanation)
                }
            }
            // Capped so the Keyword column absorbs the slack on a wide window
            // instead of the metric columns stretching.
            .width(min: 90, ideal: 105, max: 130)

            TableColumn("Difficulty", value: \.sortDifficulty) { keyword in
                if let difficulty = keyword.difficulty {
                    MetricBar(value: difficulty, tint: difficulty > 66 ? .red
                                                  : difficulty > 33 ? .orange : .green)
                } else {
                    Text("—")
                        .foregroundStyle(.tertiary)
                        .help("Run Refresh Ranks to score difficulty")
                }
            }
            // Capped so the Keyword column absorbs the slack on a wide window
            // instead of the metric columns stretching.
            .width(min: 90, ideal: 105, max: 130)

            TableColumn("Competitors", value: \.sortCompetitors) { keyword in
                Text(keyword.competitors.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(80)
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            Button("Remove", role: .destructive) {
                for id in ids { try? state.store.removeKeyword(id: id) }
                state.reloadKeywords()
            }
        }
        .overlay {
            if state.keywords.isEmpty {
                ContentUnavailableView(
                    "No keywords tracked",
                    systemImage: "magnifyingglass",
                    description: Text("Add terms above to pull rank, difficulty and "
                                    + "Apple search popularity."))
            }
        }
    }

    // MARK: Chart

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Rank trend")
                    .font(.headline)
                Spacer()
                if !selection.isEmpty {
                    Text("\(selection.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            let series = chartSeries
            if series.isEmpty {
                ContentUnavailableView(
                    "No rank history yet",
                    systemImage: "chart.xyaxis.line",
                    description: Text("History builds up each time ranks are refreshed."))
            } else {
                Chart {
                    ForEach(series, id: \.term) { entry in
                        ForEach(entry.points) { point in
                            if let rank = point.rank {
                                LineMark(
                                    x: .value("Date", point.capturedAt),
                                    y: .value("Rank", rank))
                                .foregroundStyle(by: .value("Keyword", entry.term))
                                .symbol(by: .value("Keyword", entry.term))
                                .interpolationMethod(.monotone)
                            }
                        }
                    }
                }
                // Rank 1 is best, so the axis is inverted: up means improving.
                .chartYScale(domain: .automatic(includesZero: false, reversed: true))
                .chartYAxisLabel("Position")
                .chartLegend(position: .bottom, alignment: .leading)
                .padding(14)
            }
        }
    }

    /// Charts the selected keywords, or the ten best-ranked when nothing is selected.
    private var chartSeries: [(term: String, points: [RankPoint])] {
        let candidates: [TrackedKeyword]
        if selection.isEmpty {
            candidates = Array(state.keywords
                .filter { $0.currentRank != nil }
                .sorted { ($0.currentRank ?? .max) < ($1.currentRank ?? .max) }
                .prefix(10))
        } else {
            candidates = state.keywords.filter { selection.contains($0.id) }
        }

        return candidates.compactMap { keyword in
            guard let points = state.rankHistory[keyword.id],
                  points.contains(where: { $0.rank != nil }) else { return nil }
            return (keyword.term, points)
        }
    }
}

struct RankDeltaBadge: View {
    let delta: Int?

    var body: some View {
        if let delta, delta != 0 {
            Label {
                Text("\(abs(delta))").monospacedDigit()
            } icon: {
                Image(systemName: delta > 0 ? "arrow.up" : "arrow.down")
            }
            .font(.caption)
            .foregroundStyle(delta > 0 ? .green : .red)
            .help(delta > 0 ? "Improved \(delta) position(s)" : "Dropped \(-delta) position(s)")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// A 0–100 metric shown as a labelled bar.
struct MetricBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            // Number first, then the bar: the digits are the part actually read,
            // and a leading fixed-width column keeps them aligned down the table.
            Text(String(Int(value.rounded())))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 22, alignment: .trailing)

            // Capped, not maxWidth: .infinity. A Table stretches its columns to
            // fill the window, and an unbounded bar became metres long on a
            // wide display while the numbers drifted apart.
            Capsule()
                .fill(.quaternary)
                .frame(width: 54, height: 5)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: 54 * min(1, max(0, value / 100)), height: 5)
                }

            Spacer(minLength: 0)
        }
    }
}
