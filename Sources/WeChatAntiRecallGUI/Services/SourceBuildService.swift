import Foundation

// Optional advanced path: pull the latest source and compile it locally, then use the
// freshly-built CLI + runtime dylib in place of the bundled ones. Requires the Xcode
// toolchain (which most普通用户 don't have — hence gated behind toolchain detection).
enum SourceBuildService {
    static var srcDir: URL { BundledPaths.srcDir }
    static var builtDir: URL { BundledPaths.builtDir }
    static var repoURL: String { "https://github.com/\(Upstream.owner)/\(Upstream.repo).git" }

    /// True when a Swift toolchain is available (`xcrun --find swift` succeeds).
    static func toolchainAvailable() async -> Bool {
        let result = await run("/usr/bin/xcrun", ["--find", "swift"])
        return result.exitCode == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    struct BuildOutcome {
        let cli: URL
        let dylib: URL
        let patches: URL
        let commit: String
    }

    /// git clone/pull → swift build -c release → copy artifacts into builtDir.
    static func buildFromSource(onLine: @escaping @Sendable (String) -> Void) async throws -> BuildOutcome {
        BundledPaths.ensureWorkingDirectories()
        let fm = FileManager.default
        try? fm.createDirectory(at: builtDir, withIntermediateDirectories: true)

        // 1) Fetch source.
        let gitDir = srcDir.appendingPathComponent(".git")
        if fm.fileExists(atPath: gitDir.path) {
            onLine(">> 更新源码 (git fetch/reset)…")
            try await step("/usr/bin/git", ["-C", srcDir.path, "fetch", "--depth", "1", "origin", "main"], onLine)
            try await step("/usr/bin/git", ["-C", srcDir.path, "reset", "--hard", "origin/main"], onLine)
        } else {
            onLine(">> 克隆源码…")
            try? fm.removeItem(at: srcDir)
            try await step("/usr/bin/git", ["clone", "--depth", "1", repoURL, srcDir.path], onLine)
        }

        let commitResult = await run("/usr/bin/git", ["-C", srcDir.path, "rev-parse", "--short", "HEAD"])
        let commit = commitResult.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // 2) Build release.
        onLine(">> 编译 (swift build -c release)，首次可能需要一两分钟…")
        try await step("/usr/bin/xcrun", ["swift", "build", "-c", "release", "--package-path", srcDir.path], onLine)

        // 3) Locate + copy artifacts.
        let binPathResult = await run("/usr/bin/xcrun", ["swift", "build", "-c", "release", "--package-path", srcDir.path, "--show-bin-path"])
        let binDir = URL(fileURLWithPath: binPathResult.output.trimmingCharacters(in: .whitespacesAndNewlines))

        let cliSrc = binDir.appendingPathComponent("wechat-antirecall")
        let dylibSrc = binDir.appendingPathComponent("libWeChatAntiRecallRuntime.dylib")
        let patchesSrc = srcDir.appendingPathComponent("patches.json")
        guard fm.isReadableFile(atPath: cliSrc.path), fm.isReadableFile(atPath: dylibSrc.path) else {
            throw GUIError("编译完成但找不到产物，请查看日志。")
        }

        let cliDst = builtDir.appendingPathComponent("wechat-antirecall")
        let dylibDst = builtDir.appendingPathComponent("libWeChatAntiRecallRuntime.dylib")
        let patchesDst = builtDir.appendingPathComponent("patches.json")
        for (src, dst) in [(cliSrc, cliDst), (dylibSrc, dylibDst), (patchesSrc, patchesDst)] {
            if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        }

        // 4) Compatibility gate. The GUI drives the CLI via its `--json` interface. If the
        // pulled source predates that feature, the built CLI can't talk to the GUI — refuse
        // and revert rather than shadow the working bundled CLI with a broken one.
        onLine(">> 校验构建产物是否兼容 GUI…")
        let probe = await run(cliDst.path, ["versions", "--json", "--app", "/Applications/WeChat.app", "--config", patchesDst.path])
        guard (probe.output + probe.error).contains("schemaVersion") else {
            try? fm.removeItem(at: builtDir)
            throw GUIError("源码（commit \(commit)）还没有 GUI 需要的 --json 接口，可能改动尚未合入 main。已回退到内置工具，等改动合入后再试。")
        }

        onLine(">> 完成：已切换到源码构建的工具（commit \(commit)）")
        return BuildOutcome(cli: cliDst, dylib: dylibDst, patches: patchesDst, commit: commit)
    }

    /// Removes built artifacts so the bundled CLI is used again.
    static func revertToBundled() throws {
        if FileManager.default.fileExists(atPath: builtDir.path) {
            try FileManager.default.removeItem(at: builtDir)
        }
    }

    // MARK: - Process helpers

    private struct ProcResult { let exitCode: Int32; let output: String; let error: String }

    private static func step(_ exe: String, _ args: [String], _ onLine: @escaping @Sendable (String) -> Void) async throws {
        let r = await run(exe, args, onLine: onLine)
        if r.exitCode != 0 {
            let tail = (r.error + "\n" + r.output).split(separator: "\n").suffix(6).joined(separator: "\n")
            throw GUIError("命令失败（\(exe.split(separator: "/").last ?? "")，退出码 \(r.exitCode)）：\n\(tail)")
        }
    }

    private static func run(_ exe: String, _ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async -> ProcResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ProcResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                let out = Pipe(); let err = Pipe()
                p.standardOutput = out; p.standardError = err
                var outData = Data(); var errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch {
                    cont.resume(returning: ProcResult(exitCode: -1, output: "", error: error.localizedDescription)); return
                }
                p.waitUntilExit(); group.wait()
                let o = String(data: outData, encoding: .utf8) ?? ""
                let e = String(data: errData, encoding: .utf8) ?? ""
                if let onLine {
                    for line in (o + e).split(separator: "\n", omittingEmptySubsequences: true) { onLine(String(line)) }
                }
                cont.resume(returning: ProcResult(exitCode: p.terminationStatus, output: o, error: e))
            }
        }
    }
}
