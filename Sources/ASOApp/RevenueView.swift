import SwiftUI
import Charts
import ASOCore
import ASOStore
import RevenueKit

struct RevenueView: View {
    @Environment(AppState.self) private var state
    @State private var days = 30
    @State private var sortOrder: [KeyPathComparator<KeywordROAS>] = [
        .init(\.spend, order: .reverse)
    ]

    private var rows: [KeywordROAS] { state.roasRows.sorted(using: sortOrder) }

    private var totals: (spend: Double, revenue: Double, installs: Int) {
        state.roasRows.reduce(into: (0.0, 0.0, 0)) { result, row in
            result.0 += row.spend
            result.1 += row.revenue
            result.2 += row.installs
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let diagnostic = state.diagnostic {
                AttributionBanner(diagnostic: diagnostic)
            }
            summary
            Divider()
            table
        }
        .onChange(of: days) { _, newValue in state.reloadRevenue(days: newValue) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $days) {
                Text("7 days").tag(7)
                Text("30 days").tag(30)
                Text("90 days").tag(90)
            }
            .pickerStyle(.segmented)
            .frame(width: 260)

            Spacer()

            Button {
                Task { await state.syncSpend(days: days) }
            } label: {
                Label("Sync Spend", systemImage: "dollarsign.arrow.circlepath")
            }
            .disabled(!state.hasASACredentials || state.isBusy)
            .help(state.hasASACredentials ? "Pull Apple Search Ads spend"
                                          : "Add Search Ads credentials in Settings")

            Button {
                Task { await state.syncRevenue() }
            } label: {
                Label("Sync Revenue", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!state.hasFirebaseCredentials || state.isBusy)
            .help(state.hasFirebaseCredentials ? "Pull RevenueCat events from Firestore"
                                               : "Add the Firebase service account in Settings")
        }
        .padding(12)
        .background(.bar)
    }

    private var summary: some View {
        let values = totals
        let roas = values.spend > 0 ? values.revenue / values.spend : nil

        return HStack(spacing: 14) {
            StatTile(label: "Spend", value: Format.currency(values.spend))
            StatTile(label: "Revenue", value: Format.currency(values.revenue))
            StatTile(label: "ROAS",
                     value: roas.map { String(format: "%.2fx", $0) } ?? "—",
                     tint: roas.map { $0 >= 1 ? .green : .red })
            StatTile(label: "Installs", value: "\(values.installs)")
            StatTile(label: "CPA",
                     value: values.installs > 0
                        ? Format.currency(values.spend / Double(values.installs))
                        : "—")
            Spacer()
        }
        .padding(14)
    }

    private var table: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Keyword", value: \.keyword) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.keyword).fontWeight(.medium)
                    if let campaign = row.campaignName {
                        Text(campaign).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 150, ideal: 220)

            TableColumn("Spend", value: \.spend) { row in
                Text(Format.currency(row.spend)).monospacedDigit()
            }
            .width(90)

            TableColumn("Revenue", value: \.revenue) { row in
                Text(Format.currency(row.revenue)).monospacedDigit()
            }
            .width(90)

            TableColumn("ROAS", value: \.sortROAS) { row in
                if let roas = row.roas {
                    Text(String(format: "%.2fx", roas))
                        .monospacedDigit()
                        .foregroundStyle(roas >= 1 ? .green : .red)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(70)

            TableColumn("Installs", value: \.installs) { row in
                Text("\(row.installs)").monospacedDigit()
            }
            .width(70)

            TableColumn("CPA", value: \.sortCPA) { row in
                Text(row.cpa.map(Format.currency) ?? "—").monospacedDigit()
            }
            .width(80)

            TableColumn("Taps", value: \.taps) { row in
                Text("\(row.taps)").monospacedDigit().foregroundStyle(.secondary)
            }
            .width(70)

            TableColumn("Data", value: \.sortQuality) { row in
                Text(row.quality.label)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(row.quality == .measured ? Color.green.opacity(0.2)
                                                         : Color.orange.opacity(0.2),
                                in: Capsule())
                    .help(row.quality.explanation)
            }
            .width(90)
        }
        .overlay {
            if state.roasRows.isEmpty {
                ContentUnavailableView(
                    "No spend or revenue data",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Sync Apple Search Ads spend and RevenueCat revenue "
                                    + "to see ROAS per keyword."))
            }
        }
    }
}

/// Tells the user, plainly, whether these numbers are measured or modelled.
struct AttributionBanner: View {
    let diagnostic: AttributionDiagnostic

    private var tint: Color {
        if diagnostic.totalEvents == 0 { return .secondary }
        if diagnostic.attributedEvents == 0 { return .orange }
        return diagnostic.coverage > 0.8 ? .green : .yellow
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(diagnostic.status).font(.callout.weight(.medium))
                    if diagnostic.totalEvents > 0 {
                        Text("\(diagnostic.attributedEvents)/\(diagnostic.totalEvents) purchases "
                           + "carry a keyword id")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(diagnostic.advice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
    }
}

struct StatTile: View {
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
        }
        .frame(minWidth: 84, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

enum Format {
    static func currency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        formatter.maximumFractionDigits = value >= 100 ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
