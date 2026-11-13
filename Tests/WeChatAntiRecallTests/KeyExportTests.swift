import XCTest
import Foundation
import WeChatAntiRecallRuntime
@testable import WeChatAntiRecall

final class KeyExportTests: XCTestCase {
    private var folders: [URL] = []

    override func setUp() {
        super.setUp()
        wechat_antirecall_key_export_reset_throttle_for_test()
    }

    override func tearDown() {
        for folder in folders {
            try? FileManager.default.removeItem(at: folder)
        }
        folders = []
        super.tearDown()
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("key-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        folders.append(home)
        return home
    }

    private var fixtureDomain: String { "com.example.wechat" }

    /// Container directory the runtime writes to and the stores read from, inside `home`.
    private func makeContainer(home: URL) throws -> URL {
        let directory = home
            .appendingPathComponent("Library/Containers/\(fixtureDomain)/Data/Library/Application Support/WeChatAntiRecall", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pattern(key: String, salt: String) -> String {
        "x'\(key)\(salt)'"
    }

    private func scanBuffer(_ bytes: [UInt8]) throws -> [String: Any] {
        let pointer = try bytes.withUnsafeBufferPointer { buffer in
            try XCTUnwrap(wechat_antirecall_key_export_scan_buffer_for_test(buffer.baseAddress, buffer.count))
        }
        defer { wechat_antirecall_free(pointer) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any])
    }

    private func scanText(_ text: String) throws -> [String: Any] {
        try scanBuffer(Array(text.utf8))
    }

    private func keys(from report: [String: Any]) throws -> [[String: String]] {
        try XCTUnwrap(report["keys"] as? [[String: String]])
    }

    // MARK: - Runtime marker

    func testRuntimeVersionMarker() {
        XCTAssertEqual(String(cString: wechat_antirecall_key_export_runtime_version()), "WeChatAntiRecallKeyExport:1")
    }

    // MARK: - Pattern matching

    func testScanBufferFindsBasicPattern() throws {
        let report = try scanText(pattern(key: String(repeating: "a", count: 64), salt: String(repeating: "b", count: 32)))
        let found = try keys(from: report)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0]["key"], String(repeating: "a", count: 64))
        XCTAssertEqual(found[0]["salt"], String(repeating: "b", count: 32))
    }

    func testScanBufferLowercasesHex() throws {
        let report = try scanText(pattern(key: String(repeating: "A", count: 64), salt: String(repeating: "B", count: 32)))
        XCTAssertEqual(try keys(from: report)[0]["key"], String(repeating: "a", count: 64))
        XCTAssertEqual(try keys(from: report)[0]["salt"], String(repeating: "b", count: 32))
    }

    func testScanBufferRejectsNonHexKey() throws {
        var malformed = pattern(key: String(repeating: "a", count: 63) + "g", salt: String(repeating: "b", count: 32))
        XCTAssertTrue(try keys(from: scanText(malformed)).isEmpty)
        malformed = pattern(key: String(repeating: "a", count: 64), salt: String(repeating: "z", count: 32))
        XCTAssertTrue(try keys(from: scanText(malformed)).isEmpty)
    }

    func testScanBufferRejectsWrongClosingQuote() throws {
        let malformed = "x'" + String(repeating: "a", count: 96) + "\""
        XCTAssertTrue(try keys(from: scanText(malformed)).isEmpty)
    }

    func testScanBufferRejectsTooShortBuffer() throws {
        XCTAssertTrue(try keys(from: scanText("x'abc")).isEmpty)
        XCTAssertTrue(try keys(from: scanText("")).isEmpty)
    }

    func testScanBufferDeduplicatesAndKeepsDistinct() throws {
        let first = pattern(key: String(repeating: "1", count: 64), salt: String(repeating: "2", count: 32))
        let second = pattern(key: String(repeating: "3", count: 64), salt: String(repeating: "4", count: 32))
        let found = try keys(from: scanText(first + first + second))
        XCTAssertEqual(found.count, 2)
        let keyValues = try found.map { try XCTUnwrap($0["key"]) }
        XCTAssertEqual(Set(keyValues), Set([String(repeating: "1", count: 64), String(repeating: "3", count: 64)]))
    }

    func testScanBufferFindsPatternEmbeddedInGarbage() throws {
        let blob = pattern(key: String(repeating: "e", count: 64), salt: String(repeating: "f", count: 32))
        let found = try keys(from: scanText(String(repeating: "周", count: 20) + blob + String(repeating: "\0", count: 8)))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0]["key"], String(repeating: "e", count: 64))
    }

    func testScanBufferFindsPatternAtChunkBoundaryTail() throws {
        // A blob starting just before the 2 MiB chunk size exercises long inputs.
        let prefix = Data(repeating: 0x41, count: 2 * 1024 * 1024 - 40)
        let blob = Data(pattern(key: String(repeating: "c", count: 64), salt: String(repeating: "d", count: 32)).utf8)
        var combined = prefix
        combined.append(blob)
        let report = try scanBuffer(Array(combined))
        XCTAssertEqual(try keys(from: report).count, 1)
    }

    // MARK: - Self scan (real mach_vm_region/mach_vm_read path)

    func testScanSelfFindsHeapPattern() throws {
        // Keep a live pattern on this process's heap; the real self-scan must see it.
        let key = "0123456789abcdef" + String(repeating: "ab", count: 24)
        let salt = String(repeating: "9", count: 32)
        let blob = Array(pattern(key: key, salt: salt).utf8)
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: blob.count)
        storage.initialize(from: blob, count: blob.count)
        defer {
            storage.deinitialize(count: blob.count)
            storage.deallocate()
        }

        let pointer = try XCTUnwrap(wechat_antirecall_key_export_scan_self_for_test())
        defer { wechat_antirecall_free(pointer) }
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any])
        let found = try keys(from: report)
        XCTAssertTrue(found.contains { $0["key"] == key && $0["salt"] == salt },
                      "self scan must find the pattern planted on this heap")
    }

    // MARK: - File write

    func testWriteKeysFileIsAtomicAndPrivate() throws {
        let directory = try makeContainer(home: try makeHome())
        XCTAssertEqual(wechat_antirecall_key_export_write_for_test(directory.path, "{\"v\":1}"), 1)
        let written = directory.appendingPathComponent("keys.json")
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "{\"v\":1}")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: written.path)[.posixPermissions] as? Int, 0o600)

        XCTAssertEqual(wechat_antirecall_key_export_write_for_test(directory.path, "{\"v\":2}"), 1)
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "{\"v\":2}")
        // The temporary file must not linger after either write.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["keys.json"])
    }

    // MARK: - Empty scan must not count as a write

    func testScanAndWriteSkipsEmptyScanAndWritesNonEmpty() throws {
        let home = try makeHome()
        let directory = try makeContainer(home: home)
        // First pass: this process's heap holds no key pattern, so no file may appear.
        wechat_antirecall_key_export_reset_throttle_for_test()
        XCTAssertEqual(wechat_antirecall_key_export_scan_and_write_for_test(directory.path), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("keys.json").path))

        // Plant a live pattern, then the same call must write a non-empty snapshot.
        let key = "fedcba9876543210" + String(repeating: "cd", count: 24)
        let salt = String(repeating: "7", count: 32)
        let blob = Array(pattern(key: key, salt: salt).utf8)
        let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: blob.count)
        storage.initialize(from: blob, count: blob.count)
        defer {
            storage.deinitialize(count: blob.count)
            storage.deallocate()
        }
        wechat_antirecall_key_export_reset_throttle_for_test()
        XCTAssertEqual(wechat_antirecall_key_export_scan_and_write_for_test(directory.path), 1)
        let written = try String(contentsOf: directory.appendingPathComponent("keys.json"), encoding: .utf8)
        XCTAssertTrue(written.contains(key), "snapshot must contain the planted key")
    }

    // MARK: - Preference gate

    func testEnabledForPlistRequiresStrictBoolean() throws {
        let home = try makeHome()
        let plist = home.appendingPathComponent("prefs.plist")
        let write: ([String: Any]) throws -> Void = { dictionary in
            try (dictionary as NSDictionary).write(to: plist, atomically: true)
        }
        try write(["WeChatAntiRecall_KeyExport": ["enabled": true]])
        XCTAssertEqual(wechat_antirecall_key_export_enabled_for_plist(plist.path), 1)
        try write(["WeChatAntiRecall_KeyExport": ["enabled": "yes"]])
        XCTAssertEqual(wechat_antirecall_key_export_enabled_for_plist(plist.path), 0)
        try write(["WeChatAntiRecall_KeyExport": "on"])
        XCTAssertEqual(wechat_antirecall_key_export_enabled_for_plist(plist.path), 0)
        try write([:])
        XCTAssertEqual(wechat_antirecall_key_export_enabled_for_plist(plist.path), 0)
        XCTAssertEqual(wechat_antirecall_key_export_enabled_for_plist("/nonexistent/key-export.plist"), 0)
    }

    // MARK: - CLI file store

    func testFileStoreDecodesSnapshot() throws {
        let home = try makeHome()
        let directory = try makeContainer(home: home)
        let key = String(repeating: "ab", count: 32)
        let payload = """
        {"dumpedAt":1731000000,"keys":[{"key":"\(key)","salt":"\(String(repeating: "cd", count: 16))"}],"v":1}
        """
        try payload.data(using: .utf8)?.write(to: directory.appendingPathComponent("keys.json"))
        let store = KeyExportFileStore(homeDirectory: home, domain: fixtureDomain)
        let file = try XCTUnwrap(try store.load())
        XCTAssertEqual(file.v, 1)
        XCTAssertEqual(file.dumpedAt, 1_731_000_000)
        XCTAssertEqual(file.keys.first?.key, key)
    }

    func testFileStoreMissingFileYieldsNil() throws {
        let home = try makeHome()
        let store = KeyExportFileStore(homeDirectory: home, domain: fixtureDomain)
        XCTAssertNil(try store.load())
    }

    func testFileStoreFallsBackToUnsandboxedHome() throws {
        // A WeChat whose app-sandbox entitlement was stripped writes under the real
        // home; the store must still find the snapshot when the container is empty.
        let home = try makeHome()
        let unsandboxed = home
            .appendingPathComponent("Library/Application Support/WeChatAntiRecall", isDirectory: true)
        try FileManager.default.createDirectory(at: unsandboxed, withIntermediateDirectories: true)
        let payload = """
        {"dumpedAt":1731000001,"keys":[{"key":"\(String(repeating: "ee", count: 32))","salt":"\(String(repeating: "11", count: 16))"}],"v":1}
        """
        try payload.data(using: .utf8)?
            .write(to: unsandboxed.appendingPathComponent("keys.json"))
        let store = KeyExportFileStore(homeDirectory: home, domain: fixtureDomain)
        let file = try XCTUnwrap(try store.load())
        XCTAssertEqual(file.dumpedAt, 1_731_000_001)
        XCTAssertEqual(store.candidateURLs.count, 2)
    }

    func testFileStoreRejectsUnsupportedVersionAndCorruption() throws {
        let home = try makeHome()
        let directory = try makeContainer(home: home)
        let url = directory.appendingPathComponent("keys.json")
        let store = KeyExportFileStore(homeDirectory: home, domain: fixtureDomain)
        try "{\"dumpedAt\":1,\"keys\":[],\"v\":2}".data(using: .utf8)?.write(to: url)
        XCTAssertThrowsError(try store.load())
        try "not json".data(using: .utf8)?.write(to: url)
        XCTAssertThrowsError(try store.load())
    }

    // MARK: - Database matcher

    private func makeDatabaseRoot(home: URL) throws -> URL {
        let root = home
            .appendingPathComponent("Library/Containers/\(fixtureDomain)/Data/Documents/xwechat_files", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("wxid_fixture/db", isDirectory: true),
            withIntermediateDirectories: true)
        return root
    }

    private func saltBytes(_ hex: String) -> Data {
        var data = Data()
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            data.append(UInt8(String(high) + String(low), radix: 16) ?? 0)
        }
        return data
    }

    func testMatcherPairsKeysWithDatabasesBySalt() throws {
        let home = try makeHome()
        let root = try makeDatabaseRoot(home: home)
        let encryptedSalt = String(repeating: "ab", count: 16)
        let otherSalt = String(repeating: "cd", count: 16)
        var encrypted = saltBytes(encryptedSalt)
        encrypted.append(Data(repeating: 0x00, count: 64))
        try encrypted.write(to: root.appendingPathComponent("wxid_fixture/db/message_0.db"))
        var other = saltBytes(otherSalt)
        other.append(Data(repeating: 0x00, count: 64))
        try other.write(to: root.appendingPathComponent("wxid_fixture/db/session.db"))
        // A plaintext database and a truncated file must both be skipped.
        try Data("SQLite format 3\0rest".utf8).write(to: root.appendingPathComponent("wxid_fixture/db/plain.db"))
        try Data([0x01, 0x02]).write(to: root.appendingPathComponent("wxid_fixture/db/short.db"))

        let matcher = KeyExportDatabaseMatcher(homeDirectory: home, bundleIdentifier: fixtureDomain)
        let keyHex = String(repeating: "12", count: 32)
        let staleKeyHex = String(repeating: "34", count: 32)
        let result = try matcher.match(keys: [
            KeyExportKeyEntry(key: keyHex, salt: encryptedSalt),
            KeyExportKeyEntry(key: staleKeyHex, salt: String(repeating: "ef", count: 16)),
        ])
        XCTAssertEqual(result.matches, ["wxid_fixture/db/message_0.db": keyHex])
        XCTAssertEqual(result.unmatchedKeySalts, [String(repeating: "ef", count: 16)])
        // session.db is encrypted but no exported key opens it.
        XCTAssertEqual(result.encryptedDatabasesWithoutKey, 1)
        XCTAssertEqual(try KeyExportDatabaseMatcher.readSalt(at: root.appendingPathComponent("wxid_fixture/db/plain.db")), nil)
        XCTAssertEqual(try KeyExportDatabaseMatcher.readSalt(at: root.appendingPathComponent("wxid_fixture/db/short.db")), nil)
        XCTAssertEqual(try KeyExportDatabaseMatcher.readSalt(at: root.appendingPathComponent("wxid_fixture/db/message_0.db")), encryptedSalt)
    }

    func testMatcherMergesContainerAndUnsandboxedRoots() throws {
        let home = try makeHome()
        // One encrypted database under the container root, another under ~/Documents
        // (the unsandboxed WeChat layout); both must pair with their keys.
        let containerSalt = String(repeating: "ab", count: 16)
        let unsandboxedSalt = String(repeating: "99", count: 16)
        let containerDirectory = home
            .appendingPathComponent("Library/Containers/\(fixtureDomain)/Data/Documents/xwechat_files/wxid_a/db", isDirectory: true)
        let unsandboxedDirectory = home
            .appendingPathComponent("Documents/xwechat_files/wxid_b/db", isDirectory: true)
        for (directory, salt) in [(containerDirectory, containerSalt), (unsandboxedDirectory, unsandboxedSalt)] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var contents = saltBytes(salt)
            contents.append(Data(repeating: 0x00, count: 64))
            try contents.write(to: directory.appendingPathComponent("message_0.db"))
        }

        let matcher = KeyExportDatabaseMatcher(homeDirectory: home, bundleIdentifier: fixtureDomain)
        let result = try matcher.match(keys: [
            KeyExportKeyEntry(key: String(repeating: "12", count: 32), salt: containerSalt),
            KeyExportKeyEntry(key: String(repeating: "34", count: 32), salt: unsandboxedSalt),
        ])
        XCTAssertEqual(result.matches, [
            "wxid_a/db/message_0.db": String(repeating: "12", count: 32),
            "wxid_b/db/message_0.db": String(repeating: "34", count: 32),
        ])
        XCTAssertTrue(result.unmatchedKeySalts.isEmpty)
        XCTAssertEqual(result.encryptedDatabasesWithoutKey, 0)
    }

    // MARK: - Options

    func testOptionsParsing() throws {
        XCTAssertEqual(try KeyExportOptions(["get"]).action, .get)
        XCTAssertEqual(try KeyExportOptions(["export", "--output", "/tmp/keys.json"]).outputPath, "/tmp/keys.json")
        XCTAssertThrowsError(try KeyExportOptions(["get", "--output", "/tmp/keys.json"]))
        XCTAssertThrowsError(try KeyExportOptions([]))
        XCTAssertThrowsError(try KeyExportOptions(["bogus"]))
        XCTAssertThrowsError(try KeyExportOptions(["get", "--app"]))
        XCTAssertThrowsError(try KeyExportOptions(["get", "--app", "/x", "--app", "/y"]))
        let resolved = try KeyExportOptions(["export", "--output", "~/keys.json"]).resolvedOutputURL()
        XCTAssertTrue(resolved.path.hasSuffix("/keys.json"))
        XCTAssertNotEqual(resolved.path, "~/keys.json")
    }
}
