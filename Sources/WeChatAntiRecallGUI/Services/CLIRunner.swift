import Foundation

struct CLIResult {
    let exitCode: Int32
    let output: String      // stdout for user runs; the tailed logfile for admin runs
    let stderr: String
    let cancelled: Bool     // user dismissed the admin auth dialog
    let logURL: URL?

    var succeeded: Bool { exitCode == 0 && !cancelled }
}

// Runs the bundled `wechat-antirecall` CLI. Unprivileged commands (versions, dry-run,
// tip-phrase) go through `runUser`; privileged ones (install/clone/restore) go through
// `runAdmin`, which prompts once for an admin password via osascript.
enum CLIRunner {
    // MARK: - Unprivileged

    static func runUser(
        _ executableURL: URL,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> CLIResult {
        let raw = await launch(executableURL, arguments)
        for line in Self.lines(from: raw.stdout + raw.stderr) {
            onLine?(line)
        }
        return CLIResult(
            exitCode: raw.exitCode,
            output: raw.stdout,
            stderr: raw.stderr,
            cancelled: false,
            logURL: nil
        )
    }

    // MARK: - Privileged (single admin prompt)

    /// Runs `executableURL arguments` as root. The command's combined output is redirected
    /// to a logfile (tailed live via `onLine`) and its real exit code to `<log>.exit`, so
    /// `do shell script` (which buffers and throws on non-zero) never masks the CLI's result.
    static func runAdmin(
        _ executableURL: URL,
        _ arguments: [String],
        operation: String,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async -> CLIResult {
        BundledPaths.ensureWorkingDirectories()
        let stamp = Self.timestamp()
        let logURL = BundledPaths.logsDir.appendingPathComponent("\(operation)-\(stamp).log")
        let exitURL = BundledPaths.logsDir.appendingPathComponent("\(operation)-\(stamp).log.exit")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        let realCmd = ([executableURL.path] + arguments).map(Self.posixQuote).joined(separator: " ")
        // The compound command always exits 0 (its own status is captured separately), so
        // `do shell script` won't throw and hide the CLI's real exit code / output.
        let shellCmd = "\(realCmd) > \(Self.posixQuote(logURL.path)) 2>&1; printf '%s' \"$?\" > \(Self.posixQuote(exitURL.path))"

        let osaArgs = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            "--", shellCmd,
        ]

        // Tail the logfile for near-live feedback while the (buffered) osascript runs.
        let tail = Task.detached { await Self.tail(logURL, onLine: onLine) }
        let osa = await launch(URL(fileURLWithPath: "/usr/bin/osascript"), osaArgs)
        tail.cancel()

        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let exitText = (try? String(contentsOf: exitURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let cancelled = osa.exitCode != 0 && (
            osa.stderr.contains("-128")
            || osa.stderr.lowercased().contains("user canceled")
            || osa.stderr.lowercased().contains("user cancelled")
        )

        let realExit: Int32
        if cancelled {
            realExit = 130
        } else if let parsed = Int32(exitText) {
            realExit = parsed
        } else {
            // osascript itself failed before the command ran (e.g. auth failure).
            realExit = osa.exitCode == 0 ? -1 : osa.exitCode
        }

        return CLIResult(
            exitCode: realExit,
            output: logText,
            stderr: osa.stderr,
            cancelled: cancelled,
            logURL: logURL
        )
    }

    // MARK: - Helpers

    static func posixQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func lines(from text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private struct RawResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Launches a process, reading stdout/stderr concurrently to avoid pipe-buffer deadlock.
    private static func launch(_ executableURL: URL, _ arguments: [String]) async -> RawResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<RawResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: RawResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                process.waitUntilExit()
                group.wait()
                continuation.resume(returning: RawResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    /// Polls a logfile and emits newly-appended lines until the task is cancelled.
    private static func tail(_ url: URL, onLine: (@Sendable (String) -> Void)?) async {
        guard let onLine else { return }
        var emitted = 0
        while !Task.isCancelled {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                // Keep the last (possibly partial) line pending until more arrives.
                let complete = all.count > 1 ? Array(all.dropLast()) : []
                if complete.count > emitted {
                    for line in complete[emitted..<complete.count] where !line.isEmpty {
                        onLine(line)
                    }
                    emitted = complete.count
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
