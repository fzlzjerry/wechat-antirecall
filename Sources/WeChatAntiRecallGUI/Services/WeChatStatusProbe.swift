import Foundation
import AppKit

struct DirectAppInfo {
    let marketingVersion: String
    let installedBuild: String
    let bundleIdentifier: String
}

enum WeChatStatusProbe {
    static let officialBundleIDs: Set<String> = ["com.tencent.xinWeChat", "com.tencent.xin"]
    static let cloneBundleIDPrefix = "com.tencent.xinWeChat.antirecall.clone"

    private static func isWeChatIdentifier(_ id: String?) -> Bool {
        guard let id else { return false }
        return officialBundleIDs.contains(id) || id.hasPrefix(cloneBundleIDPrefix)
    }

    /// Running WeChat instances (official + tool clones).
    static func runningInstances() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { isWeChatIdentifier($0.bundleIdentifier) }
    }

    static func isRunning() -> Bool {
        !runningInstances().isEmpty
    }

    /// Politely quit, then force-terminate any stragglers after a short grace period.
    static func quitAll() async {
        let running = runningInstances()
        for app in running {
            app.terminate()
        }
        // Give them a moment to quit gracefully.
        for _ in 0..<20 where !runningInstances().isEmpty {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        for app in runningInstances() {
            app.forceTerminate()
        }
    }

    /// Reads the target app's Info.plist directly. Used as a fallback when the CLI refuses
    /// (e.g. `notAWechatApp` because WeChat isn't installed) so the GUI can still say something.
    static func readInfo(appPath: String) -> DirectAppInfo? {
        let plistURL = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let build = plist["CFBundleVersion"] as? String,
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            return nil
        }
        let short = plist["CFBundleShortVersionString"] as? String ?? "—"
        return DirectAppInfo(marketingVersion: short, installedBuild: build, bundleIdentifier: bundleID)
    }

    static func appExists(at appPath: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: appPath, isDirectory: &isDir) && isDir.boolValue
    }
}
