import Foundation

// Machine-readable output for the GUI (and any other automation). Kept in a separate
// file so the `Decodable`-only domain types (VersionConfig/PatchTarget/PatchEntry, which
// have custom hex-parsing `init(from:)`) stay untouched — adding `Encodable` to those
// would force a brittle hand-written `encode(to:)`. Instead we define plain `Encodable`
// DTOs here and map from the domain types at the call sites.
//
// Every top-level report carries `schemaVersion` so a newer build-from-source CLI paired
// with an older GUI (or vice versa) is detectable.

let jsonSchemaVersion = 1

enum JSONOutput {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// Serialize `value` and print it to stdout. Falls back to a minimal error envelope
    /// if encoding somehow fails (should not happen for these fixed DTOs).
    static func emit<T: Encodable>(_ value: T) {
        do {
            let data = try encoder.encode(value)
            if let text = String(data: data, encoding: .utf8) {
                print(text)
            }
        } catch {
            print(#"{"schemaVersion":\#(jsonSchemaVersion),"error":{"kind":"encoding","message":"failed to encode JSON output"}}"#)
        }
    }
}

// MARK: - Shared DTOs

struct AppInfoDTO: Encodable {
    let path: String
    let bundleIdentifier: String
    let marketingVersion: String
    let installedBuild: String
    let executable: String

    init(_ info: AppInfo) {
        path = info.appURL.path
        bundleIdentifier = info.bundleIdentifier
        marketingVersion = info.shortVersion
        installedBuild = info.buildVersion
        executable = info.executableURL.path
    }
}

// MARK: - versions --json

struct VersionsReport: Encodable {
    let schemaVersion: Int
    let app: AppInfoDTO
    let supported: Bool
    let runtimeTipSupported: Bool
    let installedBuildTargets: [String]
    let features: FeaturesDTO
    let catalog: [CatalogEntryDTO]

    struct FeaturesDTO: Encodable {
        let silent: Bool
        let tip: Bool
        let blockUpdate: Bool
        let multiInstance: Bool
        let customTip: Bool
    }

    struct CatalogEntryDTO: Encodable {
        let build: String
        let targets: [String]
        let runtimeTipSupported: Bool
    }

    init(appInfo: AppInfo, configs: [VersionConfig]) {
        schemaVersion = jsonSchemaVersion
        app = AppInfoDTO(appInfo)

        let installedConfig = configs.first { $0.version == appInfo.buildVersion }
        supported = installedConfig != nil
        runtimeTipSupported = RuntimeTipInstaller.supportedBuildVersions.contains(appInfo.buildVersion)

        let installedIdentifiers = installedConfig?.targets.map(\.identifier) ?? []
        installedBuildTargets = installedIdentifiers

        features = FeaturesDTO(
            silent: installedIdentifiers.contains("revoke"),
            tip: installedIdentifiers.contains("revoke-tip"),
            blockUpdate: installedIdentifiers.contains("update"),
            multiInstance: installedIdentifiers.contains("multiInstance"),
            // custom-tip is gated by the compiled crash-interlock list, NOT by the
            // presence of a `runtime-tip` byte-patch target. This is the authoritative fact
            // the GUI cannot derive from patches.json alone.
            customTip: RuntimeTipInstaller.supportedBuildVersions.contains(appInfo.buildVersion)
        )

        catalog = configs.map { config in
            CatalogEntryDTO(
                build: config.version,
                targets: config.targets.map(\.identifier),
                runtimeTipSupported: RuntimeTipInstaller.supportedBuildVersions.contains(config.version)
            )
        }
    }
}

// MARK: - install --json

struct InstallReport: Encodable {
    let schemaVersion: Int
    let command = "install"
    let dryRun: Bool
    let resigned: Bool
    let app: AppInfoDTO
    let mode: [String]
    let runtime: [RuntimeReportDTO]
    let targets: [TargetReportDTO]

    struct TargetReportDTO: Encodable {
        let identifier: String
        let binary: String
        let entries: [EntryReportDTO]
    }

    struct EntryReportDTO: Encodable {
        let arch: String
        let address: String
        let fileOffset: String
        let state: String

        init(_ report: PatchReport) {
            arch = report.arch.rawValue
            address = "0x" + String(report.address, radix: 16)
            fileOffset = "0x" + String(report.fileOffset, radix: 16)
            switch report.status {
            case .patched: state = "patched"
            case .wouldPatch: state = "wouldPatch"
            case .alreadyPatched: state = "alreadyPatched"
            }
        }
    }

    struct RuntimeReportDTO: Encodable {
        let arch: String
        let installName: String
        let commandOffset: String
        let state: String

        init(_ report: DylibInjectionReport) {
            arch = report.arch.rawValue
            installName = report.installName
            commandOffset = "0x" + String(report.commandOffset, radix: 16)
            switch report.status {
            case .injected: state = "injected"
            case .wouldInject: state = "wouldInject"
            case .alreadyInjected: state = "alreadyInjected"
            }
        }
    }
}

// MARK: - clone --json

struct CloneReport: Encodable {
    let schemaVersion: Int
    let command = "clone"
    let dryRun: Bool
    let app: AppInfoDTO
    let keepURLSchemes: Bool
    let clones: [CloneSpecDTO]

    struct CloneSpecDTO: Encodable {
        let index: Int
        let displayName: String
        let bundleIdentifier: String
        let destination: String

        init(_ spec: WeChatCloneSpec) {
            index = spec.index
            displayName = spec.displayName
            bundleIdentifier = spec.bundleIdentifier
            destination = spec.destinationURL.path
        }
    }
}

// MARK: - error envelope

struct ErrorEnvelope: Encodable {
    let schemaVersion: Int
    let error: ErrorDTO

    init(_ error: Error) {
        schemaVersion = jsonSchemaVersion
        self.error = ErrorDTO(error)
    }
}

struct ErrorDTO: Encodable {
    let kind: String
    let message: String
    // Structured extras for the cases a GUI benefits from parsing.
    var address: String?
    var expected: [String]?
    var actual: String?
    var found: String?
    var supported: [String]?
    var pids: [String]?
    var path: String?

    init(_ error: Error) {
        message = error.localizedDescription
        guard let toolError = error as? ToolError else {
            kind = "unknown"
            return
        }
        switch toolError {
        case .usage:
            kind = "usage"
        case .unsupportedVersion(let found, let supported):
            kind = "unsupportedVersion"
            self.found = found
            self.supported = supported
        case .invalidConfig:
            kind = "invalidConfig"
        case .invalidHex:
            kind = "invalidHex"
        case .appInfoMissing:
            kind = "appInfoMissing"
        case .notAWechatApp(let path):
            kind = "notAWechatApp"
            self.path = path
        case .unsupportedMachO(let path):
            kind = "unsupportedMachO"
            self.path = path
        case .addressNotMapped(let address, let file):
            kind = "addressNotMapped"
            self.address = "0x" + String(address, radix: 16)
            self.path = file
        case .bytesMismatch(let address, let expected, let actual):
            kind = "bytesMismatch"
            self.address = "0x" + String(address, radix: 16)
            self.expected = expected.map(\.hexString)
            self.actual = actual.hexString
        case .noMatchingSlice(let path):
            kind = "noMatchingSlice"
            self.path = path
        case .commandFailed:
            kind = "commandFailed"
        case .permissionDenied(let path, _):
            kind = "permissionDenied"
            self.path = path
        case .fileOperationFailed(_, let path, _):
            kind = "fileOperationFailed"
            self.path = path
        case .appIsRunning(let path, let pids):
            kind = "appIsRunning"
            self.path = path
            self.pids = pids
        }
    }
}
