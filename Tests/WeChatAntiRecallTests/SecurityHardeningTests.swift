import XCTest
@testable import WeChatAntiRecall

final class SecurityHardeningTests: XCTestCase {
    private let installName = "@loader_path/libWeChatAntiRecallRuntime.dylib"

    func testBundleRelativePathRejectsEscapingComponents() throws {
        let appURL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

        XCTAssertThrowsError(try BundleRelativePath.resolve("../out", in: appURL))
        XCTAssertThrowsError(try BundleRelativePath.resolve("/tmp/out", in: appURL))
        XCTAssertThrowsError(try BundleRelativePath.resolve(".", in: appURL))

        XCTAssertEqual(
            try BundleRelativePath.resolve("Contents/Resources/wechat.dylib", in: appURL).path,
            "/Applications/WeChat.app/Contents/Resources/wechat.dylib"
        )
    }

    func testRuntimeDylibRejectsNonMachOFile() throws {
        let url = try temporaryFile(named: "libWeChatAntiRecallRuntime.dylib", data: Data([0xde, 0xad, 0xbe, 0xef]))

        XCTAssertThrowsError(try RuntimeTipInstaller.validateRuntimeDylib(at: url))
    }

    func testRuntimeDylibRejectsSymlink() throws {
        let directory = try temporaryDirectory()
        let realURL = directory.appendingPathComponent("real.dylib")
        let symlinkURL = directory.appendingPathComponent("libWeChatAntiRecallRuntime.dylib")
        try Data([0xde, 0xad, 0xbe, 0xef]).write(to: realURL)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realURL)

        XCTAssertThrowsError(try RuntimeTipInstaller.validateRuntimeDylib(at: symlinkURL))
    }

    func testRuntimeDylibRejectsMachOWithoutRequiredSymbols() throws {
        let url = try temporaryFile(named: "libWeChatAntiRecallRuntime.dylib", data: makeMinimalArm64DylibData())

        XCTAssertThrowsError(try RuntimeTipInstaller.validateRuntimeDylib(at: url))
    }

    func testBuiltRuntimeDylibPassesValidation() throws {
        let runtimeURL = try currentBuildRuntimeDylibURL()

        XCTAssertNoThrow(try RuntimeTipInstaller.validateRuntimeDylib(at: runtimeURL))
    }

    func testMachOInjectorRejectsMalformedFatHeaderWithoutTrapping() throws {
        let url = try temporaryFile(
            named: "wechat.dylib",
            data: Data([0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x01])
        )

        XCTAssertThrowsError(
            try MachODylibInjector(fileURL: url).inject(installName: installName, arch: .arm64, dryRun: true)
        )
    }

    func testMachOInjectorRejectsMalformedThinHeaderWithoutTrapping() throws {
        var data = Data()
        data.appendLE32(0xfeedfacf)
        let url = try temporaryFile(named: "wechat.dylib", data: data)

        XCTAssertThrowsError(
            try MachODylibInjector(fileURL: url).inject(installName: installName, arch: .arm64, dryRun: true)
        )
    }

    func testMachOInjectorRejectsZeroLoadCommandSize() throws {
        var command = Data()
        command.appendLE32(0x19)
        command.appendLE32(0)
        let url = try temporaryFile(named: "wechat.dylib", data: makeThinMachOData(loadCommands: command))

        XCTAssertThrowsError(
            try MachODylibInjector(fileURL: url).inject(installName: installName, arch: .arm64, dryRun: true)
        )
    }

    func testMachOInjectorRejectsInvalidLoadDylibNameOffset() throws {
        var command = Data()
        command.appendLE32(0xc)
        command.appendLE32(24)
        command.appendLE32(24)
        command.appendLE32(2)
        command.appendLE32(0)
        command.appendLE32(0)
        let url = try temporaryFile(named: "wechat.dylib", data: makeThinMachOData(loadCommands: command))

        XCTAssertThrowsError(
            try MachODylibInjector(fileURL: url).inject(installName: installName, arch: .arm64, dryRun: true)
        )
    }

    private func currentBuildRuntimeDylibURL() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent(".build/debug/libWeChatAntiRecallRuntime.dylib"),
            cwd.appendingPathComponent(".build/release/libWeChatAntiRecallRuntime.dylib"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/libWeChatAntiRecallRuntime.dylib"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/release/libWeChatAntiRecallRuntime.dylib")
        ]

        guard let url = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw XCTSkip("Runtime dylib build artifact is not available")
        }
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-security-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makeMinimalArm64DylibData() -> Data {
        makeThinMachOData(fileType: 6, loadCommands: makeTextSegmentCommand())
    }

    private func makeThinMachOData(fileType: UInt32 = 6, loadCommands: Data) -> Data {
        var data = Data()
        data.appendLE32(0xfeedfacf)
        data.appendLE32(0x0100000c)
        data.appendLE32(0)
        data.appendLE32(fileType)
        data.appendLE32(1)
        data.appendLE32(UInt32(loadCommands.count))
        data.appendLE32(0)
        data.appendLE32(0)
        data.append(loadCommands)
        return data
    }

    private func makeTextSegmentCommand() -> Data {
        var data = Data()
        data.appendLE32(0x19)
        data.appendLE32(72)
        data.appendPaddedASCII("__TEXT", length: 16)
        data.appendLE64(0)
        data.appendLE64(4096)
        data.appendLE64(0)
        data.appendLE64(4096)
        data.appendLE32(7)
        data.appendLE32(5)
        data.appendLE32(0)
        data.appendLE32(0)
        return data
    }
}

private extension Data {
    mutating func appendLE32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }

    mutating func appendLE64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    mutating func appendPaddedASCII(_ value: String, length: Int) {
        let bytes = Array(value.utf8)
        append(contentsOf: bytes.prefix(length))
        if bytes.count < length {
            append(contentsOf: Array(repeating: 0, count: length - bytes.count))
        }
    }
}
