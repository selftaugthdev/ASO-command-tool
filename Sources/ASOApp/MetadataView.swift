import SwiftUI
import ASOCore
import ASCKit

struct MetadataView: View {
    @Environment(AppState.self) private var state
    @State private var locale: String = "en-US"

    private var locales: [String] {
        state.snapshot?.locales ?? []
    }

    var body: some View {
        Group {
            if state.snapshot == nil {
                ContentUnavailableView {
                    Label("Metadata not loaded", systemImage: "doc.text")
                } description: {
                    Text("Pull the live metadata from App Store Connect to edit it.")
                } actions: {
                    Button("Pull Metadata") { Task { await state.pullMetadata() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.hasASCCredentials || state.isBusy)
                }
            } else {
                editor
            }
        }
        .onChange(of: state.snapshot?.app.id) { _, _ in
            locale = state.snapshot?.app.primaryLocale ?? locales.first ?? "en-US"
        }
    }

    private var editor: some View {
        @Bindable var state = state

        return VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(MetadataField.allCases, id: \.self) { field in
                        MetadataFieldEditor(
                            field: field,
                            locale: locale,
                            remote: state.snapshot?.metadata[locale]?[field] ?? "",
                            value: binding(for: field),
                            isWritable: isWritable(field))
                    }
                }
                .padding(18)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Locale", selection: $locale) {
                ForEach(locales, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 180)

            if let version = state.snapshot?.editableVersion {
                Label("Editing \(version.versionString)", systemImage: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("No editable version", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Keywords and description need a version in Prepare for Submission")
            }

            Spacer()

            if changeCount > 0 {
                Text("\(changeCount) change\(changeCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await state.pullMetadata() }
            } label: {
                Label("Pull", systemImage: "arrow.down.circle")
            }
            .disabled(state.isBusy)

            Button {
                state.preparePush()
            } label: {
                Label("Review & Push", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(changeCount == 0 || state.isBusy)
            .help("Shows exactly what will change before anything is sent to Apple")
        }
        .padding(12)
        .background(.bar)
    }

    private var changeCount: Int {
        guard let snapshot = state.snapshot else { return 0 }
        return MetadataDiffer.diff(remote: snapshot, local: state.edits)
            .filter(\.isChanged).count
    }

    /// Version-scoped fields cannot be edited without an editable version.
    private func isWritable(_ field: MetadataField) -> Bool {
        field.container == .appInfo || state.snapshot?.editableVersion != nil
    }

    private func binding(for field: MetadataField) -> Binding<String> {
        Binding(
            get: { state.edits[locale]?[field] ?? "" },
            set: { newValue in
                var entry = state.edits[locale]
                    ?? LocalizedMetadata(locale: locale)
                entry[field] = newValue
                state.edits[locale] = entry
            })
    }
}

struct MetadataFieldEditor: View {
    let field: MetadataField
    let locale: String
    let remote: String
    @Binding var value: String
    let isWritable: Bool

    private var isChanged: Bool { value != remote }

    private var overLimit: Bool {
        guard let limit = field.characterLimit else { return false }
        return value.count > limit
    }

    private var isMultiline: Bool {
        field == .description || field == .whatsNew || field == .promotionalText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(field.displayName)
                    .font(.subheadline.weight(.semibold))

                if isChanged {
                    Text("changed")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                if !isWritable {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Needs a version in Prepare for Submission")
                }

                Spacer()

                if let limit = field.characterLimit {
                    Text("\(value.count)/\(limit)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(overLimit ? .red : .secondary)
                }
            }

            if isMultiline {
                // Fixed height, never minHeight: inside a ScrollView the editor
                // is offered unbounded height, so a minHeight lets a 4000-character
                // description grow to its full length and shove the whole page
                // off screen. A fixed frame makes it scroll internally instead.
                TextEditor(text: $value)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: field == .description ? 260 : 80)
                    .padding(6)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(borderColor, lineWidth: 1)
                    }
                    .disabled(!isWritable)
            } else {
                TextField(field.displayName, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isWritable)
            }

            if field == .keywords && !value.isEmpty {
                KeywordFieldHint(value: value)
            }

            if isChanged && !remote.isEmpty {
                DisclosureGroup("Live value") {
                    Text(remote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
    }

    private var borderColor: Color {
        if overLimit { return .red }
        if isChanged { return .accentColor.opacity(0.6) }
        return .clear
    }
}

/// Feedback specific to the 100-character keywords field.
struct KeywordFieldHint: View {
    let value: String

    private var terms: [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var duplicates: [String] {
        Dictionary(grouping: terms.map { $0.lowercased() }, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys.sorted()
    }

    /// Spaces after commas are billed against the 100-character budget and
    /// Apple ignores them, so they are pure waste.
    private var wastedSpaces: Int {
        value.filter { $0 == " " }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(terms.count) term\(terms.count == 1 ? "" : "s")")
            if !duplicates.isEmpty {
                Label("duplicate: \(duplicates.joined(separator: ", "))",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if wastedSpaces > 0 {
                Label("\(wastedSpaces) space\(wastedSpaces == 1 ? "" : "s") wasted",
                      systemImage: "scissors")
                    .foregroundStyle(.orange)
                    .help("Apple ignores spaces in the keywords field, but they still "
                        + "count toward the 100-character limit")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// The confirm gate. Nothing reaches App Store Connect until the user presses
/// Push here, and the button stays disabled while the plan has blockers.
struct PushReviewSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let plan: PushPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review changes")
                    .font(.title2.weight(.semibold))
                Text("\(plan.appName) · \(plan.operations.count) request(s) to App Store Connect")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let version = plan.editableVersionString {
                    Text("Target version \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(plan.diffs.filter(\.isChanged)) { diff in
                        DiffRow(diff: diff)
                    }
                }
                .padding(20)
            }
            .frame(minHeight: 240)

            if !plan.blockers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Cannot push", systemImage: "exclamationmark.octagon.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    ForEach(plan.blockers, id: \.self) { blocker in
                        Text("• \(blocker)")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.red.opacity(0.08))
            }

            Divider()

            HStack {
                Label("Writes directly to your live listing",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Cancel") {
                    state.pendingPlan = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Push to App Store Connect") {
                    Task { await state.confirmPush() }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!plan.canPush)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 560)
    }
}

struct DiffRow: View {
    let diff: MetadataDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(diff.locale)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Text(diff.field.displayName)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let violation = diff.limitViolation {
                    Label(violation, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Text("−").foregroundStyle(.red).font(.body.monospaced())
                Text(diff.remote.isEmpty ? "(empty)" : diff.remote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .strikethrough(color: .red.opacity(0.4))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 8) {
                Text("+").foregroundStyle(.green).font(.body.monospaced())
                Text(diff.local.isEmpty ? "(empty)" : diff.local)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}
