import Foundation
import XCTest
@testable import WeChatAntiRecall

final class CodeSigningTests: XCTestCase {
    func testResignPreservesRootAndNestedEntitlements() throws {
        let fixture = try makeSignedAppFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
        }

        let before = try CodeSigningEntitlementsSnapshot.capture(in: fixture.appURL)
        XCTAssertGreaterThanOrEqual(before.entries.count, 3)
        let emptyBefore = try XCTUnwrap(
            before.entries.first {
                $0.url.standardizedFileURL == fixture.emptyXPCURL.standardizedFileURL
            }
        )
        XCTAssertNil(emptyBefore.plistData)

        try resign(
            appURL: fixture.appURL,
            nestedBinaries: [fixture.executableURL, fixture.helperExecutableURL]
        )

        XCTAssertEqual(try before.mismatchingPaths(), [])
        XCTAssertEqual(
            try entitlementDictionary(at: fixture.appURL)["com.apple.security.network.client"] as? Bool,
            true
        )
        XCTAssertEqual(
            try entitlementDictionary(at: fixture.appURL)["com.apple.security.device.audio-input"] as? Bool,
            true
        )
        XCTAssertEqual(
            try entitlementDictionary(at: fixture.helperAppURL)["com.apple.security.inherit"] as? Bool,
            true
        )
        let after = try CodeSigningEntitlementsSnapshot.capture(in: fixture.appURL)
        let emptyAfter = try XCTUnwrap(
            after.entries.first {
                $0.url.standardizedFileURL == fixture.emptyXPCURL.standardizedFileURL
            }
        )
        XCTAssertNil(emptyAfter.plistData)
        XCTAssertEqual(
            try run(
                "/usr/bin/codesign",
                ["--verify", "--deep", "--strict", fixture.appURL.path]
            ),
            0
        )
    }

    private func makeSignedAppFixture() throws -> SignedAppFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-codesign-tests-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Fixture")
        let helperAppURL = appURL.appendingPathComponent("Contents/Helpers/Helper.app", isDirectory: true)
        let helperExecutableURL = helperAppURL.appendingPathComponent("Contents/MacOS/Helper")
        let emptyXPCURL = appURL.appendingPathComponent("Contents/XPCServices/Empty.xpc", isDirectory: true)
        let emptyXPCExecutableURL = emptyXPCURL.appendingPathComponent("Contents/MacOS/Empty")

        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: helperExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: emptyXPCExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sourceURL = root.appendingPathComponent("main.c")
        try "int main(void) { return 0; }\n".write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            try run("/usr/bin/xcrun", ["clang", sourceURL.path, "-o", executableURL.path]),
            0
        )
        try FileManager.default.copyItem(at: executableURL, to: helperExecutableURL)
        try FileManager.default.copyItem(at: executableURL, to: emptyXPCExecutableURL)

        try writeInfoPlist(
            [
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": "dev.wechat-antirecall.codesign-fixture",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1"
            ],
            to: appURL.appendingPathComponent("Contents/Info.plist")
        )
        try writeInfoPlist(
            [
                "CFBundleExecutable": "Helper",
                "CFBundleIdentifier": "dev.wechat-antirecall.codesign-fixture.helper",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1"
            ],
            to: helperAppURL.appendingPathComponent("Contents/Info.plist")
        )
        try writeInfoPlist(
            [
                "CFBundleExecutable": "Empty",
                "CFBundleIdentifier": "dev.wechat-antirecall.codesign-fixture.empty",
                "CFBundlePackageType": "XPC!",
                "CFBundleVersion": "1"
            ],
            to: emptyXPCURL.appendingPathComponent("Contents/Info.plist")
        )

        let rootEntitlementsURL = root.appendingPathComponent("root-entitlements.plist")
        let helperEntitlementsURL = root.appendingPathComponent("helper-entitlements.plist")
        try writeInfoPlist(
            [
                "com.apple.security.device.audio-input": true,
                "com.apple.security.network.client": true
            ],
            to: rootEntitlementsURL
        )
        try writeInfoPlist(
            [
                "com.apple.security.app-sandbox": true,
                "com.apple.security.inherit": true
            ],
            to: helperEntitlementsURL
        )

        XCTAssertEqual(
            try run(
                "/usr/bin/codesign",
                [
                    "--force", "--sign", "-",
                    "--entitlements", helperEntitlementsURL.path,
                    helperAppURL.path
                ]
            ),
            0
        )
        XCTAssertEqual(
            try run(
                "/usr/bin/codesign",
                ["--force", "--sign", "-", emptyXPCURL.path]
            ),
            0
        )
        XCTAssertEqual(
            try run(
                "/usr/bin/codesign",
                [
                    "--force", "--sign", "-",
                    "--entitlements", rootEntitlementsURL.path,
                    appURL.path
                ]
            ),
            0
        )

        return SignedAppFixture(
            root: root,
            appURL: appURL,
            executableURL: executableURL,
            helperAppURL: helperAppURL,
            helperExecutableURL: helperExecutableURL,
            emptyXPCURL: emptyXPCURL
        )
    }

    private func writeInfoPlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private func entitlementDictionary(at url: URL) throws -> [String: Any] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--entitlements", "-", "--xml", url.path]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        return try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

private struct SignedAppFixture {
    let root: URL
    let appURL: URL
    let executableURL: URL
    let helperAppURL: URL
    let helperExecutableURL: URL
    let emptyXPCURL: URL
}
