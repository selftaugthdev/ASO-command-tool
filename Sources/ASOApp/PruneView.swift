import SwiftUI
import ASOCore
import ASOStore
import KeywordKit

/// Bulk-removes low-popularity keywords, behind a preview and a confirm step.
///
/// Deleting a few hundred rows is not undoable, so the sheet shows exactly what
/// would go before anything is removed.
struct PruneView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var threshold: Double = 10
    @State private var allApps = false
    @State private var includeUnknown = false

    private var doomed: [TrackedKeyword] {
        state.lowPopularityPreview(threshold: threshold, allApps: allApps,
                                   includeUnknown: includeUnknown)
    }

    private var remainingEstimate: String {
        let removed = doomed.count
        let total = allApps
            ? (try? state.store.trackedAppCountryPairs().reduce(0) { $0 + $1.count }) ?? 0
            : state.keywords.count
        let remaining = max(0, total - removed)
        let seconds = OperationProgress.initialEstimate(
            itemCount: remaining,
            secondsPerItem: KeywordResearcher.secondsPerKeywordLookup)
        return "\(remaining) keyword(s) left, "
             + "a refresh would take \(OperationProgress.describe(seconds))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove low-popularity keywords")
                    .font(.title2.weight(.semibold))
                Text("Apple's popularity index bottoms out at 5, which means "
                   + "effectively nobody searches the term. Ranking well for those "
                   + "costs refresh time and returns nothing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Remove below popularity")
                        Text(String(Int(threshold)))
                            .font(.body.monospacedDigit().weight(.semibold))
                        Spacer()
                    }
                    Slider(value: $threshold, in: 5...60, step: 1) {
                        Text("Threshold")
                    } minimumValueLabel: {
                        Text("5").font(.caption2)
                    } maximumValueLabel: {
                        Text("60").font(.caption2)
                    }
                }

                Toggle("Across all apps", isOn: $allApps)
                    .toggleStyle(.checkbox)

                Toggle("Also remove keywords with no popularity data", isOn: $includeUnknown)
                    .toggleStyle(.checkbox)
                    .help("Off by default: no data means never measured, not "
                        + "measured as low. Turning this on deletes anything that "
                        + "has not been researched yet.")
            }
            .padding(20)

            Divider()

            HStack(spacing: 8) {
                Image(systemName: doomed.isEmpty ? "checkmark.circle" : "trash")
                    .foregroundStyle(doomed.isEmpty ? Color.secondary : Color.red)
                Text(doomed.isEmpty
                     ? "Nothing matches — no keywords would be removed."
                     : "\(doomed.count) keyword(s) would be removed.")
                    .font(.callout.weight(.medium))
                Spacer()
                Text(remainingEstimate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Table(Array(doomed.prefix(500))) {
                TableColumn("Keyword", value: \.term)
                TableColumn("Popularity") { keyword in
                    Text(keyword.popularity.map { String(Int($0)) } ?? "none")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(90)
                TableColumn("Rank") { keyword in
                    Text(keyword.currentRank.map { "#\($0)" } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Country") { keyword in
                    Text(keyword.country.uppercased())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .width(70)
            }
            .frame(minHeight: 200)

            Divider()

            HStack {
                if doomed.contains(where: { ($0.currentRank ?? .max) <= 10 }) {
                    Label("Some of these currently rank in the top 10",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help("Ranking well for a term nobody searches is usually "
                            + "still not worth tracking, but worth a look first.")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove \(doomed.count)") {
                    state.removeKeywords(doomed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(doomed.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 660)
    }
}
