import SwiftUI
import UniformTypeIdentifiers
import ASOCore
import ASCKit

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .appStoreConnect

    enum Section: String, CaseIterable, Identifiable {
        case appStoreConnect = "App Store Connect"
        case searchAds = "Search Ads"
        case revenue = "Revenue"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch section {
                    case .appStoreConnect: ascSection
                    case .searchAds: asaSection
                    case .revenue: revenueSection
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Label("Stored in the macOS Keychain. Never logged or sent anywhere but Apple.",
                      systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
    }

    // MARK: Sections

    private var ascSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "App Store Connect API",
                subtitle: "Users and Access → Integrations → App Store Connect API. "
                        + "The key needs at least App Manager to edit metadata.")

            CredentialField(key: .ascIssuerId, placeholder: "69a6de70-…")
            CredentialField(key: .ascKeyId, placeholder: "2X9R4HXF34")
            PrivateKeyField(key: .ascPrivateKey,
                            hint: "AuthKey_XXXXXXXXXX.p8 — you can only download this once")

            HStack {
                Button("Test Connection") { testASC() }
                    .disabled(!state.hasASCCredentials)
                Spacer()
                StatusPill(ok: state.hasASCCredentials)
            }
        }
    }

    private var asaSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Apple Search Ads API",
                subtitle: "Search Ads → Settings → API. You need the Org ID from the "
                        + "account dropdown, plus a client id, team id and key id.")

            CredentialField(key: .asaOrgId, placeholder: "1234567")
            CredentialField(key: .asaClientId, placeholder: "SEARCHADS.abc…")
            CredentialField(key: .asaTeamId, placeholder: "SEARCHADS.abc…")
            CredentialField(key: .asaKeyId, placeholder: "a1b2c3d4-…")
            PrivateKeyField(key: .asaPrivateKey, hint: "Search Ads private key .p8")

            HStack {
                Spacer()
                StatusPill(ok: state.hasASACredentials)
            }

            Text("Search Ads supplies Apple's real keyword popularity index. Without it, "
               + "keyword difficulty and rank still work, but the popularity column stays "
               + "empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var revenueSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: "Firebase relay",
                subtitle: "RevenueCat has no bulk event export, so a Cloud Function "
                        + "captures their webhooks into Firestore and this app reads it.")

            CredentialField(key: .firebaseProjectId, placeholder: "my-project-id")
            PrivateKeyField(key: .firebaseServiceAccount,
                            hint: "Service account JSON with Cloud Datastore User")

            HStack {
                Spacer()
                StatusPill(ok: state.hasFirebaseCredentials)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Setup").font(.subheadline.weight(.semibold))
                Text("""
                1. cd Firebase && firebase deploy --only functions
                2. firebase functions:secrets:set REVENUECAT_WEBHOOK_SECRET
                3. RevenueCat → Integrations → Webhooks → point at the function URL, \
                using that same secret as the Authorization header
                4. Paste the service account JSON above, then Sync Revenue
                """)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Text("Keyword-level ROAS additionally needs each app to forward AdServices "
               + "attribution to RevenueCat. See Docs/AdServicesAttribution.md.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func testASC() {
        Task {
            do {
                let client = try state.ascClient()
                let apps = try await client.listApps()
                state.report(.success, "Connected. Found \(apps.count) app(s).")
            } catch {
                state.report(.error, "Connection failed: \(error.localizedDescription)")
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StatusPill: View {
    let ok: Bool

    var body: some View {
        Label(ok ? "Configured" : "Incomplete",
              systemImage: ok ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption)
            .foregroundStyle(ok ? .green : .secondary)
    }
}

/// A single-line credential bound straight to the Keychain.
struct CredentialField: View {
    @Environment(AppState.self) private var state
    let key: CredentialKey
    var placeholder: String = ""

    @State private var value = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.displayName).font(.caption.weight(.medium))
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onChange(of: value) { _, newValue in save(newValue) }
        }
        .task {
            guard !loaded else { return }
            // Off the main thread: a Keychain read blocks until the user
            // answers the authorization prompt, which would freeze the sheet.
            let store = state.credentials
            value = await Task.detached { store.optional(key) }.value ?? ""
            loaded = true
        }
    }

    private func save(_ newValue: String) {
        guard loaded else { return }
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try state.credentials.delete(key)
            } else {
                try state.credentials.set(trimmed, for: key)
            }
            Task { await state.refreshCredentialStatus() }
        } catch {
            state.report(.error, "Could not save \(key.displayName): \(error.localizedDescription)")
        }
    }
}

/// A multi-line secret (.p8 or service account JSON) that can be pasted or
/// loaded from a file. The contents are never shown back once stored.
struct PrivateKeyField: View {
    @Environment(AppState.self) private var state
    let key: CredentialKey
    var hint: String = ""

    @State private var isStored = false
    @State private var draft = ""
    @State private var isEditing = false
    @State private var showingImporter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.displayName).font(.caption.weight(.medium))
                Spacer()
                if isStored && !isEditing {
                    Label("Stored", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            if isStored && !isEditing {
                HStack {
                    Text("••••••••••••••••••••")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Replace") { isEditing = true; draft = "" }
                        .buttonStyle(.borderless)
                    Button("Remove", role: .destructive) {
                        try? state.credentials.delete(key)
                        isStored = false
                        Task { await state.refreshCredentialStatus() }
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $draft)
                        .font(.caption.monospaced())
                        .frame(height: 90)
                        .padding(4)
                        .background(.quaternary.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Button("Choose File…") { showingImporter = true }
                        Spacer()
                        if isEditing {
                            Button("Cancel") { isEditing = false; draft = "" }
                        }
                        Button("Save") { save() }
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }

            if !hint.isEmpty {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task {
            let store = state.credentials
            isStored = await Task.detached { store.contains(key) }.value
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.data, .json, .text]) { result in
            switch result {
            case .success(let url):
                // Files chosen through the panel come with a security scope
                // that must be opened explicitly before reading.
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    draft = contents
                } else {
                    state.report(.error, "Could not read \(url.lastPathComponent)")
                }
            case .failure(let error):
                state.report(.error, error.localizedDescription)
            }
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate before storing, so a malformed key is caught here rather than
        // as a confusing 401 on the first API call.
        if key == .ascPrivateKey || key == .asaPrivateKey {
            do {
                _ = try JWTSigner.privateKey(fromPEM: trimmed)
            } catch {
                state.report(.error, "That does not look like a valid .p8 key: "
                                   + error.localizedDescription)
                return
            }
        }

        do {
            try state.credentials.set(trimmed, for: key)
            isStored = true
            isEditing = false
            draft = ""
            Task { await state.refreshCredentialStatus() }
            state.report(.success, "\(key.displayName) saved to Keychain")
        } catch {
            state.report(.error, "Could not save: \(error.localizedDescription)")
        }
    }
}
