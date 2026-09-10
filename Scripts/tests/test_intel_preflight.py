import hashlib
import importlib.util
import json
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "Scripts" / "intel-preflight.py"

spec = importlib.util.spec_from_file_location("intel_preflight", SCRIPT_PATH)
assert spec is not None and spec.loader is not None
intel_preflight = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = intel_preflight
spec.loader.exec_module(intel_preflight)


class IntelPreflightTests(unittest.TestCase):
    def test_thin_binary_report_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            slice_bytes = self._make_thin_macho(0x0100000C, payload_seed=0x11)
            binary_path = app_path / "Contents" / "Resources" / "wechat.dylib"
            binary_path.write_bytes(slice_bytes)
            config_path = self._write_config(root, build_version="269624")

            report = intel_preflight.build_report(app_path, config_path)

            self.assertEqual(report.binary.kind, "thin-arm64")
            self.assertEqual(report.binary.sha256, hashlib.sha256(slice_bytes).hexdigest())
            self.assertEqual(report.binary.x86_64_slice_sha256, None)
            self.assertEqual(report.catalog.build_matched, True)
            self.assertEqual(report.catalog.target_count, 2)
            self.assertEqual(report.catalog.intel_covered, True)
            self.assertEqual(report.catalog.targets[0].feature, "silent")
            self.assertEqual(report.catalog.targets[0].arches, ["arm64"])
            self.assertEqual(report.catalog.targets[1].feature, "block-update")
            self.assertEqual(report.catalog.targets[1].arches, ["x86_64"])
            self.assertIn("有 Intel catalog 覆盖", report.summary)
            self.assertIn("非 Swift CLI dry-run", report.summary)
            summary = intel_preflight.render_summary(report)
            self.assertIn("应用：WeChat.app / 构建 269624 / 版本 4.1.13.56", summary)
            self.assertIn("x86_64 slice SHA256：未发现 x86_64 slice", summary)
            self.assertIn("catalog：命中 build 269624，targets 2，Intel 覆盖 是", summary)
            self.assertIn("非 Swift CLI dry-run", summary)
            self.assertEqual(report.to_jsonable()["host"]["swiftProbe"]["status"], "ok")
            self.assertEqual(report.to_jsonable()["limitations"], ["只读目录预检", "不写入、不安装、不签名、不联网", "非 Swift CLI dry-run", "不代表真实 Intel 实机已验证"])
            self.assertEqual(report.to_jsonable()["app"]["path"], "WeChat.app")
            self.assertEqual(report.to_jsonable()["binary"]["path"], "wechat.dylib")
            self.assertEqual(report.to_jsonable()["catalog"]["path"], "patches.json")

            encoded = report.to_jsonable()
            self.assertEqual(encoded["schemaVersion"], 1)
            self.assertEqual(encoded["binary"]["sha256"], hashlib.sha256(slice_bytes).hexdigest())

    def test_fat32_binary_reports_x86_slice_hash(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            x86_slice = self._make_thin_macho(0x01000007, payload_seed=0x22)
            arm_slice = self._make_thin_macho(0x0100000C, payload_seed=0x33)
            fat = self._make_fat_binary([(0x01000007, x86_slice), (0x0100000C, arm_slice)], fat64=False)
            binary_path = app_path / "Contents" / "Resources" / "wechat.dylib"
            binary_path.write_bytes(fat)
            config_path = self._write_config(root, build_version="269624")

            report = intel_preflight.build_report(app_path, config_path)

            self.assertEqual(report.binary.kind, "fat32")
            self.assertEqual(report.binary.sha256, hashlib.sha256(fat).hexdigest())
            self.assertEqual(report.binary.x86_64_slice_sha256, hashlib.sha256(x86_slice).hexdigest())
            self.assertEqual([slice_.arch for slice_ in report.binary.slices], ["x86_64", "arm64"])
            self.assertEqual(report.binary.slices[0].offset, 256)
            self.assertEqual(report.binary.slices[1].offset, 1024)

    def test_fat64_binary_reports_x86_slice_hash(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            x86_slice = self._make_thin_macho(0x01000007, payload_seed=0x44)
            arm_slice = self._make_thin_macho(0x0100000C, payload_seed=0x55)
            fat = self._make_fat_binary([(0x01000007, x86_slice), (0x0100000C, arm_slice)], fat64=True)
            binary_path = app_path / "Contents" / "Resources" / "wechat.dylib"
            binary_path.write_bytes(fat)
            config_path = self._write_config(root, build_version="269624")

            report = intel_preflight.build_report(app_path, config_path)

            self.assertEqual(report.binary.kind, "fat64")
            self.assertEqual(report.binary.x86_64_slice_sha256, hashlib.sha256(x86_slice).hexdigest())
            self.assertEqual([slice_.arch for slice_ in report.binary.slices], ["x86_64", "arm64"])
            self.assertEqual(report.catalog.targets[0].entry_count, 1)

    def test_missing_app_and_missing_binary_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            config_path = self._write_config(root, build_version="269624")
            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(root / "Nope.app", config_path)
            self.assertEqual(ctx.exception.kind, "missingApp")

            app_path = self._make_app_bundle(root, build_version="269624")
            (app_path / "Contents" / "Resources" / "wechat.dylib").unlink()
            with self.assertRaises(intel_preflight.PreflightError) as ctx2:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx2.exception.kind, "missingBinary")

    def test_missing_info_plist_is_reported_before_containment(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            info_path = app_path / "Contents" / "Info.plist"
            info_path.unlink()
            config_path = self._write_config(root, build_version="269624")

            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx.exception.kind, "missingInfoPlist")

    def test_bundle_symlink_escape_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            outside = root / "outside.dylib"
            outside.write_bytes(self._make_thin_macho(0x0100000C, payload_seed=0x77))
            escaped = app_path / "Contents" / "Resources" / "wechat.dylib"
            if escaped.exists() or escaped.is_symlink():
                escaped.unlink()
            escaped.symlink_to(outside)
            config_path = self._write_config(root, build_version="269624")

            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx.exception.kind, "pathEscape")

    def test_config_validation_rejects_non_objects_and_bad_entries(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(self._make_thin_macho(0x0100000C, payload_seed=0x11))

            bad_root = root / "bad.json"
            bad_root.write_text(json.dumps([1, {"version": "269624", "targets": ["oops"]}], ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(app_path, bad_root)
            self.assertEqual(ctx.exception.kind, "invalidConfig")

            bad_target = root / "bad-target.json"
            bad_target.write_text(json.dumps([
                {"version": "269624", "targets": [{"entries": []}]}
            ], ensure_ascii=False), encoding="utf-8")
            with self.assertRaises(intel_preflight.PreflightError) as ctx2:
                intel_preflight.build_report(app_path, bad_target)
            self.assertEqual(ctx2.exception.kind, "invalidConfig")

    def test_catalog_loads_all_repository_builds_with_repeated_arch_entries(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            config_path = ROOT / "patches.json"
            versions = [item["version"] for item in json.loads(config_path.read_text(encoding="utf-8"))]
            app_path = self._make_app_bundle(root, build_version=versions[0])
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(self._make_thin_macho(0x0100000C, payload_seed=0x12))

            repeated = intel_preflight._validate_target_entries(  # type: ignore[attr-defined]
                [
                    {"arch": "arm64", "addr": "10", "expected": "11", "asm": "22"},
                    {"arch": "arm64", "addr": "20", "expected": "33", "asm": "44"},
                ],
                config_path=config_path,
                build_version=versions[0],
                target_index=0,
            )
            self.assertEqual(len(repeated), 2)

            for version in versions:
                report = intel_preflight.load_catalog_report(config_path, version)
                self.assertTrue(report.build_matched)
                self.assertGreater(report.target_count, 0)
                self.assertTrue(any(target.entry_count >= 1 for target in report.targets))

    def test_fat_binary_rejects_duplicate_overlap_and_cpu_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            x86_slice = self._make_thin_macho(0x01000007, payload_seed=0x22)
            arm_slice = self._make_thin_macho(0x0100000C, payload_seed=0x33)
            config_path = self._write_config(root, build_version="269624")

            duplicate = self._make_fat_binary([(0x01000007, x86_slice), (0x01000007, x86_slice)], fat64=False)
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(duplicate)
            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx.exception.kind, "duplicateSliceArch")

            overlap = self._make_fat_binary([(0x01000007, x86_slice), (0x0100000C, arm_slice)], fat64=False)
            overlap = bytearray(overlap)
            # Force the second slice to overlap the first one.
            struct.pack_into(">I", overlap, 8 + 20 + 8, 300)
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(bytes(overlap))
            with self.assertRaises(intel_preflight.PreflightError) as ctx2:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx2.exception.kind, "overlappingSlice")

            mismatch = bytearray(self._make_fat_binary([(0x01000007, x86_slice)], fat64=False))
            struct.pack_into("<I", mismatch, 256 + 4, 0x0100000C)
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(bytes(mismatch))
            with self.assertRaises(intel_preflight.PreflightError) as ctx3:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx3.exception.kind, "cpuMismatch")

    def test_fat_binary_rejects_slice_overlapping_header_or_table(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            config_path = self._write_config(root, build_version="269624")
            malformed = self._make_fat_binary_with_offsets(
                [(0x01000007, self._make_thin_macho(0x01000007, payload_seed=0x88), 24)],
                fat64=False,
            )
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(malformed)

            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx.exception.kind, "invalidFatSlice")
            self.assertIn("table", ctx.exception.message)

    def test_fat_binary_rejects_zero_slices(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            config_path = self._write_config(root, build_version="269624")
            malformed = bytearray(struct.pack(">II", 0xCAFEBABE, 0))
            malformed.extend(b"\0" * 64)
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(bytes(malformed))

            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.build_report(app_path, config_path)
            self.assertEqual(ctx.exception.kind, "invalidFat")
            self.assertIn("没有切片", ctx.exception.message)

    def test_duplicate_build_version_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            (app_path / "Contents" / "Resources" / "wechat.dylib").write_bytes(self._make_thin_macho(0x0100000C, payload_seed=0x66))
            config_path = root / "patches.json"
            config_path.write_text(
                json.dumps(
                    [
                        {
                            "version": "269624",
                            "targets": [
                                {"identifier": "revoke", "entries": [{"arch": "arm64", "addr": "10", "expected": "11", "asm": "22"}]}
                            ],
                        },
                        {
                            "version": "269624",
                            "targets": [
                                {"identifier": "update", "entries": [{"arch": "x86_64", "addr": "20", "expected": "33", "asm": "44"}]}
                            ],
                        },
                    ],
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )

            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.load_catalog_report(config_path, "269624")
            self.assertEqual(ctx.exception.kind, "invalidConfig")
            self.assertIn("重复", ctx.exception.message)

    def test_unsupported_macho_and_json_output(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            app_path = self._make_app_bundle(root, build_version="269624")
            binary_path = app_path / "Contents" / "Resources" / "wechat.dylib"
            binary_path.write_bytes(b"not mach-o")
            config_path = self._write_config(root, build_version="269624")

            with self.assertRaises(intel_preflight.PreflightError) as ctx:
                intel_preflight.analyze_binary(binary_path)
            self.assertEqual(ctx.exception.kind, "unsupportedMachO")

            binary_path.write_bytes(self._make_thin_macho(0x0100000C, payload_seed=0x66))
            report = intel_preflight.build_report(app_path, config_path)
            payload = json.dumps(report.to_jsonable(), ensure_ascii=False, sort_keys=True)
            parsed = json.loads(payload)
            self.assertEqual(parsed["schemaVersion"], 1)
            self.assertEqual(parsed["app"]["bundleIdentifier"], "com.tencent.xinWeChat")
            self.assertEqual(parsed["binary"]["kind"], "thin-arm64")

    def test_main_converts_oserror_to_json_error(self) -> None:
        original = intel_preflight.build_report
        try:
            def boom(_app_path: Path, _config_path: Path):
                raise OSError("boom")
            intel_preflight.build_report = boom  # type: ignore[assignment]
            exit_code = intel_preflight.main(["--app", "/tmp/WeChat.app", "--config", "/tmp/patches.json"])
            self.assertEqual(exit_code, 1)
        finally:
            intel_preflight.build_report = original  # type: ignore[assignment]

    def test_probe_command_redacts_paths_and_captures_exit_code(self) -> None:
        original = intel_preflight.subprocess.run

        class Completed:
            def __init__(self, stdout: str, returncode: int):
                self.stdout = stdout
                self.returncode = returncode

        try:
            def fake_run_failure(*_args, **_kwargs):
                raise intel_preflight.subprocess.CalledProcessError(
                    2,
                    ["xcrun"],
                    output="error loading /Users/PRIVATE_SENTINEL/toolchain\n",
                )

            intel_preflight.subprocess.run = fake_run_failure  # type: ignore[assignment]
            failure = intel_preflight._probe_command(["xcrun"], redact_output=False)  # type: ignore[attr-defined]
            self.assertEqual(failure.status, "error")
            self.assertEqual(failure.exit_code, 2)
            self.assertNotIn("/Users/PRIVATE_SENTINEL/toolchain", failure.detail)
            self.assertIn("[redacted]", failure.detail)

            def fake_run_success(*_args, **_kwargs):
                return Completed("toolchain at /Users/PRIVATE_SENTINEL/toolchain\n", 0)

            intel_preflight.subprocess.run = fake_run_success  # type: ignore[assignment]
            success = intel_preflight._probe_command(["swift"], redact_output=False)  # type: ignore[attr-defined]
            self.assertEqual(success.status, "ok")
            self.assertEqual(success.exit_code, 0)
            self.assertNotIn("/Users/PRIVATE_SENTINEL/toolchain", success.detail)
            self.assertIn("[redacted]", success.detail)
        finally:
            intel_preflight.subprocess.run = original  # type: ignore[assignment]

    def _make_app_bundle(self, root: Path, *, build_version: str) -> Path:
        app_path = root / "WeChat.app"
        info_path = app_path / "Contents" / "Info.plist"
        binary_dir = app_path / "Contents" / "Resources"
        binary_dir.mkdir(parents=True, exist_ok=True)
        info_path.parent.mkdir(parents=True, exist_ok=True)
        plist = {
            "CFBundleExecutable": "WeChat",
            "CFBundleShortVersionString": "4.1.13.56",
            "CFBundleVersion": build_version,
            "CFBundleIdentifier": "com.tencent.xinWeChat",
        }
        with info_path.open("wb") as fh:
            plistlib.dump(plist, fh)
        (binary_dir / "wechat.dylib").write_bytes(self._make_thin_macho(0x0100000C, payload_seed=0x10))
        return app_path

    def _write_config(self, root: Path, *, build_version: str) -> Path:
        config = [
            {
                "version": build_version,
                "targets": [
                    {
                        "identifier": "revoke",
                        "entries": [
                            {"arch": "arm64", "addr": "10", "expected": "11", "asm": "22"}
                        ],
                    },
                    {
                        "identifier": "update",
                        "entries": [
                            {"arch": "x86_64", "addr": "20", "expected": "33", "asm": "44"}
                        ],
                    },
                ],
            }
        ]
        path = root / "patches.json"
        path.write_text(json.dumps(config, ensure_ascii=False, indent=2), encoding="utf-8")
        return path

    def _make_fat_binary(self, slices: list[tuple[int, bytes]], *, fat64: bool) -> bytes:
        return self._make_fat_binary_with_offsets(
            [(cputype, data, offset) for (cputype, data), offset in zip(slices, [256, 1024], strict=False)],
            fat64=fat64,
        )

    def _make_fat_binary_with_offsets(self, slices: list[tuple[int, bytes, int]], *, fat64: bool) -> bytes:
        offsets = [256, 1024]
        header = bytearray()
        if fat64:
            header.extend(struct.pack(">II", 0xCAFEBABF, len(slices)))
            for cputype, data, offset in slices:
                header.extend(struct.pack(">IIQQII", cputype, 0, offset, len(data), 0, 0))
        else:
            header.extend(struct.pack(">II", 0xCAFEBABE, len(slices)))
            for cputype, data, offset in slices:
                header.extend(struct.pack(">IIIII", cputype, 0, offset, len(data), 0))

        blob = bytearray(header)
        while slices and len(blob) < slices[0][2]:
            blob.append(0)
        for index, (_, data, offset) in enumerate(slices):
            if len(blob) < offset:
                blob.extend(b"\0" * (offset - len(blob)))
            blob.extend(data)
            if index + 1 < len(slices):
                next_offset = slices[index + 1][2]
                if len(blob) < next_offset:
                    blob.extend(b"\0" * (next_offset - len(blob)))
        return bytes(blob)

    def _make_thin_macho(self, cputype: int, *, payload_seed: int) -> bytes:
        total_size = 512
        header = bytearray(struct.pack("<IIIIIIII", 0xFEEDFACF, cputype, 0, 0x2, 1, 72, 0, 0))
        segment = bytearray()
        segment.extend(struct.pack("<II", 0x19, 72))
        segment.extend(b"__TEXT\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
        segment.extend(struct.pack("<QQQQIIII", 0, total_size, 0, total_size, 7, 5, 0, 0))
        blob = header + segment
        while len(blob) < total_size:
            blob.append((payload_seed + len(blob)) % 256)
        return bytes(blob)


if __name__ == "__main__":
    unittest.main()
