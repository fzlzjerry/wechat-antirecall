import Foundation

// Decodable mirrors of the CLI's `--json` output (see Sources/WeChatAntiRecall/JSONOutput.swift).
// The GUI is a separate target with no dependency on the CLI target, so it re-declares the
// shapes it consumes. `schemaVersion` lets us detect a CLI/GUI mismatch.

struct CLIAppInfo: Decodable, Equatable {
    let path: String
    let bundleIdentifier: String
    let marketingVersion: String
    let installedBuild: String
    let executable: String
}

struct VersionsReport: Decodable, Equatable {
    let schemaVersion: Int
    let app: CLIAppInfo
    let supported: Bool
    let runtimeTipSupported: Bool
    let installedBuildTargets: [String]
    let features: Features
    let catalog: [CatalogEntry]

    struct Features: Decodable, Equatable {
        let silent: Bool
        let tip: Bool
        let blockUpdate: Bool
        let multiInstance: Bool
        let customTip: Bool
    }

    struct CatalogEntry: Decodable, Equatable, Identifiable {
        let build: String
        let targets: [String]
        let runtimeTipSupported: Bool
        var id: String { build }
    }
}

struct InstallReport: Decodable {
    let schemaVersion: Int
    let command: String
    let dryRun: Bool
    let resigned: Bool
    let app: CLIAppInfo
    let mode: [String]
    let runtime: [RuntimeReport]
    let targets: [TargetReport]

    struct TargetReport: Decodable {
        let identifier: String
        let binary: String
        let entries: [EntryReport]
    }

    struct EntryReport: Decodable {
        let arch: String
        let address: String
        let fileOffset: String
        let state: String   // patched | wouldPatch | alreadyPatched
    }

    struct RuntimeReport: Decodable {
        let arch: String
        let installName: String
        let commandOffset: String
        let state: String   // injected | wouldInject | alreadyInjected
    }

    /// True when every target/runtime entry is either freshly-applicable or already applied
    /// — i.e. a real install would succeed with no byte mismatch.
    var allEntriesClean: Bool {
        let targetStates = targets.flatMap { $0.entries.map(\.state) }
        let runtimeStates = runtime.map(\.state)
        let ok: Set<String> = ["patched", "wouldPatch", "alreadyPatched", "injected", "wouldInject", "alreadyInjected"]
        return (targetStates + runtimeStates).allSatisfy { ok.contains($0) }
    }

    /// True when the primary work is already done (nothing left to patch/inject).
    var alreadyApplied: Bool {
        let targetStates = targets.flatMap { $0.entries.map(\.state) }
        let runtimeStates = runtime.map(\.state)
        let all = targetStates + runtimeStates
        guard !all.isEmpty else { return false }
        return all.allSatisfy { $0 == "alreadyPatched" || $0 == "alreadyInjected" }
    }
}

struct CloneReport: Decodable {
    let schemaVersion: Int
    let command: String
    let dryRun: Bool
    let app: CLIAppInfo
    let keepURLSchemes: Bool
    let clones: [CloneSpec]

    struct CloneSpec: Decodable, Identifiable {
        let index: Int
        let displayName: String
        let bundleIdentifier: String
        let destination: String
        var id: Int { index }
    }
}

// The CLI prints this envelope to stdout (exit 1) when `--json` is set and an error occurs.
struct CLIErrorEnvelope: Decodable, Error, LocalizedError {
    let schemaVersion: Int
    let error: CLIError

    var errorDescription: String? { error.message }
}

struct CLIError: Decodable {
    let kind: String
    let message: String
    var address: String?
    var expected: [String]?
    var actual: String?
    var found: String?
    var supported: [String]?
    var pids: [String]?
    var path: String?
}
