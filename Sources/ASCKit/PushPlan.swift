import Foundation
import ASOCore

/// A single write against one localization object.
///
/// Fields are grouped per locale per container so one locale costs at most two
/// requests instead of one per field.
public struct PushOperation: Identifiable, Sendable {
    public var id: String { "\(locale).\(container == .appInfo ? "info" : "version")" }
    public var locale: String
    public var container: MetadataField.Container
    /// nil when the localization does not exist yet and must be created.
    public var localizationId: String?
    public var values: [MetadataField: String]

    public var isCreate: Bool { localizationId == nil }

    public var summary: String {
        let fields = values.keys.map(\.displayName).sorted().joined(separator: ", ")
        return "\(locale): \(isCreate ? "create" : "update") \(fields)"
    }
}

/// A reviewed set of changes, ready to send once the user confirms.
///
/// `isConfirmed` starts false and can only be set by `confirmed()`, so an
/// accidental call to `ASCClient.push` on a freshly built plan is rejected
/// rather than silently writing to a live listing.
public struct PushPlan: Sendable, Identifiable {
    /// Changes whenever the plan's contents change, so a presented review sheet
    /// re-renders rather than showing a stale diff.
    public var id: String {
        "\(appId)-\(operations.map(\.id).joined(separator: ","))-\(diffs.count)"
    }
    public var appId: String
    public var appName: String
    public var appInfoId: String?
    public var editableVersionId: String?
    public var editableVersionString: String?
    public var operations: [PushOperation]
    public var diffs: [MetadataDiff]
    public private(set) var isConfirmed: Bool = false

    public init(appId: String,
                appName: String,
                appInfoId: String?,
                editableVersionId: String?,
                editableVersionString: String?,
                operations: [PushOperation],
                diffs: [MetadataDiff]) {
        self.appId = appId
        self.appName = appName
        self.appInfoId = appInfoId
        self.editableVersionId = editableVersionId
        self.editableVersionString = editableVersionString
        self.operations = operations
        self.diffs = diffs
    }

    public var isEmpty: Bool { operations.isEmpty }

    /// Reasons this plan must not be sent. Non-empty means the confirm button
    /// stays disabled.
    public var blockers: [String] {
        var blockers: [String] = []
        for diff in diffs {
            if let violation = diff.limitViolation {
                blockers.append("\(diff.locale): \(violation)")
            }
        }
        let needsVersion = operations.contains { $0.container == .version }
        if needsVersion && editableVersionId == nil {
            blockers.append(
                "No editable version. Description, keywords and promotional text can only "
              + "be changed on a version in Prepare for Submission. Create one in App Store "
              + "Connect, then pull again.")
        }
        return blockers
    }

    public var canPush: Bool { !isEmpty && blockers.isEmpty }

    /// The only way to mark a plan sendable.
    public func confirmed() -> PushPlan {
        var copy = self
        copy.isConfirmed = true
        return copy
    }

    /// Human-readable review text, also used for the MCP approval flow later.
    public var reviewText: String {
        var lines = ["Push to \(appName) (\(appId))"]
        if let version = editableVersionString {
            lines.append("Target version: \(version)")
        }
        lines.append("")
        for diff in diffs where diff.isChanged {
            lines.append("[\(diff.locale)] \(diff.field.displayName)")
            lines.append("  - \(diff.remote.isEmpty ? "(empty)" : diff.remote)")
            lines.append("  + \(diff.local.isEmpty ? "(empty)" : diff.local)")
        }
        if !blockers.isEmpty {
            lines.append("")
            lines.append("BLOCKED:")
            lines.append(contentsOf: blockers.map { "  ! \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

public struct PushOutcome: Identifiable, Sendable {
    public var id: String { operation.id }
    public var operation: PushOperation
    public var error: (any Error)?
    public var succeeded: Bool { error == nil }
}

public struct PushReport: Sendable {
    public var appId: String
    public var outcomes: [PushOutcome]

    public var succeeded: [PushOutcome] { outcomes.filter(\.succeeded) }
    public var failed: [PushOutcome] { outcomes.filter { !$0.succeeded } }
    public var allSucceeded: Bool { failed.isEmpty }

    public var summary: String {
        if allSucceeded {
            return "Pushed \(succeeded.count) localization update(s) successfully."
        }
        return "\(succeeded.count) succeeded, \(failed.count) failed: "
            + failed.map { "\($0.operation.locale) (\($0.error?.localizedDescription ?? "unknown"))" }
                .joined(separator: "; ")
    }
}

/// Builds diffs and push plans by comparing local edits against a fetched snapshot.
public enum MetadataDiffer {

    /// Computes every field-level difference between the snapshot and local edits.
    public static func diff(remote: AppMetadataSnapshot,
                            local: [String: LocalizedMetadata]) -> [MetadataDiff] {
        var diffs: [MetadataDiff] = []
        let locales = Set(remote.metadata.keys).union(local.keys).sorted()

        for locale in locales {
            let remoteEntry = remote.metadata[locale]
            guard let localEntry = local[locale] else { continue }
            for field in MetadataField.allCases {
                let remoteValue = remoteEntry?[field] ?? ""
                let localValue = localEntry[field]
                // Only surface fields the user actually edited. An absent key
                // means "not touched", which is different from "cleared".
                guard localEntry.values[field] != nil else { continue }
                if remoteValue != localValue {
                    diffs.append(MetadataDiff(locale: locale, field: field,
                                              remote: remoteValue, local: localValue))
                }
            }
        }
        return diffs
    }

    /// Groups diffs into the minimum set of API writes.
    public static func plan(remote: AppMetadataSnapshot,
                            local: [String: LocalizedMetadata]) -> PushPlan {
        let diffs = diff(remote: remote, local: local)
        var grouped: [String: [MetadataField.Container: [MetadataField: String]]] = [:]

        for diff in diffs where diff.isChanged {
            grouped[diff.locale, default: [:]][diff.field.container, default: [:]][diff.field] = diff.local
        }

        var operations: [PushOperation] = []
        for (locale, containers) in grouped {
            let remoteEntry = remote.metadata[locale]
            for (container, values) in containers {
                let localizationId = container == .appInfo
                    ? remoteEntry?.appInfoLocalizationId
                    : remoteEntry?.versionLocalizationId
                operations.append(PushOperation(locale: locale,
                                                container: container,
                                                localizationId: localizationId,
                                                values: values))
            }
        }
        operations.sort { $0.id < $1.id }

        return PushPlan(appId: remote.app.id,
                        appName: remote.app.name,
                        appInfoId: remote.appInfoId,
                        editableVersionId: remote.editableVersion?.id,
                        editableVersionString: remote.editableVersion?.versionString,
                        operations: operations,
                        diffs: diffs)
    }
}
