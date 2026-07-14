import Foundation
import CryptoKit

// Repo the GUI pulls updates from and publishes releases to (confirmed with the user).
enum Upstream {
    static let owner = "fzlzjerry"
    static let repo = "wechat-antirecall"
    static var patchesJSON: URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/patches.json")!
    }
    static var patchesChecksum: URL {
        URL(string: "https://raw.githubusercontent.com/\(owner)/\(repo)/main/patches.json.sha256")!
    }
    static var latestRelease: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
    }
    static var releasesPage: URL {
        URL(string: "https://github.com/\(owner)/\(repo)/releases")!
    }
}

struct PatchesFetchResult {
    let count: Int
    let checksumVerified: Bool
    let sha256: String
}

struct ReleaseInfo {
    let tag: String
    let name: String
    let htmlURL: URL
}

enum UpdateService {
    /// Downloads the latest patches.json, verifies integrity, and writes it to the App
    /// Support override (used by the CLI via `--config`).
    ///
    /// Integrity: patches.json drives byte-writes into wechat.dylib, so we verify a SHA-256
    /// sidecar (`patches.json.sha256`) published alongside it — a mismatch is rejected. If no
    /// sidecar exists upstream yet, we fall back to structural validation (HTTPS + the CLI's
    /// `expected`-byte guard remain as defenses) and report `checksumVerified == false`.
    @discardableResult
    static func fetchLatestPatches() async throws -> PatchesFetchResult {
        var request = URLRequest(url: Upstream.patchesJSON)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GUIError("下载失败：无响应。")
        }
        guard http.statusCode == 200 else {
            throw GUIError("下载失败（HTTP \(http.statusCode)）。请检查网络。")
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !array.isEmpty,
              array.allSatisfy({ $0["version"] is String && $0["targets"] is [Any] }) else {
            throw GUIError("下载的补丁数据格式不正确，已忽略。")
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        // Verify against the sidecar checksum if the maintainer published one.
        var verified = false
        if let expected = try? await fetchChecksum() {
            guard expected.lowercased() == digest.lowercased() else {
                throw GUIError("补丁数据校验和不匹配，已拒绝下载（可能被篡改或传输损坏）。")
            }
            verified = true
        }

        BundledPaths.ensureWorkingDirectories()
        try data.write(to: BundledPaths.downloadedPatchesJSON, options: .atomic)
        return PatchesFetchResult(count: array.count, checksumVerified: verified, sha256: digest)
    }

    /// Fetches the expected SHA-256 from `patches.json.sha256` (first whitespace token).
    /// Returns nil if the sidecar doesn't exist (404) so callers can fall back gracefully.
    private static func fetchChecksum() async throws -> String? {
        var request = URLRequest(url: Upstream.patchesChecksum)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).first
        guard let hex = token, hex.count == 64 else { return nil }
        return String(hex)
    }

    /// Removes the downloaded override so the bundled baseline is used again.
    static func revertToBundled() throws {
        let url = BundledPaths.downloadedPatchesJSON
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func checkLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: Upstream.latestRelease)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GUIError("查询发布版本失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）。")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String else {
            throw GUIError("暂无发布版本。")
        }
        let name = obj["name"] as? String ?? tag
        let html = (obj["html_url"] as? String).flatMap(URL.init) ?? Upstream.releasesPage
        return ReleaseInfo(tag: tag, name: name, htmlURL: html)
    }
}
