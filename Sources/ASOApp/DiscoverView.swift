import SwiftUI
import ASOCore
import ASOStore
import KeywordKit

/// Finds keyword openings in non-English storefronts.
struct DiscoverView: View {
    @Environment(AppState.self) private var state

    @State private var selectedCountries: Set<String> = ["de", "nl", "fr", "es"]
    @State private var seedText = ""
    @State private var maxCandidates = 25
    @State private var sortOrder: [KeyPathComparator<LocaleOpportunity>] = [
        .init(\.score, order: .reverse)
    ]

    private var seeds: [String] {
        let typed = seedText
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard typed.isEmpty else { return typed }
        // Default to the strongest terms already tracked: they are what the app
        // is actually about, in the market where its data is best.
        return state.keywords
            .filter { ($0.popularity ?? 0) >= 20 }
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .prefix(6)
            .map(\.term)
    }

    private var estimate: String {
        let requests = LocaleOpportunityFinder.estimatedRequests(
            seedCount: seeds.count,
            storefronts: selectedCountries.count,
            candidatesPerStorefront: maxCandidates)
        let seconds = OperationProgress.initialEstimate(
            itemCount: requests,
            secondsPerItem: KeywordResearcher.secondsPerKeywordLookup)
        return "\(requests) lookups, \(OperationProgress.describe(seconds))"
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if state.opportunities.isEmpty {
                ContentUnavailableView {
                    Label("No localized openings found yet", systemImage: "globe")
                } description: {
                    Text("English keywords with real demand are contested by every "
                       + "funded competitor. The same idea in a smaller storefront "
                       + "often is not. This searches those stores, reads what the "
                       + "apps ranking there actually call themselves, and scores "
                       + "the vocabulary you are missing.")
                } actions: {
                    Button("Find openings") { run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRun)
                }
            } else {
                table
            }
        }
    }

    private var canRun: Bool {
        !state.isBusy && !selectedCountries.isEmpty && !seeds.isEmpty
            && state.selectedApp != nil
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Seed terms (blank uses your strongest tracked keywords)",
                          text: $seedText)
                    .textFieldStyle(.roundedBorder)

                Stepper("Depth \(maxCandidates)", value: $maxCandidates, in: 10...60, step: 5)
                    .frame(width: 130)

                Button("Find openings") { run() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRun)
            }

            HStack(spacing: 6) {
                Text("Stores").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(Storefront.prospects) { storefront in
                            let isOn = selectedCountries.contains(storefront.country)
                            Button {
                                if isOn { selectedCountries.remove(storefront.country) }
                                else { selectedCountries.insert(storefront.country) }
                            } label: {
                                Text(storefront.country.uppercased())
                                    .font(.caption.monospaced())
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(isOn ? Color.accentColor.opacity(0.25)
                                                     : Color.secondary.opacity(0.12),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(storefront.name)
                        }
                    }
                }
                Spacer()
                Text(estimate).font(.caption).foregroundStyle(.secondary)
            }

            if !seeds.isEmpty && seedText.isEmpty {
                Text("Seeding from: \(seeds.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var table: some View {
        Table(state.opportunities.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Keyword", value: \.term) { row in
                Text(row.term).fontWeight(.medium).lineLimit(1).help(row.term)
            }
            .width(min: 150, ideal: 220)

            TableColumn("Store", value: \.country) { row in
                Text(row.country.uppercased())
                    .font(.caption.monospaced())
                    .help(row.storefrontName)
            }
            .width(60)

            TableColumn("Demand", value: \.score) { row in
                HStack(spacing: 5) {
                    if let popularity = row.popularity {
                        Text(String(Int(popularity)))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text("Apple").font(.system(size: 9)).foregroundStyle(.blue)
                    } else {
                        // Never shown as a number that could pass for Apple's
                        // index; this is a count of competitor titles, not volume.
                        Text("\(row.titleTargeting)/10")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text("titles").font(.system(size: 9)).foregroundStyle(.purple)
                    }
                }
                .help(row.demandIsMeasured
                      ? "Apple Search Ads popularity for this storefront."
                      : "Search Ads is not connected, so this is a proxy: how many "
                      + "of the top ten apps put this term in their title or "
                      + "subtitle. Developers do not spend title characters on "
                      + "words nobody searches, but it is revealed preference, "
                      + "not measured volume.")
            }
            .width(95)

            TableColumn("Difficulty", value: \.difficulty) { row in
                MetricBar(value: row.difficulty,
                          tint: row.difficulty > 66 ? .red
                              : row.difficulty > 33 ? .orange : .green)
            }
            .width(min: 90, ideal: 105, max: 130)

            TableColumn("You") { row in
                if let rank = row.ourRank {
                    Text("#\(rank)").monospacedDigit()
                        .foregroundStyle(rank <= 10 ? .green : .secondary)
                } else {
                    Text("absent").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .width(70)

            TableColumn("Score", value: \.score) { row in
                Text(String(Int(row.score)))
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(row.score > 30 ? .green : .secondary)
            }
            .width(60)

            TableColumn("") { row in
                Button("Track") {
                    state.trackOpportunity(row)
                }
                .buttonStyle(.borderless)
                .help("Add to tracked keywords for \(row.country.uppercased())")
            }
            .width(60)
        }
    }

    private func run() {
        let countries = Storefront.prospects.filter {
            selectedCountries.contains($0.country)
        }
        let terms = seeds
        state.start { await state.findOpportunities(storefronts: countries, seeds: terms,
                                                    maxCandidates: maxCandidates) }
    }
}
