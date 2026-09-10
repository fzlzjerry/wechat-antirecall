#!/usr/bin/env python3
"""只构建并运行合成夹具；不启动、注入、签名或修改微信。"""
from __future__ import annotations

import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent


def run(args: list[str | Path], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(arg) for arg in args], cwd=ROOT, env=env,
        capture_output=True, text=True, timeout=120,
    )
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    result.check_returncode()
    return result


def main() -> None:
    if platform.system() != "Darwin" or platform.machine() != "x86_64":
        raise SystemExit("需要原生 Intel x86_64 macOS；本脚本不声称验证 arm64/Rosetta")
    # 不将 Agent 密钥或 DYLD 配置传给测试子进程。
    env = {key: os.environ[key] for key in ("HOME", "PATH", "TMPDIR", "DEVELOPER_DIR", "SDKROOT") if key in os.environ}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    with tempfile.TemporaryDirectory(prefix="wechat-intel-selftest-") as directory:
        out = Path(directory)
        fixture = out / "fixtures.o"
        run(["xcrun", "clang", "-arch", "x86_64", "-c", ROOT / "fixtures.S", "-o", fixture], env)
        common = ["xcrun", "clang++", "-arch", "x86_64", "-std=c++17", "-Wall", "-Wextra", "-Werror", "-g"]
        configs = {
            "debug": ["-O0"],
            "release": ["-O2", "-DNDEBUG"],
            "sanitized": ["-O1", "-fsanitize=address,undefined", "-fno-sanitize-recover=all"],
        }
        for name, flags in configs.items():
            binary = out / name
            run(common + flags + [
                "-Wno-unused-const-variable", "-DRTI_SELFTEST",
                ROOT / "RuntimeTipIntel.mm", ROOT / "runtime_test.cpp", fixture,
                "-framework", "Foundation", "-o", binary,
            ], env)
            result = run([binary], env)
            if "PASS: actual runtime installer/wrapper: 100 cases" not in result.stdout:
                raise RuntimeError("缺少完整自测结果")
            print(f"PASS: {name}")
        for _ in range(5):
            run([out / "release"], env)
        # 编译真实构造函数，并在非微信进程、非目标路径加载，必须拒绝安装 hook。
        payload = out / "RuntimeTipIntel.payload"
        run(common + [
            "-O2", "-dynamiclib", ROOT / "RuntimeTipIntel.mm", "-framework", "Foundation",
            "-Wl,-install_name,@loader_path/RuntimeTipIntel.dylib", "-o", payload,
        ], env)
        result = run([
            sys.executable, "-c",
            "import ctypes,sys; ctypes.CDLL(sys.argv[1]); print('dlopen returned safely')",
            payload,
        ], env)
        refusal = "refused: runtime image outside exact experiment Resources path"
        if result.stderr.count(refusal) != 1 or "hook installed;" in result.stderr:
            raise RuntimeError("错误路径保护没有明确拒绝")
        print("PASS: production constructor wrong-path rejection")
    print("PASS: all synthetic tests; no WeChat process was launched or modified")


if __name__ == "__main__":
    main()
