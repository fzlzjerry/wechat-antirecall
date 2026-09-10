#!/usr/bin/env python3
"""Read-only Intel preflight for WeChat on macOS.

The tool inspects a target .app bundle, parses the bundled wechat.dylib as a
thin or fat Mach-O, computes streaming SHA-256 digests, and reports only what
is covered by the local patch catalog.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import platform
import re
import subprocess
import struct
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

JSON_SCHEMA_VERSION = 1
DEFAULT_APP_PATH = "/Applications/WeChat.app"
DEFAULT_CONFIG_PATH = str(Path(__file__).resolve().parents[1] / "patches.json")
DEFAULT_BINARY_RELATIVE_PATH = "Contents/Resources/wechat.dylib"

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_SEGMENT_64 = 0x19
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM64 = 0x0100000C

FEATURE_BY_IDENTIFIER = {
    "revoke": "silent",
    "revoke-tip": "tip",
    "runtime-tip": "runtime-tip",
    "update": "block-update",
    "multiInstance": "multi-instance",
    "multiInstance-extra": "multi-instance-extra",
}

ARCH_BY_CPU_TYPE = {
    CPU_TYPE_X86_64: "x86_64",
    CPU_TYPE_ARM64: "arm64",
}


class PreflightError(Exception):
    def __init__(self, kind: str, message: str, *, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.kind = kind
        self.message = message
        self.details = details or {}

    def to_payload(self) -> dict[str, Any]:
        payload = {"kind": self.kind, "message": self.message}
        payload.update(
            {
                k: v
                for k, v in self.details.items()
                if v is not None and "path" not in k.lower()
            }
        )
        return payload


@dataclass(frozen=True)
class AppInfo:
    app_path: Path
    bundle_identifier: str
    marketing_version: str
    build_version: str
    executable_name: str
    binary_path: Path


@dataclass(frozen=True)
class HostInfo:
    python_version: str
    implementation: str
    platform: str
    executable: str
    machine: str
    macos_version: str
    swift_probe: "ProbeResult"
    macos_sdk_version_probe: "ProbeResult"
    macos_sdk_platform_probe: "ProbeResult"


@dataclass(frozen=True)
class ProbeResult:
    status: str
    detail: str
    exit_code: int | None = None


@dataclass(frozen=True)
class MachOSlice:
    arch: str
    offset: int
    size: int
    sha256: str
    segments: list[dict[str, Any]]


@dataclass(frozen=True)
class BinaryReport:
    path: str
    kind: str
    sha256: str
    x86_64_slice_sha256: str | None
    slices: list[MachOSlice]


@dataclass(frozen=True)
class ConfigTargetReport:
    identifier: str
    feature: str
    arches: list[str]
    entry_count: int
    intel_covered: bool


@dataclass(frozen=True)
class CatalogReport:
    path: str
    build_version: str
    build_matched: bool
    target_count: int
    intel_covered: bool
    targets: list[ConfigTargetReport]


@dataclass(frozen=True)
class Report:
    schema_version: int
    app: AppInfo
    binary: BinaryReport
    catalog: CatalogReport
    host: HostInfo
    summary: str

    def to_jsonable(self) -> dict[str, Any]:
        return {
            "schemaVersion": self.schema_version,
            "app": {
                "path": safe_basename(self.app.app_path),
                "bundleIdentifier": self.app.bundle_identifier,
                "marketingVersion": self.app.marketing_version,
                "buildVersion": self.app.build_version,
                "executable": self.app.executable_name,
                "binaryPath": self.app.binary_path.name,
            },
            "binary": {
                "path": Path(self.binary.path).name,
                "kind": self.binary.kind,
                "sha256": self.binary.sha256,
                "x86_64SliceSha256": self.binary.x86_64_slice_sha256,
                "slices": [
                    {
                        "arch": slice_.arch,
                        "offset": slice_.offset,
                        "size": slice_.size,
                        "sha256": slice_.sha256,
                        "segments": slice_.segments,
                    }
                    for slice_ in self.binary.slices
                ],
            },
            "catalog": {
                "path": Path(self.catalog.path).name,
                "buildVersion": self.catalog.build_version,
                "buildMatched": self.catalog.build_matched,
                "targetCount": self.catalog.target_count,
                "intelCovered": self.catalog.intel_covered,
                "targets": [
                    {
                        "identifier": item.identifier,
                        "feature": item.feature,
                        "arches": item.arches,
                        "entryCount": item.entry_count,
                        "intelCovered": item.intel_covered,
                    }
                    for item in self.catalog.targets
                ],
            },
            "host": {
                "pythonVersion": self.host.python_version,
                "implementation": self.host.implementation,
                "platform": self.host.platform,
                "executable": Path(self.host.executable).name,
                "machine": self.host.machine,
                "macosVersion": self.host.macos_version,
                "swiftProbe": {
                    "status": self.host.swift_probe.status,
                    "detail": self.host.swift_probe.detail,
                    "exitCode": self.host.swift_probe.exit_code,
                },
                "macosSdkVersionProbe": {
                    "status": self.host.macos_sdk_version_probe.status,
                    "detail": self.host.macos_sdk_version_probe.detail,
                    "exitCode": self.host.macos_sdk_version_probe.exit_code,
                },
                "macosSdkPlatformProbe": {
                    "status": self.host.macos_sdk_platform_probe.status,
                    "detail": self.host.macos_sdk_platform_probe.detail,
                    "exitCode": self.host.macos_sdk_platform_probe.exit_code,
                },
            },
            "limitations": [
                "只读目录预检",
                "不写入、不安装、不签名、不联网",
                "非 Swift CLI dry-run",
                "不代表真实 Intel 实机已验证",
            ],
            "summary": self.summary,
        }


class ReadOnlyFile:
    def __init__(self, path: Path):
        self.path = path
        self._fh = path.open("rb")

    def close(self) -> None:
        self._fh.close()

    def read_at(self, offset: int, size: int) -> bytes:
        self._fh.seek(offset)
        data = self._fh.read(size)
        if len(data) != size:
            raise PreflightError(
                "truncatedMachO",
                "Mach-O 文件内容不足，无法完成解析",
                details={"path": str(self.path), "offset": offset, "requested": size, "read": len(data)},
            )
        return data

    def iter_range(self, offset: int, size: int, chunk_size: int = 1024 * 1024):
        remaining = size
        cursor = offset
        while remaining:
            take = min(chunk_size, remaining)
            self._fh.seek(cursor)
            chunk = self._fh.read(take)
            if len(chunk) != take:
                raise PreflightError(
                    "truncatedMachO",
                    "Mach-O 文件内容不足，无法完成解析",
                    details={"path": str(self.path), "offset": cursor, "requested": take, "read": len(chunk)},
                )
            yield chunk
            remaining -= take
            cursor += take

    def digest_range(self, offset: int, size: int) -> str:
        hasher = hashlib.sha256()
        for chunk in self.iter_range(offset, size):
            hasher.update(chunk)
        return hasher.hexdigest()

    def digest_whole(self) -> str:
        return self.digest_range(0, self.path.stat().st_size)


def safe_basename(path: Path) -> str:
    return path.name or str(path)


def load_config(path: Path) -> list[dict[str, Any]]:
    try:
        data = path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise PreflightError("missingConfig", "找不到 patches.json", details={"path": str(path)}) from exc
    except UnicodeDecodeError as exc:
        raise PreflightError("invalidConfig", "patches.json 不是合法 UTF-8 文本", details={"path": str(path)}) from exc
    try:
        value = json.loads(data)
    except json.JSONDecodeError as exc:
        raise PreflightError("invalidConfig", "patches.json 不是合法 JSON", details={"path": str(path)}) from exc
    if not isinstance(value, list):
        raise PreflightError("invalidConfig", "patches.json 顶层必须是数组", details={"path": str(path)})
    return value


def _path_is_inside(candidate: Path, root: Path) -> bool:
    try:
        candidate.resolve(strict=True).relative_to(root.resolve(strict=True))
        return True
    except Exception:
        return False


def _validate_target_entries(entries: Any, *, config_path: Path, build_version: str, target_index: int) -> list[dict[str, Any]]:
    if not isinstance(entries, list) or not entries:
        raise PreflightError(
            "invalidConfig",
            "patches.json 里的 entries 必须是非空数组",
            details={"path": str(config_path), "buildVersion": build_version, "targetIndex": target_index},
        )

    normalized: list[dict[str, Any]] = []
    for entry_index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise PreflightError(
                "invalidConfig",
                "patches.json 里的 entry 必须是对象",
                details={"path": str(config_path), "buildVersion": build_version, "targetIndex": target_index, "entryIndex": entry_index},
            )
        arch = entry.get("arch")
        addr = entry.get("addr")
        expected = entry.get("expected")
        asm = entry.get("asm")
        if not isinstance(arch, str) or not arch:
            raise PreflightError(
                "invalidConfig",
                "patches.json 里的 entry 缺少 arch",
                details={"path": str(config_path), "buildVersion": build_version, "targetIndex": target_index, "entryIndex": entry_index},
            )
        if not isinstance(addr, str) or not addr:
            raise PreflightError(
                "invalidConfig",
                "patches.json 里的 entry 缺少 addr",
                details={"path": str(config_path), "buildVersion": build_version, "targetIndex": target_index, "entryIndex": entry_index, "arch": arch},
            )
        if not isinstance(asm, str) or not asm:
            raise PreflightError(
                "invalidConfig",
                "patches.json 里的 entry 缺少 asm",
                details={"path": str(config_path), "buildVersion": build_version, "targetIndex": target_index, "entryIndex": entry_index, "arch": arch},
            )
        if not isinstance(expected, (str, list)) or (isinstance(expected, list) and not all(isinstance(item, str) for item in expected)):
            raise PreflightError(
                "invalidConfig",
                "patches.json 里的 entry expected 格式不合法",
                details={"path": str(config_path), "buildVersion": build_version, "targetIndex": target_index, "entryIndex": entry_index, "arch": arch},
            )
        normalized.append(entry)
    return normalized


def read_app_info(app_path: Path) -> AppInfo:
    if not app_path.exists():
        raise PreflightError("missingApp", "找不到 app bundle", details={"path": str(app_path)})
    if not app_path.is_dir():
        raise PreflightError("missingApp", "app 路径不是目录", details={"path": str(app_path)})

    info_path = app_path / "Contents" / "Info.plist"
    if not info_path.exists():
        raise PreflightError("missingInfoPlist", "找不到 Info.plist", details={"path": str(info_path)})
    if not info_path.is_file():
        raise PreflightError("missingInfoPlist", "找不到 Info.plist", details={"path": str(info_path)})
    if not _path_is_inside(info_path, app_path):
        raise PreflightError("pathEscape", "Info.plist 指向 bundle 外部")
    try:
        with info_path.open("rb") as fh:
            plist = plistlib.load(fh)
    except Exception as exc:  # pragma: no cover - defensive, surfaced in tests via message
        raise PreflightError("invalidInfoPlist", "Info.plist 不是合法 plist", details={"path": str(info_path)}) from exc
    if not isinstance(plist, dict):
        raise PreflightError("invalidInfoPlist", "Info.plist 内容不是字典", details={"path": str(info_path)})

    required = {
        "CFBundleExecutable": "executable",
        "CFBundleShortVersionString": "marketingVersion",
        "CFBundleVersion": "buildVersion",
        "CFBundleIdentifier": "bundleIdentifier",
    }
    extracted: dict[str, str] = {}
    for plist_key, report_key in required.items():
        value = plist.get(plist_key)
        if not isinstance(value, str) or not value:
            raise PreflightError("missingInfoField", f"Info.plist 缺少 {plist_key}", details={"path": str(info_path), "key": plist_key})
        extracted[report_key] = value

    binary_path = app_path / DEFAULT_BINARY_RELATIVE_PATH
    if not binary_path.exists():
        raise PreflightError("missingBinary", "找不到 bundled wechat.dylib", details={"path": str(binary_path)})
    if not binary_path.is_file():
        raise PreflightError("missingBinary", "bundled wechat.dylib 不是文件", details={"path": str(binary_path)})
    if not _path_is_inside(binary_path, app_path):
        raise PreflightError("pathEscape", "bundled wechat.dylib 指向 bundle 外部")

    return AppInfo(
        app_path=app_path,
        bundle_identifier=extracted["bundleIdentifier"],
        marketing_version=extracted["marketingVersion"],
        build_version=extracted["buildVersion"],
        executable_name=extracted["executable"],
        binary_path=binary_path,
    )


def analyze_binary(path: Path) -> BinaryReport:
    view = ReadOnlyFile(path)
    try:
        file_size = path.stat().st_size
        whole_sha = view.digest_whole()
        magic = struct.unpack(">I", view.read_at(0, 4))[0]
        if magic == FAT_MAGIC:
            slices = _analyze_fat(view, path, file_size, is_64_bit=False)
            kind = "fat32"
        elif magic == FAT_MAGIC_64:
            slices = _analyze_fat(view, path, file_size, is_64_bit=True)
            kind = "fat64"
        elif struct.unpack("<I", view.read_at(0, 4))[0] == MH_MAGIC_64:
            slices = [_analyze_thin_slice(view, path, 0, file_size)]
            kind = f"thin-{slices[0].arch}"
        else:
            raise PreflightError("unsupportedMachO", "不支持的 Mach-O 文件格式", details={"path": str(path)})
    finally:
        view.close()

    x86_hash = next((slice_.sha256 for slice_ in slices if slice_.arch == "x86_64"), None)
    return BinaryReport(
        path=str(path),
        kind=kind,
        sha256=whole_sha,
        x86_64_slice_sha256=x86_hash,
        slices=slices,
    )


def _analyze_fat(view: ReadOnlyFile, path: Path, file_size: int, *, is_64_bit: bool) -> list[MachOSlice]:
    if file_size < (8 + (32 if is_64_bit else 20)):
        raise PreflightError("invalidFat", "fat 头部过短", details={"path": str(path)})
    nfat = struct.unpack(">I", view.read_at(4, 4))[0]
    if nfat <= 0:
        raise PreflightError("invalidFat", "fat Mach-O 里没有切片", details={"path": str(path), "nfat": nfat})
    entry_size = 32 if is_64_bit else 20
    table_size = 8 + nfat * entry_size
    if table_size > file_size:
        raise PreflightError("invalidFat", "fat 头部超出文件边界", details={"path": str(path)})

    slice_specs: list[dict[str, int]] = []
    seen_arches: set[str] = set()
    occupied_ranges: list[tuple[int, int]] = []
    for index in range(nfat):
        entry_offset = 8 + index * entry_size
        entry = view.read_at(entry_offset, entry_size)
        if is_64_bit:
            cputype, _cpusubtype, slice_offset, slice_size, _align, _reserved = struct.unpack(">IIQQII", entry)
        else:
            cputype, _cpusubtype, slice_offset32, slice_size32, _align = struct.unpack(">IIIII", entry)
            slice_offset = slice_offset32
            slice_size = slice_size32
        if slice_size < 32:
            raise PreflightError(
                "invalidFatSlice",
                "fat 切片过短",
                details={"path": str(path), "sliceIndex": index, "offset": slice_offset, "size": slice_size},
            )
        if slice_offset < table_size:
            raise PreflightError(
                "invalidFatSlice",
                "fat 切片落在 fat 头部或 table 覆盖范围内",
                details={"path": str(path), "sliceIndex": index, "offset": slice_offset, "tableSize": table_size},
            )
        if slice_offset + slice_size > file_size:
            raise PreflightError(
                "invalidFatSlice",
                "fat 切片超出文件边界",
                details={"path": str(path), "sliceIndex": index, "offset": slice_offset, "size": slice_size},
            )
        arch = ARCH_BY_CPU_TYPE.get(cputype, f"cpu-0x{cputype:x}")
        if arch in seen_arches:
            raise PreflightError(
                "duplicateSliceArch",
                "fat Mach-O 包含重复架构切片",
                details={"path": str(path), "arch": arch, "sliceIndex": index},
            )
        for start, end in occupied_ranges:
            if not (slice_offset + slice_size <= start or slice_offset >= end):
                raise PreflightError(
                    "overlappingSlice",
                    "fat Mach-O 切片范围重叠",
                    details={"path": str(path), "arch": arch, "sliceIndex": index},
                )
        seen_arches.add(arch)
        occupied_ranges.append((slice_offset, slice_offset + slice_size))
        slice_specs.append({"offset": slice_offset, "size": slice_size, "cputype": cputype})

    slices: list[MachOSlice] = []
    for spec in slice_specs:
        slices.append(_analyze_thin_slice(view, path, spec["offset"], spec["size"], cputype=spec["cputype"]))
    return slices


def _analyze_thin_slice(
    view: ReadOnlyFile,
    path: Path,
    offset: int,
    size: int,
    *,
    cputype: int | None = None,
) -> MachOSlice:
    header = view.read_at(offset, 32)
    magic, header_cpu_type, _cpusubtype, _filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack("<IIIIIIII", header)
    if magic != MH_MAGIC_64:
        raise PreflightError("invalidMachO", "切片不是薄 Mach-O 64-bit", details={"path": str(path), "offset": offset})

    if cputype is None:
        cputype = header_cpu_type
    if header_cpu_type != cputype:
        raise PreflightError("cpuMismatch", "fat 目录项与切片头 CPU type 不一致", details={"path": str(path), "offset": offset})
    arch = ARCH_BY_CPU_TYPE.get(cputype)
    if arch is None:
        arch = f"cpu-0x{cputype:x}"

    if sizeofcmds + 32 > size:
        raise PreflightError(
            "invalidMachO",
            "Mach-O load commands 超出切片边界",
            details={"path": str(path), "offset": offset, "sizeofcmds": sizeofcmds, "size": size},
        )

    commands = view.read_at(offset + 32, sizeofcmds)
    cursor = 0
    segments: list[dict[str, Any]] = []
    for _ in range(ncmds):
        if cursor + 8 > len(commands):
            raise PreflightError("invalidMachO", "Mach-O load command 被截断", details={"path": str(path), "offset": offset})
        cmd, cmdsize = struct.unpack_from("<II", commands, cursor)
        if cmdsize < 8 or cursor + cmdsize > len(commands):
            raise PreflightError("invalidMachO", "Mach-O load command 超出边界", details={"path": str(path), "offset": offset})
        command = commands[cursor:cursor + cmdsize]
        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                raise PreflightError("invalidMachO", "LC_SEGMENT_64 长度不足", details={"path": str(path), "offset": offset})
            segname = command[8:24].split(b"\0", 1)[0].decode("ascii", errors="replace")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", command, 24)
            if fileoff + filesize > size:
                raise PreflightError(
                    "invalidSegment",
                    "Mach-O segment 超出切片边界",
                    details={"path": str(path), "offset": offset, "segment": segname, "fileoff": fileoff, "filesize": filesize, "size": size},
                )
            segments.append(
                {
                    "name": segname,
                    "vmaddr": f"0x{vmaddr:x}",
                    "vmsize": f"0x{vmsize:x}",
                    "fileoff": f"0x{fileoff:x}",
                    "filesize": f"0x{filesize:x}",
                }
            )
        cursor += cmdsize

    if cursor != len(commands):
        raise PreflightError("invalidMachO", "Mach-O load commands 未完全消费", details={"path": str(path), "offset": offset})

    sha = view.digest_range(offset, size)
    return MachOSlice(arch=arch, offset=offset, size=size, sha256=sha, segments=segments)


def load_catalog_report(config_path: Path, build_version: str) -> CatalogReport:
    configs = load_config(config_path)
    matched_items: list[dict[str, Any]] = []
    for index, item in enumerate(configs):
        if not isinstance(item, dict):
            raise PreflightError("invalidConfig", "patches.json 顶层条目必须是对象", details={"index": index})
        if item.get("version") == build_version:
            matched_items.append(item)
    if len(matched_items) > 1:
        raise PreflightError("invalidConfig", "patches.json 里 buildVersion 重复", details={"path": str(config_path), "buildVersion": build_version})
    if not matched_items:
        targets: list[ConfigTargetReport] = []
        return CatalogReport(
            path=str(config_path),
            build_version=build_version,
            build_matched=False,
            target_count=0,
            intel_covered=False,
            targets=targets,
        )

    matched = matched_items[0]
    raw_targets = matched.get("targets")
    if not isinstance(raw_targets, list):
        raise PreflightError("invalidConfig", "patches.json 里 targets 必须是数组", details={"path": str(config_path), "buildVersion": build_version})

    targets: list[ConfigTargetReport] = []
    for target_index, target in enumerate(raw_targets):
        if not isinstance(target, dict):
            raise PreflightError("invalidConfig", "patches.json 里的 target 必须是对象", details={"index": target_index, "buildVersion": build_version})
        identifier = target.get("identifier")
        entries = _validate_target_entries(target.get("entries"), config_path=config_path, build_version=build_version, target_index=target_index)
        if not isinstance(identifier, str) or not identifier:
            raise PreflightError("invalidConfig", "patches.json 里的 target 缺少 identifier", details={"index": target_index, "buildVersion": build_version})
        arches = sorted({entry["arch"] for entry in entries})
        intel_covered = any(entry["arch"] == "x86_64" for entry in entries)
        targets.append(
            ConfigTargetReport(
                identifier=identifier,
                feature=FEATURE_BY_IDENTIFIER.get(identifier, identifier),
                arches=arches,
                entry_count=len(entries),
                intel_covered=intel_covered,
            )
        )

    return CatalogReport(
        path=str(config_path),
        build_version=build_version,
        build_matched=True,
        target_count=len(targets),
        intel_covered=any(target.intel_covered for target in targets),
        targets=targets,
    )


def build_report(app_path: Path, config_path: Path) -> Report:
    app = read_app_info(app_path)
    binary = analyze_binary(app.binary_path)
    catalog = load_catalog_report(config_path, app.build_version)
    x86_note = "有 x86_64 slice" if binary.x86_64_slice_sha256 else "无 x86_64 slice"
    intel_note = "有 Intel catalog 覆盖" if catalog.intel_covered else "catalog 未提供 x86_64 覆盖"
    swift_probe = _probe_command(["swift", "--version"])
    sdk_version_probe = _probe_command(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    sdk_platform_probe = _probe_command(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], redact_output=True)
    host = HostInfo(
        python_version=sys.version.split()[0],
        implementation=sys.implementation.name,
        platform=sys.platform,
        executable=sys.executable,
        machine=platform.machine() or "unknown",
        macos_version=platform.mac_ver()[0] or "unknown",
        swift_probe=swift_probe,
        macos_sdk_version_probe=sdk_version_probe,
        macos_sdk_platform_probe=sdk_platform_probe,
    )
    summary = (
        f"{safe_basename(app.app_path)} {app.marketing_version} ({app.build_version})："
        f"binary={binary.kind}，{x86_note}；"
        f"catalog={'命中' if catalog.build_matched else '未命中'}，"
        f"targets={catalog.target_count}，{intel_note}；"
        f"host={host.machine} / {host.macos_version} / Python {host.python_version} / "
        f"Swift {host.swift_probe.status} / SDK {host.macos_sdk_version_probe.detail} / "
        f"SDK平台路径 probe {host.macos_sdk_platform_probe.status}；"
        f"非 Swift CLI dry-run。"
    )
    return Report(JSON_SCHEMA_VERSION, app, binary, catalog, host, summary)


def _probe_command(command: list[str], *, redact_output: bool = False) -> ProbeResult:
    try:
        completed = subprocess.run(
            command,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=10,
        )
    except FileNotFoundError:
        return ProbeResult("unavailable", "command not found", exit_code=127)
    except subprocess.TimeoutExpired:
        return ProbeResult("timeout", "timeout >=10s", exit_code=124)
    except subprocess.CalledProcessError as exc:
        output_text = getattr(exc, "stdout", None) or getattr(exc, "output", None) or ""
        output = output_text.strip().splitlines()
        detail = _redact_probe_text(output[0] if output else "")
        if not detail:
            detail = "probe failed"
        return ProbeResult("error", detail, exit_code=exc.returncode)
    output = completed.stdout.strip().splitlines()
    if redact_output:
        return ProbeResult("ok", "redacted", exit_code=completed.returncode)
    return ProbeResult("ok", _redact_probe_text(output[0] if output else "unavailable"), exit_code=completed.returncode)


def _redact_probe_text(text: str) -> str:
    if not text:
        return text
    redacted = text
    for token in _extract_absolute_paths(text):
        redacted = redacted.replace(token, "[redacted]")
    return redacted


def _extract_absolute_paths(text: str) -> list[str]:
    return re.findall(r"/[^\s,;:)]+", text)


def render_summary(report: Report) -> str:
    lines = [
        f"应用：{safe_basename(report.app.app_path)} / 构建 {report.app.build_version} / 版本 {report.app.marketing_version}",
        f"二进制：{Path(report.binary.path).name} / {report.binary.kind} / whole SHA256 {report.binary.sha256}",
    ]
    if report.binary.x86_64_slice_sha256:
        lines.append(f"x86_64 slice SHA256：{report.binary.x86_64_slice_sha256}")
    else:
        lines.append("x86_64 slice SHA256：未发现 x86_64 slice")
    lines.append(
        f"catalog：{'命中' if report.catalog.build_matched else '未命中'} build {report.catalog.build_version}，"
        f"targets {report.catalog.target_count}，Intel 覆盖 {'是' if report.catalog.intel_covered else '否'}"
    )
    if report.catalog.targets:
        feature_text = ", ".join(f"{item.feature}:{'/'.join(item.arches) or '-'}" for item in report.catalog.targets)
        lines.append(f"features：{feature_text}")
    lines.append(
        f"toolchain：CPU {report.host.machine}，macOS {report.host.macos_version}，"
        f"Python {report.host.python_version}，Swift probe {report.host.swift_probe.status}，"
        f"SDK 版本 {report.host.macos_sdk_version_probe.detail} (exitCode={report.host.macos_sdk_version_probe.exit_code})，"
        f"SDK 平台路径 probe {report.host.macos_sdk_platform_probe.status} (exitCode={report.host.macos_sdk_platform_probe.exit_code})"
    )
    lines.append(
        "结论：这是只读目录预检，非 Swift CLI dry-run，不代表补丁已安装或真实 Intel 实机已验证。"
    )
    return "\n".join(lines)


def emit_json(report: Report) -> None:
    print(json.dumps(report.to_jsonable(), ensure_ascii=False, indent=2, sort_keys=True))


def emit_error(error: PreflightError) -> None:
    print(json.dumps({"schemaVersion": JSON_SCHEMA_VERSION, "error": error.to_payload()}, ensure_ascii=False, indent=2, sort_keys=True))


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", default=DEFAULT_APP_PATH, help="要检查的 WeChat.app 路径")
    parser.add_argument("--config", default=DEFAULT_CONFIG_PATH, help="patches.json 路径")
    parser.add_argument("--summary", action="store_true", help="输出适合粘贴 issue 的中文摘要")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        report = build_report(Path(args.app), Path(args.config))
    except PreflightError as error:
        emit_error(error)
        return 1
    except OSError as error:
        emit_error(PreflightError("osError", error.__class__.__name__))
        return 1

    if args.summary:
        print(render_summary(report))
    else:
        emit_json(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
