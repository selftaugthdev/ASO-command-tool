import SwiftUI
import ASOCore
import ASOStore

enum Workspace: String, CaseIterable, Identifiable {
    case keywords = "Keywords"
    case metadata = "Metadata"
    case revenue = "Revenue"
    case competitors = "Competitors"
    case alerts = "Alerts"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .keywords: return "magnifyingglass"
        case .metadata: return "doc.text"
        case .revenue: return "chart.line.uptrend.xyaxis"
        case .competitors: return "person.2"
        case .alerts: return "bell"
        }
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var state
    @State private var workspace: Workspace = .keywords
    @State private var showingSettings = false

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let status = state.status {
                    StatusBanner(message: status) { state.status = nil }
                }
                if state.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.busyLabel).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.4))
                }

                if state.selectedApp == nil {
                    EmptyWorkspace(showingSettings: $showingSettings)
                } else {
                    // Workspace switching lives here rather than in the sidebar.
                    // Two independent selections inside one sidebar List fought
                    // each other and drew rows outside the List's bounds.
                    Picker("View", selection: $workspace) {
                        ForEach(Workspace.allCases) { item in
                            Label(item.rawValue, systemImage: item.icon).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()
                    detailContent
                }
            }
            // The app name belongs in the window title, not a .navigation
            // toolbar item, which draws on top of the title rather than beside it.
            .navigationTitle(state.selectedApp?.name ?? "ASO Command Center")
            .navigationSubtitle(state.selectedApp == nil ? "" : workspace.rawValue)
            .toolbar { toolbarContent }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(item: $state.pendingPlan) { plan in
            PushReviewSheet(plan: plan)
        }
        .onChange(of: state.selectedAppId) { _, _ in
            state.reloadKeywords()
            state.reloadRevenue()
            state.snapshot = nil
            state.edits = [:]
        }
        .onChange(of: state.selectedCountry) { _, _ in state.reloadKeywords() }
        .task {
            state.reloadKeywords()
            state.reloadRevenue()
            state.reloadAlerts()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch workspace {
        case .keywords: KeywordsView()
        case .metadata: MetadataView()
        case .revenue: RevenueView()
        case .competitors: CompetitorsView()
        case .alerts: AlertsView()
        }
    }

    private var sidebar: some View {
        @Bindable var state = state

        // A plain VStack, not safeAreaInset: an inset overlays the List's own
        // scroll area instead of reserving space beside it, which let rows
        // render on top of the footer and the window controls.
        return VStack(spacing: 0) {
            List(selection: $state.selectedAppId) {
                Section("Apps") {
                    if state.apps.isEmpty {
                        Text("No apps yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.apps) { app in
                        HStack(spacing: 8) {
                            Image(systemName: "app.fill")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name).lineLimit(1)
                                Text(app.bundleId)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .tag(app.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()

            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 220)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var state = state

        ToolbarItem {
            Picker("Country", selection: $state.selectedCountry) {
                ForEach(Countries.tracked, id: \.code) { country in
                    Text(country.label).tag(country.code)
                }
            }
            .frame(width: 150)
        }
        ToolbarItem {
            Button {
                Task { await state.importApps() }
            } label: {
                Label("Import Apps", systemImage: "square.and.arrow.down")
            }
            .disabled(!state.hasASCCredentials || state.isBusy)
            .help(state.hasASCCredentials
                  ? "Import your apps from App Store Connect"
                  : "Add App Store Connect credentials in Settings first")
        }
    }
}

/// The storefronts tracked by default, matching the shipped locales.
enum Countries {
    static let tracked: [(code: String, label: String)] = [
        ("us", "🇺🇸 United States"),
        ("nl", "🇳🇱 Netherlands"),
        ("be", "🇧🇪 Belgium"),
        ("gb", "🇬🇧 United Kingdom"),
        ("de", "🇩🇪 Germany"),
        ("fr", "🇫🇷 France"),
        ("ca", "🇨🇦 Canada"),
        ("au", "🇦🇺 Australia"),
    ]

    static func label(for code: String) -> String {
        tracked.first { $0.code == code }?.label ?? code.uppercased()
    }
}

struct StatusBanner: View {
    let message: StatusMessage
    var dismiss: () -> Void

    private var color: Color {
        switch message.kind {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var icon: String {
        switch message.kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(message.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(color.opacity(0.12))
    }
}

struct EmptyWorkspace: View {
    @Environment(AppState.self) private var state
    @Binding var showingSettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No app selected")
                .font(.title2)

            if !state.hasASCCredentials {
                Text("Add your App Store Connect API key to get started.")
                    .foregroundStyle(.secondary)
                Button("Open Settings") { showingSettings = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Import your apps from App Store Connect.")
                    .foregroundStyle(.secondary)
                Button("Import Apps") { Task { await state.importApps() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
