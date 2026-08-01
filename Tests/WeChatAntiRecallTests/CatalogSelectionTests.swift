import Foundation
import XCTest
@testable import WeChatAntiRecallGUI

final class CatalogSelectionTests: XCTestCase {
    func testHigherBuildCatalogBeatsNewerButStaleOverride() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let staleDownload = directory.appendingPathComponent("downloaded.json")
        let bundled = directory.appendingPathComponent("bundled.json")
        try writeCatalog(builds: [269110], to: staleDownload)
        try writeCatalog(builds: [269340, 269341], to: bundled)

        // Even a later modification date must not let a lower-build override hide new support.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: staleDownload.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: bundled.path)

        XCTAssertEqual(BundledPaths.newerCatalog(staleDownload, bundled), bundled)
    }

    func testFreshDownloadWinsWhenLatestBuildMatches() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let downloaded = directory.appendingPathComponent("downloaded.json")
        let bundled = directory.appendingPathComponent("bundled.json")
        try writeCatalog(builds: [269341], to: downloaded)
        try writeCatalog(builds: [269341], to: bundled)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: downloaded.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: bundled.path)

        XCTAssertEqual(BundledPaths.newerCatalog(downloaded, bundled), downloaded)
    }

    func testInvalidCatalogFallsBackToValidCandidate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalid = directory.appendingPathComponent("invalid.json")
        let valid = directory.appendingPathComponent("valid.json")
        try Data("not-json".utf8).write(to: invalid)
        try writeCatalog(builds: [269341], to: valid)

        XCTAssertEqual(BundledPaths.newerCatalog(invalid, valid), valid)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCatalog(builds: [Int], to url: URL) throws {
        let catalog = builds.map { build in
            ["version": String(build), "targets": []] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: catalog)
        try data.write(to: url)
    }
}
