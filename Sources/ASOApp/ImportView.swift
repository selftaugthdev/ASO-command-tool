import SwiftUI
import UniformTypeIdentifiers
import ASOCore
import KeywordKit

/// Imports a keyword list exported from another ASO tool.
struct ImportView: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var raw = ""
    @State private var result: ImportResult?
    @State private var showingImporter = false
    @State private var researchAfterImport = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import keywords")
                    .font(.title2.weight(.semibold))
                Text("Paste a CSV or a plain list, or choose an exported file. "
                   + "Columns are detected by name, so exports from TryAstro, AppTweak, "
                   + "Appfigures and similar tools all work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $raw)
                    .font(.caption.monospaced())
                    .scrollContentBackground(.hidden)
                    .frame(height: 160)
                    .padding(6)
                    .background(.quaternary.opacity(0.3),
                                in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: raw) { _, newValue in
                        result = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? nil
                            : KeywordImporter.parse(newValue)
                    }

                HStack {
                    Button("Choose File…") { showingImporter = true }
                    Spacer()
                    if let result, !result.isEmpty {
                        Text("\(result.keywords.count) keyword(s)"
                           + (result.skippedRows > 0
                              ? ", \(result.skippedRows) skipped" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)

            if let result, !result.isEmpty {
                Divider()
                preview(result)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Look up rank and difficulty after importing",
                           isOn: $researchAfterImport)
                        .toggleStyle(.checkbox)
                    if researchAfterImport, let count = result?.keywords.count, count > 0 {
                        let seconds = OperationProgress.initialEstimate(
                            itemCount: count,
                            secondsPerItem: KeywordResearcher.secondsPerKeywordLookup)
                        Text("\(count) lookups, \(OperationProgress.describe(seconds)). "
                           + "You can stop part way.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(result?.isEmpty ?? true)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 700, height: 620)
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText,
                                            .plainText, .text, .data]) { outcome in
            switch outcome {
            case .success(let url):
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    raw = contents
                    result = KeywordImporter.parse(contents)
                } else {
                    state.report(.error, "Could not read \(url.lastPathComponent)")
                }
            case .failure(let error):
                state.report(.error, error.localizedDescription)
            }
        }
    }

    private func preview(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Detected columns").font(.subheadline.weight(.semibold))
                ForEach(result.detectedColumns.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                    Text("\(entry.key) → \(entry.value)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 20)

            Table(Array(result.keywords.prefix(200))) {
                TableColumn("Keyword", value: \.term)
                TableColumn("Their volume") { row in
                    Text(row.volume.map { String(format: "%.0f", $0) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                TableColumn("Their difficulty") { row in
                    Text(row.difficulty.map { String(format: "%.0f", $0) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                TableColumn("Their rank") { row in
                    Text(row.rank.map { "#\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 180)
        }
    }

    private func runImport() {
        guard let result else { return }
        let keywords = result.keywords
        dismiss()

        state.start {
            // Import first so the terms and any supplied volume land even if a
            // long research pass is interrupted part way through.
            await state.importKeywords(keywords)
            if researchAfterImport {
                await state.research(terms: keywords.map(\.term))
            }
        }
    }
}
