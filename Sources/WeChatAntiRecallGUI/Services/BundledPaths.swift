import Foundation

// Resolves the three artifacts the GUI ships (CLI, runtime dylib, baseline patches.json)
// plus the writable working directory. In a packaged .app these live in Contents/Resources;
// during development (`swift run WeChatAntiRecallGUI`) they are resolved from the repo's
// `.build` and root so the app is testable before packaging.
enum BundledPaths {
    static var resourcesURL: URL {
        Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    private static func firstReadable(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    /// Repo-root fallbacks used only during `swift run` development.
    private static var devRepoRoot: URL {
        // .build/<config>/WeChatAntiRecallGUI -> repo root is 3 levels up from the binary dir.
        URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()   // release/
            .deletingLastPathComponent()   // arm64-apple-macosx/ or debug/
            .deletingLastPathComponent()   // .build/
            .deletingLastPathComponent()   // repo root
    }

    private static var devBuildDirs: [URL] {
        let root = devRepoRoot
        return [
            root.appendingPathComponent(".build/release"),
            root.appendingPathComponent(".build/debug"),
            root.appendingPathComponent(".build/arm64-apple-macosx/release"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug"),
        ]
    }

    /// Source-build working dirs (populated only when the user opts into build-from-source).
    static var srcDir: URL { appSupportDir.appendingPathComponent("src", isDirectory: true) }
    static var builtDir: URL { appSupportDir.appendingPathComponent("build", isDirectory: true) }

    static var usingBuiltFromSource: Bool {
        FileManager.default.isReadableFile(atPath: builtDir.appendingPathComponent("wechat-antirecall").path)
    }

    static var cli: URL {
        firstReadable([builtDir.appendingPathComponent("wechat-antirecall"),
                       resourcesURL.appendingPathComponent("wechat-antirecall")]
                      + devBuildDirs.map { $0.appendingPathComponent("wechat-antirecall") })
            ?? resourcesURL.appendingPathComponent("wechat-antirecall")
    }

    static var runtimeDylib: URL {
        firstReadable([builtDir.appendingPathComponent("libWeChatAntiRecallRuntime.dylib"),
                       resourcesURL.appendingPathComponent("libWeChatAntiRecallRuntime.dylib")]
                      + devBuildDirs.map { $0.appendingPathComponent("libWeChatAntiRecallRuntime.dylib") })
            ?? resourcesURL.appendingPathComponent("libWeChatAntiRecallRuntime.dylib")
    }

    static var bundledPatchesJSON: URL {
        firstReadable([resourcesURL.appendingPathComponent("patches.json"),
                       devRepoRoot.appendingPathComponent("patches.json")])
            ?? resourcesURL.appendingPathComponent("patches.json")
    }

    // MARK: - Writable working directory

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("WeChatAntiRecall", isDirectory: true)
    }

    static var downloadedPatchesJSON: URL {
        appSupportDir.appendingPathComponent("patches.json")
    }

    static var catalogMetaJSON: URL {
        appSupportDir.appendingPathComponent("catalog-meta.json")
    }

    static var logsDir: URL {
        appSupportDir.appendingPathComponent("logs", isDirectory: true)
    }

    @discardableResult
    static func ensureWorkingDirectories() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// The patches.json the CLI should use, passed via `--config`.
    ///
    /// A downloaded catalog is not automatically authoritative forever. After an app update,
    /// an older file in Application Support may cover fewer WeChat builds than the new bundled
    /// catalog. Prefer the catalog with the highest numeric build; when both reach the same build,
    /// prefer the one written most recently so an explicit in-app refresh can still replace the
    /// bundled baseline.
    static var effectivePatchesJSON: URL {
        let built = builtDir.appendingPathComponent("patches.json")
        let baseline = newerCatalog(built, bundledPatchesJSON) ?? bundledPatchesJSON
        return newerCatalog(downloadedPatchesJSON, baseline) ?? baseline
    }

    static var usingDownloadedCatalog: Bool {
        effectivePatchesJSON.standardizedFileURL == downloadedPatchesJSON.standardizedFileURL
    }

    /// Minimal sanity: decodes as a non-empty array of objects each having `version` + `targets`.
    static func isValidCatalog(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty else {
            return false
        }
        return array.allSatisfy { $0["version"] is String && $0["targets"] is [Any] }
    }

    /// Returns the newer valid candidate, or nil when neither URL contains a valid catalog.
    /// Internal visibility keeps this deterministic policy directly testable without touching
    /// global Application Support state.
    static func newerCatalog(_ lhs: URL, _ rhs: URL) -> URL? {
        let lhsBuild = latestBuild(in: lhs)
        let rhsBuild = latestBuild(in: rhs)

        switch (lhsBuild, rhsBuild) {
        case (nil, nil):
            return nil
        case (.some, nil):
            return lhs
        case (nil, .some):
            return rhs
        case let (.some(left), .some(right)) where left != right:
            return left > right ? lhs : rhs
        default:
            let leftDate = modificationDate(of: lhs) ?? .distantPast
            let rightDate = modificationDate(of: rhs) ?? .distantPast
            return leftDate >= rightDate ? lhs : rhs
        }
    }

    private static func latestBuild(in url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty,
              array.allSatisfy({ $0["version"] is String && $0["targets"] is [Any] }) else {
            return nil
        }
        return array.compactMap { ($0["version"] as? String).flatMap(Int.init) }.max()
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
