import XCTest

final class PatchConfigTests: XCTestCase {
    private let removedBuilds = [
        "31927",
        "32281",
        "32288",
        "31960",
        "34371",
        "34817",
        "36559"
    ]

    func testEveryPatchEntryHasNonEmptyExpectedBytes() throws {
        let patchConfigs = try loadPatchConfigs()

        for patchConfig in patchConfigs {
            let version = try XCTUnwrap(patchConfig["version"] as? String)
            let targets = try XCTUnwrap(patchConfig["targets"] as? [[String: Any]])

            for target in targets {
                let identifier = try XCTUnwrap(target["identifier"] as? String)
                let entries = try XCTUnwrap(target["entries"] as? [[String: Any]])

                for entry in entries {
                    let arch = try XCTUnwrap(entry["arch"] as? String)
                    let addr = try XCTUnwrap(entry["addr"] as? String)

                    XCTAssertTrue(
                        hasNonEmptyExpectedBytes(entry),
                        "Missing non-empty expected for version \(version), target \(identifier), arch \(arch), addr \(addr)"
                    )
                }
            }
        }
    }

    func testRemovedBuildsAreNotDocumentedInReadme() throws {
        let readme = try String(contentsOf: repositoryRoot().appendingPathComponent("README.md"))

        for build in removedBuilds {
            XCTAssertFalse(readme.contains(build), "README.md still documents removed build \(build)")
        }
    }

    private func loadPatchConfigs() throws -> [[String: Any]] {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent("patches.json"))
        let json = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(json as? [[String: Any]])
    }

    private func hasNonEmptyExpectedBytes(_ entry: [String: Any]) -> Bool {
        if let expected = entry["expected"] as? String {
            return !expected.isEmpty
        }

        if let expectedValues = entry["expected"] as? [String] {
            return !expectedValues.isEmpty && expectedValues.allSatisfy { !$0.isEmpty }
        }

        return false
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
