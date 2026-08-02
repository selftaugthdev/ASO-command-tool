import SwiftUI
import Charts
import ASOCore
import ASOStore

/// Answers "did that change work" for each recorded metadata edit.
struct ImpactView: View {
    @Environment(AppState.self) private var state
    @State private var selected: ChangeImpact.ID?

    var body: some View {
        HSplitView {
            list.frame(minWidth: 320, maxWidth: 460)
            detail.frame(minWidth: 420)
        }
        .task {
            state.reloadImpacts()
            state.reloadCompetitorPresence()
        }
        .onChange(of: state.selectedAppId) { _, _ in state.reloadImpacts() }
        .onChange(of: state.selectedCountry) { _, _ in state.reloadImpacts() }
    }

    private var list: some View {
        Group {
            if state.impacts.isEmpty {
                ContentUnavailableView {
                    Label("No metadata changes recorded", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Every push made here is logged with its exact time and "
                       + "before/after text, and edits made directly in App Store "
                       + "Connect are picked up on the next pull. Rank movement "
                       + "either side of each change is then measured for you.")
                }
            } else {
                List(state.impacts, selection: $selected) { impact in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(impact.event.field.displayName)
                                .font(.callout.weight(.semibold))
                            Text(impact.event.locale)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                            if impact.event.source == .detected {
                                Image(systemName: "eye")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .help("Changed outside this app, noticed on a pull. "
                                        + "The time shown is when it was seen.")
                            }
                            Spacer()
                            MovementBadge(impact: impact)
                        }
                        Text(impact.event.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(impact.event.occurredAt.formatted(date: .abbreviated,
                                                               time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(impact.id)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let impact = state.impacts.first(where: { $0.id == selected }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(impact.event.field.displayName) · \(impact.event.locale)")
                            .font(.title3.weight(.semibold))
                        Text(impact.event.occurredAt.formatted(date: .complete,
                                                               time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // The verdict deliberately refuses to call a result when
                    // the sample is small or the movement is within noise.
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: impact.isConclusive
                              ? (impact.averageMovement ?? 0) > 0
                                ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
                              : "questionmark.circle")
                            .foregroundStyle(impact.isConclusive
                                             ? ((impact.averageMovement ?? 0) > 0
                                                ? Color.green : Color.red)
                                             : Color.secondary)
                            .font(.title2)
                        Text(impact.verdict)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 14) {
                        StatTile(label: "Avg rank before",
                                 value: impact.averageRankBefore
                                    .map { String(format: "#%.1f", $0) } ?? "—")
                        StatTile(label: "Avg rank after",
                                 value: impact.averageRankAfter
                                    .map { String(format: "#%.1f", $0) } ?? "—")
                        StatTile(label: "Improved", value: "\(impact.improved)",
                                 tint: impact.improved > 0 ? .green : nil)
                        StatTile(label: "Declined", value: "\(impact.declined)",
                                 tint: impact.declined > 0 ? .red : nil)
                        Spacer()
                    }

                    if impact.event.field == .keywords {
                        DiffPair(before: impact.event.oldValue,
                                 after: impact.event.newValue)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("Select a change",
                                   systemImage: "sidebar.right",
                                   description: Text("See what moved after it."))
        }
    }
}

struct MovementBadge: View {
    let impact: ChangeImpact

    var body: some View {
        if let movement = impact.averageMovement, impact.isConclusive {
            Label {
                Text(String(format: "%.1f", abs(movement))).monospacedDigit()
            } icon: {
                Image(systemName: movement > 0 ? "arrow.up" : "arrow.down")
            }
            .font(.caption2)
            .foregroundStyle(movement > 0 ? .green : .red)
        } else {
            Text("inconclusive")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }
}

struct DiffPair: View {
    let before: String?
    let after: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What changed").font(.headline)
            HStack(alignment: .top, spacing: 8) {
                Text("−").foregroundStyle(.red).font(.body.monospaced())
                Text(before?.isEmpty == false ? before! : "(empty)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("+").foregroundStyle(.green).font(.body.monospaced())
                Text(after?.isEmpty == false ? after! : "(empty)")
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Who else holds the keyword set already being tracked.
struct KeywordOwnershipView: View {
    @Environment(AppState.self) private var state
    // Top-ten count descending: the apps actually standing between you and the
    // first page, rather than everything that merely appears somewhere.
    @State private var sortOrder: [KeyPathComparator<CompetitorPresence>] = [
        .init(\.topTen, order: .reverse)
    ]

    // Split into named subviews rather than one expression: the combined
    // Table plus ContentUnavailableView exceeded what the type checker will
    // solve in reasonable time.
    var body: some View {
        Group {
            if state.presence.isEmpty { emptyState } else { table }
        }
        .task { state.reloadCompetitorPresence() }
        .onChange(of: state.selectedAppId) { _, _ in state.reloadCompetitorPresence() }
        .onChange(of: state.selectedCountry) { _, _ in state.reloadCompetitorPresence() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No result data captured yet", systemImage: "person.2.slash")
        } description: {
            Text("Run Refresh Ranks. Every lookup already returns the other apps "
               + "in the results, so this is built from data the refresh collects "
               + "anyway — no extra requests, and no probing competitors one at a time.")
        } actions: {
            Button("Refresh Ranks") {
                state.start { await state.refreshRanks() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.keywords.isEmpty || state.isBusy)
        }
    }

    private var trackedCount: Int { state.keywords.count }

    private var table: some View {
        Table(state.presence.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("App", value: \.appName) { row in
                OwnershipNameCell(row: row)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Appears in", value: \.appearances) { (row: CompetitorPresence) in
                Text("\(row.appearances)/\(trackedCount)")
                    .monospacedDigit()
                    .help("Tracked keywords whose top 10 includes this app")
            }
            .width(90)

            TableColumn("Top 10", value: \.topTen) { (row: CompetitorPresence) in
                Text("\(row.topTen)")
                    .monospacedDigit()
                    .foregroundStyle(row.topTen > 0 ? Color.primary : Color.secondary)
            }
            .width(70)

            TableColumn("Avg pos", value: \.averageRank) { (row: CompetitorPresence) in
                Text(String(format: "#%.1f", row.averageRank))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(80)

            TableColumn("Beats you on") { (row: CompetitorPresence) in
                OwnershipBeatsCell(row: row)
            }
            .width(min: 160, ideal: 280)
        }
    }
}

private struct OwnershipNameCell: View {
    let row: CompetitorPresence

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(row.appName).fontWeight(.medium).lineLimit(1)
            if let ratings = row.ratingCount {
                Text("\(ratings) ratings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OwnershipBeatsCell: View {
    let row: CompetitorPresence

    var body: some View {
        Text(row.beatsUsOn.prefix(4).joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(row.beatsUsOn.isEmpty
                  ? "Nothing — you outrank them everywhere you both appear."
                  : row.beatsUsOn.joined(separator: "\n"))
    }
}
