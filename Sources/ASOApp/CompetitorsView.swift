import SwiftUI
import ASOCore
import ASOStore
import KeywordKit

struct CompetitorsView: View {
    @Environment(AppState.self) private var state
    @State private var input = ""
    @State private var competitors: [(id: String, name: String, country: String)] = []
    @State private var overlap: CompetitorOverlap?
    @State private var selectedCompetitorId: String?

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            HSplitView {
                list.frame(minWidth: 240, maxWidth: 320)
                detail.frame(minWidth: 460)
            }
        }
        .task { reload() }
        .onChange(of: state.selectedAppId) { _, _ in
            reload()
            overlap = nil
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            TextField("App Store URL or numeric app id", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add Competitor", action: add)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || state.isBusy)
        }
        .padding(12)
        .background(.bar)
    }

    private func add() {
        guard let app = state.selectedApp else { return }
        guard let id = iTunesSearchClient.appId(from: input) else {
            state.report(.error, "Could not read an app id from that. Paste an App Store "
                               + "URL or the numeric id.")
            return
        }
        input = ""
        Task {
            do {
                let search = iTunesSearchClient()
                guard let found = try await search.lookup(ids: [id],
                                                          country: state.selectedCountry).first
                else {
                    state.report(.error, "No app with id \(id) in the "
                                       + "\(state.selectedCountry.uppercased()) store")
                    return
                }
                try state.store.addCompetitor(appId: app.id, competitorId: found.id,
                                              name: found.name,
                                              country: state.selectedCountry)
                let analyzer = CompetitorAnalyzer(store: state.store, search: search)
                try await analyzer.snapshot(competitorId: found.id,
                                            country: state.selectedCountry)
                reload()
                state.report(.success, "Added \(found.name)")
            } catch {
                state.report(.error, "Could not add competitor: \(error.localizedDescription)")
            }
        }
    }

    private func reload() {
        guard let appId = state.selectedAppId else { competitors = []; return }
        competitors = (try? state.store.competitors(appId: appId)) ?? []
    }

    private var list: some View {
        List(competitors, id: \.id, selection: $selectedCompetitorId) { competitor in
            VStack(alignment: .leading, spacing: 2) {
                Text(competitor.name).lineLimit(1)
                Text(competitor.country.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .tag(competitor.id)
        }
        .overlay {
            if competitors.isEmpty {
                ContentUnavailableView("No competitors",
                                       systemImage: "person.2",
                                       description: Text("Add one above to compare keywords."))
            }
        }
        .onChange(of: selectedCompetitorId) { _, newValue in
            guard let newValue else { return }
            analyze(competitorId: newValue)
        }
    }

    private func analyze(competitorId: String) {
        guard let app = state.selectedApp else { return }
        overlap = nil
        Task {
            do {
                let analyzer = CompetitorAnalyzer(store: state.store)
                overlap = try await analyzer.overlap(competitorId: competitorId,
                                                     app: app,
                                                     country: state.selectedCountry)
            } catch {
                state.report(.error, "Analysis failed: \(error.localizedDescription)")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let overlap {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(overlap.competitor.name).font(.title2.weight(.semibold))
                        Text(overlap.competitor.sellerName)
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 14) {
                            Label(String(format: "%.1f", overlap.competitor.averageRating),
                                  systemImage: "star.fill")
                            Text("\(overlap.competitor.ratingCount) ratings")
                            Text("v\(overlap.competitor.version)")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Text("Keyword sets are estimated from public title, subtitle and "
                       + "description text. Apple does not expose a competitor's keywords field.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 6))

                    if !overlap.losingTerms.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("They outrank you (\(overlap.losingTerms.count))",
                                  systemImage: "arrow.down.right")
                                .font(.headline)
                                .foregroundStyle(.red)

                            ForEach(overlap.losingTerms, id: \.term) { entry in
                                HStack {
                                    Text(entry.term).fontWeight(.medium)
                                    Spacer()
                                    Text(entry.ours.map { "you #\($0)" } ?? "you unranked")
                                        .foregroundStyle(.red)
                                    Text("them #\(entry.theirs)")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout.monospacedDigit())
                            }
                        }
                    }

                    TermCloud(title: "Shared terms (\(overlap.sharedTerms.count))",
                              terms: overlap.sharedTerms, tint: .blue)

                    TermCloud(title: "Gaps — they target, you don't (\(overlap.gapTerms.count))",
                              terms: overlap.gapTerms, tint: .orange,
                              onTap: { term in
                                  Task { await state.research(terms: [term]) }
                              })
                }
                .padding(20)
            }
        } else if selectedCompetitorId != nil {
            ProgressView("Analyzing overlap…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("Select a competitor",
                                   systemImage: "chart.bar.doc.horizontal",
                                   description: Text("See shared keywords and gaps."))
        }
    }
}

struct TermCloud: View {
    let title: String
    let terms: [String]
    let tint: Color
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if terms.isEmpty {
                Text("None").font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(terms, id: \.self) { term in
                        Button {
                            onTap?(term)
                        } label: {
                            Text(term)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(tint.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(onTap == nil)
                        .help(onTap == nil ? term : "Track \"\(term)\"")
                    }
                }
            }
        }
    }
}

/// Wraps subviews onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct AlertsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        List {
            ForEach(state.alerts) { alert in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: alert.severity))
                        .foregroundStyle(color(for: alert.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title).fontWeight(.medium)
                        Text(alert.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(alert.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if !alert.acknowledged {
                        Button("Dismiss") {
                            try? state.store.acknowledgeAlert(id: alert.id)
                            state.reloadAlerts()
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 4)
                .opacity(alert.acknowledged ? 0.5 : 1)
            }
        }
        .overlay {
            if state.alerts.isEmpty {
                ContentUnavailableView(
                    "No alerts",
                    systemImage: "bell.slash",
                    description: Text("Rank drops, competitor changes and CPA spikes "
                                    + "will appear here once the scheduled check runs."))
            }
        }
        .task { state.reloadAlerts() }
    }

    private func icon(for severity: ASOAlert.Severity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private func color(for severity: ASOAlert.Severity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}
