import XCTest
@testable import WeChatAntiRecall

final class MachODylibInjectorTests: XCTestCase {
    private let installName = "@loader_path/libWeChatAntiRecallRuntime.dylib"
    private let arm64CPUType: Int32 = 0x0100000c
    private let segment64LoadCommand: UInt32 = 0x19

    func testInjectsLoadDylibIntoThinMachOHeaderPadding() throws {
        let url = try makeTemporaryMachO()

        let reports = try MachODylibInjector(fileURL: url).inject(
            installName: installName,
            arch: .arm64,
            dryRun: false
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, .injected)
        XCTAssertTrue(try loadDylibCommands(in: url).contains(installName))
    }

    func testInjectsLoadDylibIntoFatMachOSliceHeaderPadding() throws {
        let sliceOffset = 4096
        let url = try makeTemporaryFatMachO(sliceOffset: sliceOffset)

        let reports = try MachODylibInjector(fileURL: url).inject(
            installName: installName,
            arch: .arm64,
            dryRun: false
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, .injected)
        XCTAssertTrue(try loadDylibCommands(in: url, machOffset: sliceOffset).contains(installName))
    }

    func testDryRunDoesNotModifyMachO() throws {
        let url = try makeTemporaryMachO()
        let before = try Data(contentsOf: url)

        let reports = try MachODylibInjector(fileURL: url).inject(
            installName: installName,
            arch: .arm64,
            dryRun: true
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, .wouldInject)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(try loadDylibCommands(in: url).contains(installName))
    }

    func testAlreadyInjectedDylibIsReported() throws {
        let url = try makeTemporaryMachO()
        _ = try MachODylibInjector(fileURL: url).inject(
            installName: installName,
            arch: .arm64,
            dryRun: false
        )

        let reports = try MachODylibInjector(fileURL: url).inject(
            installName: installName,
            arch: .arm64,
            dryRun: true
        )

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, .alreadyInjected)
    }

    func testRuntimeInstallerCopiesDylibAndInjectsHostBinary() throws {
        try assertRuntimeInstallerCopiesDylibAndInjectsHostBinary(buildVersion: "268597")
    }

    func testRuntimeInstallerSupportsBuild268599() throws {
        try assertRuntimeInstallerCopiesDylibAndInjectsHostBinary(buildVersion: "268599")
    }

    private func assertRuntimeInstallerCopiesDylibAndInjectsHostBinary(buildVersion: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-runtime-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let resourcesURL = directory
            .appendingPathComponent("WeChat.app/Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let hostBinaryURL = resourcesURL.appendingPathComponent("wechat.dylib")
        try Data(contentsOf: try makeTemporaryMachO()).write(to: hostBinaryURL)

        let sourceDylibURL = directory.appendingPathComponent(RuntimeTipInstaller.dylibFileName)
        try Data([0xca, 0xfe, 0xba, 0xbe]).write(to: sourceDylibURL)

        let appInfo = AppInfo(
            appURL: directory.appendingPathComponent("WeChat.app"),
            executableURL: directory.appendingPathComponent("WeChat.app/Contents/MacOS/WeChat"),
            shortVersion: "4.1.9",
            buildVersion: buildVersion,
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        let options = try InstallOptions(["--runtime-dylib", sourceDylibURL.path])

        let installer = try RuntimeTipInstaller(appInfo: appInfo, options: options)
        let reports = try installer.install(dryRun: false)

        XCTAssertEqual(reports.map(\.status), [.injected])
        XCTAssertEqual(
            try Data(contentsOf: resourcesURL.appendingPathComponent(RuntimeTipInstaller.dylibFileName)),
            try Data(contentsOf: sourceDylibURL)
        )
        XCTAssertTrue(try loadDylibCommands(in: hostBinaryURL).contains(RuntimeTipInstaller.installName))
    }

    func testRuntimeInstallerRejectsUnsupportedBuildVersion() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-runtime-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceDylibURL = directory.appendingPathComponent(RuntimeTipInstaller.dylibFileName)
        try Data([0xca, 0xfe, 0xba, 0xbe]).write(to: sourceDylibURL)

        let appInfo = AppInfo(
            appURL: directory.appendingPathComponent("WeChat.app"),
            executableURL: directory.appendingPathComponent("WeChat.app/Contents/MacOS/WeChat"),
            shortVersion: "4.1.8",
            buildVersion: "268596",
            bundleIdentifier: "com.tencent.xinWeChat"
        )
        let options = try InstallOptions(["--runtime-dylib", sourceDylibURL.path])

        XCTAssertThrowsError(try RuntimeTipInstaller(appInfo: appInfo, options: options)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "补丁配置无效：runtime-tip 目前只支持微信构建号 268597, 268599，当前构建号是 268596"
            )
        }
    }

    private func makeTemporaryMachO(contentOffset: UInt32 = 320) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wechat.dylib")

        let data = makeThinMachOData(contentOffset: contentOffset)
        try data.write(to: url)
        return url
    }

    private func makeTemporaryFatMachO(sliceOffset: Int, contentOffset: UInt32 = 320) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wechat-antirecall-macho-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("wechat.dylib")
        let slice = makeThinMachOData(contentOffset: contentOffset)

        var data = Data()
        data.appendBE32(0xcafebabe)
        data.appendBE32(1)
        data.appendBE32(UInt32(bitPattern: arm64CPUType))
        data.appendBE32(0)
        data.appendBE32(UInt32(sliceOffset))
        data.appendBE32(UInt32(slice.count))
        data.appendBE32(12)
        while data.count < sliceOffset {
            data.append(0)
        }
        data.append(slice)

        try data.write(to: url)
        return url
    }

    private func makeThinMachOData(contentOffset: UInt32 = 320) -> Data {
        var data = Data()
        data.appendLE32(0xfeedfacf)
        data.appendLE32(UInt32(bitPattern: arm64CPUType))
        data.appendLE32(0)
        data.appendLE32(6)
        data.appendLE32(1)
        data.appendLE32(152)
        data.appendLE32(0)
        data.appendLE32(0)

        data.appendLE32(segment64LoadCommand)
        data.appendLE32(152)
        data.appendPaddedASCII("__TEXT", length: 16)
        data.appendLE64(0)
        data.appendLE64(512)
        data.appendLE64(0)
        data.appendLE64(512)
        data.appendLE32(7)
        data.appendLE32(5)
        data.appendLE32(1)
        data.appendLE32(0)

        data.appendPaddedASCII("__text", length: 16)
        data.appendPaddedASCII("__TEXT", length: 16)
        data.appendLE64(UInt64(contentOffset))
        data.appendLE64(4)
        data.appendLE32(contentOffset)
        data.appendLE32(2)
        data.appendLE32(0)
        data.appendLE32(0)
        data.appendLE32(0)
        data.appendLE32(0)
        data.appendLE32(0)
        data.appendLE32(0)

        while data.count < Int(contentOffset) {
            data.append(0)
        }
        data.append(contentsOf: [0xc0, 0x03, 0x5f, 0xd6])
        return data
    }

    private func loadDylibCommands(in url: URL, machOffset: Int = 0) throws -> [String] {
        let data = try Data(contentsOf: url)
        let ncmds = Int(data.leUInt32(at: machOffset + 16))
        var commandOffset = machOffset + 32
        var result: [String] = []

        for _ in 0..<ncmds {
            let cmd = data.leUInt32(at: commandOffset)
            let cmdsize = Int(data.leUInt32(at: commandOffset + 4))
            if cmd == 0xc {
                let nameOffset = Int(data.leUInt32(at: commandOffset + 8))
                let start = commandOffset + nameOffset
                let end = (start..<(commandOffset + cmdsize)).first { data[$0] == 0 } ?? commandOffset + cmdsize
                result.append(String(data: data[start..<end], encoding: .utf8) ?? "")
            }
            commandOffset += cmdsize
        }

        return result
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

    mutating func appendBE32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendPaddedASCII(_ value: String, length: Int) {
        let bytes = Array(value.utf8)
        append(contentsOf: bytes.prefix(length))
        if bytes.count < length {
            append(contentsOf: Array(repeating: 0, count: length - bytes.count))
        }
    }
}
