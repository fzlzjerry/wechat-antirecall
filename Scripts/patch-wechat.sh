#!/bin/bash
#
# patch-wechat.sh — 零参数一键打补丁
#
# 流程：编译 release → 退出微信 → 判断当前微信是否受支持 →
#       三种 dry-run 校验（不修改文件）→ 全部通过后直接安装
#       runtime-tip（自定义提示）+ block-update（屏蔽自动更新）。
#
# 真正打补丁会修改 /Applications/WeChat.app，可能弹提权窗口。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/wechat-antirecall"
APP="${WECHAT_APP:-/Applications/WeChat.app}"
# 默认提示语；若用户已配过自己的提示语（tip-phrase get 能取到），则保留用户的。
DEFAULT_TIP="已拦截 {from} 于 {time} 撤回：{content}"

step() { printf '\n==> %s\n' "$*"; }

if [[ ! -d "$APP" ]]; then
  echo "未找到 WeChat.app: $APP" >&2
  echo "用环境变量 WECHAT_APP=/path/WeChat.app 指定，例如：" >&2
  echo "  WECHAT_APP=/Users/me/Downloads/WeChatMac_4.1.12/WeChat.app bash Scripts/patch-wechat.sh" >&2
  exit 1
fi

# 真打补丁需要交互式提权（osascript 可能弹窗）。
if [[ ! -t 0 ]]; then
  echo "打补丁需要交互式终端（install 可能弹提权窗口）。请在终端里手动运行本脚本。" >&2
  exit 1
fi

step "[1/5] 编译 release"
swift build -c release

step "[2/5] 退出微信"
if pgrep -x "WeChat" >/dev/null 2>&1; then
  echo "微信正在运行，尝试退出…"
  osascript -e 'tell application "WeChat" to quit' 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x "WeChat" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x "WeChat" >/dev/null 2>&1; then
    echo "优雅退出超时，强制结束 WeChat 进程…"
    pkill -x "WeChat" 2>/dev/null || true
    sleep 1
  fi
else
  echo "微信未运行。"
fi

step "[3/5] 判断当前微信是否受支持"
# versions --json 里有 app.installedBuild 和 catalog[]；用 build 去匹配是否在 catalog 里。
VERSIONS_JSON="$("$BIN" versions --json --app "$APP")"
BUILD=$(printf '%s' "$VERSIONS_JSON" | python3 -c "import json,sys;print(json.load(sys.stdin)['app']['installedBuild'])")
SUPPORTED=$(printf '%s' "$VERSIONS_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=d['app']['installedBuild']
print('yes' if any(c['build']==b for c in d['catalog']) else 'no')
")
RUNTIME_TIP=$(printf '%s' "$VERSIONS_JSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
b=d['app']['installedBuild']
print('yes' if any(c['build']==b and c.get('runtimeTipSupported') for c in d['catalog']) else 'no')
")
echo "当前微信构建号: $BUILD"
echo "受支持: $SUPPORTED"
echo "runtime-tip(自定义提示)可用: $RUNTIME_TIP"

if [[ "$SUPPORTED" != "yes" ]]; then
  echo
  echo "当前微信构建号（$BUILD）暂不受支持，已中止。请先「检查更新→拉取最新补丁数据」。" >&2
  exit 1
fi
if [[ "$RUNTIME_TIP" != "yes" ]]; then
  echo
  echo "当前构建号（$BUILD）不支持 runtime-tip，无法安装自定义提示。已中止。" >&2
  echo "可改用静默防撤回：手动执行 $BIN install --app \"$APP\"" >&2
  exit 1
fi

step "[4/5] dry-run 校验（不修改文件）"
"$BIN" install --dry-run --runtime-tip --block-update --app "$APP"
echo
echo "dry-run 通过：每个补丁点原始字节都与 patches.json 匹配。"

step "[5/5] 打补丁（--runtime-tip --block-update）"
# 提示语：保留用户已有的；没有则写默认值（普通用户权限，绝不提权）。
if ! "$BIN" tip-phrase get 2>/dev/null | grep -q '^Phrase: .\+'; then
  echo "未检测到提示语，写入默认值: $DEFAULT_TIP"
  "$BIN" tip-phrase set "$DEFAULT_TIP"
fi

# 先普通用户身份安装（bundle 常归当前用户所有，多数无需密码）；失败再 sudo 提权。
INSTALL_ARGS=(install --runtime-tip --block-update --app "$APP")
if ! "$BIN" "${INSTALL_ARGS[@]}"; then
  echo
  echo "普通用户身份安装失败，尝试提权（会弹管理员密码窗口）…"
  sudo "$BIN" "${INSTALL_ARGS[@]}"
fi

echo
echo "==> 安装完成。请重新打开微信验证："
echo "    1) 让另一个账号发一条消息再撤回，确认原消息保留且显示自定义提示。"
echo "    2) 微信菜单「检查更新」应被屏蔽（block-update 生效）。"
echo
echo "    如微信打开后点不动 / 闪退：系统设置 → 隐私与安全性 → 完全磁盘访问权限，"
echo "    删掉旧的 WeChat 重新添加 /Applications/WeChat.app，再重开微信。"
