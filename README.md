# wechat-antirecall

macOS 微信 4 防撤回补丁工具。参考 WeChatTweak 的版本配置和 Mach-O 地址补丁思路，默认只处理 `revoke` 目标，版本未知时拒绝写入。

## 更新
- 2026.5.11 增加 268575（微信 4.1.9） 多开 

## 支持的版本

| 构建号 | 架构 | 补丁目标 |
|--------|------|----------|
| 31927, 31960, 32281, 32288, 34371 | arm64 | `Contents/MacOS/WeChat` |
| 34817 | x86_64 | `Contents/MacOS/WeChat` |
| 36559 | x86_64 | `Contents/Frameworks/wechat.dylib` |
| 268575 | arm64 | `multiInstance` 在 `Contents/MacOS/WeChat` |
| 268575, 268596, 268597 | arm64 | `Contents/Resources/wechat.dylib` |
| 268597 | arm64 | 自定义撤回提示运行时 `--runtime-tip` |

> **268575 / 268596 / 268597（微信 4.1.9）** 的补丁目标在 `wechat.dylib`，不是主二进制。该 dylib 不会被 `codesign --deep` 自动作为嵌套代码处理，工具会先单独重签被 patch 的 dylib，再重签整个 app，否则运行到撤回消息所在代码页时 macOS 会以 `Code Signature Invalid` 杀掉微信。

> **268575（微信 4.1.9）** 的 `multiInstance` 目标在主二进制 `Contents/MacOS/WeChat`。其中 dylib 不会被 `codesign --deep` 自动作为嵌套代码处理，工具会先单独重签被 patch 的 dylib，再重签整个 app，否则运行到撤回消息所在代码页时 macOS 会以 `Code Signature Invalid` 杀掉微信

## 补丁模式

**静默模式（默认）**：直接跳过 `revokemsg` 系统消息解析分支，撤回的消息保持原样显示，无任何提示。

**提示模式（`--with-tip`）**：不跳过 `revokemsg` 解析，让微信继续读取 `replacemsg` 撤回提示，同时把撤回包里的 `newmsgid` 清零，阻止微信按原消息 SvrID 删除已有消息。效果与 BetterWX/WeChatTweak 的"保留提示、阻断删除"策略一致。

**自定义撤回提示短语（`tip-phrase` + `--runtime-tip`）**：提供 X1a0He 风格的短语配置入口，支持 `{from}` 占位符和本地预览。`tip-phrase` 写入当前登录用户的 WeChat 容器偏好文件，请用普通用户执行，不要用 `sudo`。`--runtime-tip` 会把运行时 dylib 安装到 `Contents/Resources`，并给 `wechat.dylib` 注入 `LC_LOAD_DYLIB`，让撤回提示改用配置短语；目前只支持构建号 `268597`。

**无限多开（`--multi-instance`）**：绕过微信 4.1.9 进程互斥检查，允许同时启动多个客户端实例（当前仅 `268575` 提供该目标）。

<u>使用方法：选择带有多开参数的命令安装后，使用命令 `open -n /Applications/WeChat.app` 或者 使用多开启动器： [WeChatMulti](https://github.com/loohalh/WeChatMulti)</u>


**屏蔽自动更新（`--block-update` / `--update-only`）**：针对微信 4.1.9 的 `XAppUpdateManager`，屏蔽 `startUpdater`、`startBackgroundUpdatesCheck:`、`checkForUpdates:`、`enableAutoUpdate:` 等入口，并让 `automaticallyDownloadsUpdates`、`canCheckForUpdate` 返回 `false`。

## 用法

**第一步**：查看当前微信版本是否已支持。

```bash
swift run wechat-antirecall versions --app /Applications/WeChat.app
```

**第二步**：dry-run 确认补丁命中。

```bash
# 静默模式
swift run wechat-antirecall install --dry-run --app /Applications/WeChat.app

# 提示模式
swift run wechat-antirecall install --with-tip --dry-run --app /Applications/WeChat.app

# 提示模式 + 多开
swift run wechat-antirecall install --with-tip --multi-instance --dry-run --app /Applications/WeChat.app

# 只屏蔽自动更新
swift run wechat-antirecall install --update-only --dry-run --app /Applications/WeChat.app

# 防撤回并屏蔽自动更新
swift run wechat-antirecall install --with-tip --block-update --dry-run --app /Applications/WeChat.app

# 防撤回+屏蔽自动更新+多开
swift run wechat-antirecall install --with-tip --block-update --multi-instance --dry-run --app /Applications/WeChat.app
```

**可选步骤**：配置自定义撤回提示短语。

短语最长 120 个字符，不能包含换行。`{from}` 会在运行时替换成发送者备注或昵称。未配置时默认显示 `已拦截一条撤回消息`。

```bash
# 查看当前短语
swift run wechat-antirecall tip-phrase get

# 预览短语效果，不写入配置
swift run wechat-antirecall tip-phrase preview "已拦截 {from} 撤回的一条消息" --from 张三

# 写入 WeChat 容器偏好配置。不要用 sudo 执行。
swift run wechat-antirecall tip-phrase set "已拦截 {from} 撤回的一条消息"

# 恢复默认短语
swift run wechat-antirecall tip-phrase reset
```

配置位置：

```text
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences/com.tencent.xinWeChat.plist
```

修改短语后请完全退出并重新打开微信。已启动的 WeChat 进程可能持有旧的偏好缓存，重启后 runtime 会重新读取容器 plist。

自定义短语要实际显示在聊天里，还需要安装运行时 hook。运行时 dylib 不会由普通 `swift run` 自动放到 release 目录，先构建 release，再做 dry-run：

```bash
swift build -c release
.build/release/wechat-antirecall install --runtime-tip --dry-run --app /Applications/WeChat.app
```

`--runtime-tip` 会自动选择提示模式，不需要再额外加 `--with-tip`。

**第三步**：确认无误后安装。

安装前请先完全退出微信。不要在微信仍运行时写入补丁；否则已启动的进程可能在执行到被修改过的代码页时被 macOS 以 `Code Signature Invalid` 终止。

```bash
swift build -c release

# 静默模式
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app

# 提示模式
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app

# 自定义撤回提示短语（仅 268597）
sudo .build/release/wechat-antirecall install --runtime-tip --app /Applications/WeChat.app

# 提示模式 + 多开
sudo .build/release/wechat-antirecall install --with-tip --multi-instance --app /Applications/WeChat.app

# 只屏蔽自动更新
sudo .build/release/wechat-antirecall install --update-only --app /Applications/WeChat.app

# 提示模式防撤回 + 屏蔽自动更新 + 多开
sudo .build/release/wechat-antirecall install --with-tip --block-update --multi-instance --app /Applications/WeChat.app
```

如果看到类似：

```
error: "wechat.dylib" couldn't be copied because you don't have permission to access "Resources".
```

说明当前命令没有权限在 `/Applications/WeChat.app/Contents/Resources` 里创建备份/写入补丁。请不要用 `swift run ... install` 直接安装，先 `swift build -c release`，再使用上面的 `sudo .build/release/wechat-antirecall ...` 命令。`--no-backup` 不能解决这个权限问题，后续 patch 和重签名仍然需要写入 app bundle。

如果已经使用 `sudo .build/release/...` 仍然看到这条英文错误，通常是在运行旧版工具；旧实现使用 `FileManager.copyItem` 在 `Resources` 内复制备份，部分环境会在这里直接抛出 Cocoa 权限错误。请拉取/构建新版后重试。新版会先做真实写入探针，并在失败时输出当前有效用户 ID。也可以先用下面命令确认 sudo 是否真的能写入目标目录：

```bash
sudo sh -c 'id -u; touch /Applications/WeChat.app/Contents/Resources/.wechat-antirecall-write-test && rm /Applications/WeChat.app/Contents/Resources/.wechat-antirecall-write-test'
```

如果上面的命令第一行输出 `0`，但 `touch` 仍然报 `Operation not permitted`，说明 `sudo` 已生效，写入被 macOS 隐私权限拦截。到 **System Settings → Privacy & Security → App Management** 中给当前运行命令的应用开启权限，例如 Terminal、iTerm、VS Code、Cursor 或 Codex；必要时也在 **Full Disk Access** 中开启同一个应用。改完后退出并重新打开终端，再重新运行 release 安装命令。

如果工具提示 `WeChat 仍在运行`，请先退出微信后再安装或恢复。这个检查会阻止在运行中的 app bundle 上打补丁，避免旧进程因为代码签名页校验失败而崩溃。

安装时默认在被 patch 的二进制旁边创建备份，文件名格式：

```
wechat.dylib.wechat-antirecall-backup-20260505-143000
```

### 重新安装 / 切换模式

如果已安装旧补丁（例如在撤回时闪退，或想从静默切换到提示模式），加 `--no-backup` 直接覆盖：

```bash
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --runtime-tip --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --with-tip --multi-instance --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --update-only --app /Applications/WeChat.app --no-backup
```

### 验证签名

```bash
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/libWeChatAntiRecallRuntime.dylib
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/wechat.dylib
codesign --verify --deep --strict --verbose=2 /Applications/WeChat.app
```

### 从备份恢复

```bash
sudo .build/release/wechat-antirecall restore \
  --binary Contents/Resources/wechat.dylib \
  --backup /Applications/WeChat.app/Contents/Resources/wechat.dylib.wechat-antirecall-backup-YYYYMMDD-HHMMSS \
  --app /Applications/WeChat.app
```

恢复 `wechat.dylib` 备份后，runtime 的 load command 会随备份一起消失；`Contents/Resources/libWeChatAntiRecallRuntime.dylib` 即使留在目录里也不会再被加载。

## 补丁配置格式

`patches.json` 配置来自 WeChatTweak / 社区 fork 的 Mach-O patch 思路，并补充当前微信 4 的防撤回和屏蔽更新目标。

```json
{
  "version": "36559",
  "targets": [
    {
      "identifier": "revoke",
      "binary": "Contents/Frameworks/wechat.dylib",
      "entries": [
        {
          "arch": "x86_64",
          "addr": "4B51260",
          "expected": "B001000000C3",
          "asm": "B801000000C3"
        }
      ]
    }
  ]
}
```

`expected` 支持单个十六进制字符串或字符串数组；提示模式会同时接受"原始字节"和"已装过静默补丁的字节"，支持直接在两种模式间切换而无需先恢复备份。

`multiInstance` 目标目前只覆盖 `268575`（微信 4.1.9），当前提供 arm64 地址（主二进制 `Contents/MacOS/WeChat`）。

`update` 目标目前覆盖 `268575` / `268596` / `268597`（微信 4.1.9 arm64），核心是让更新入口提前返回，并把更新权限相关 getter 固定为 `false`。

显式请求 `--with-tip` 或 `--block-update` 时，当前构建号必须提供对应的 `revoke-tip` 或 `update` 目标；工具会拒绝静默降级成其他模式。

## 参考

- [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak-macOS) — upstream，包含 `Block message recall` 功能
- [tanranv5/WeChatTweak](https://github.com/tanranv5/WeChatTweak) — 社区 fork，补充较新 x86_64 配置，引入 `binary` 字段
- [zetaloop/BetterWX](https://github.com/zetaloop/BetterWX) — Windows 版微信 4 的同类提示模式补丁
- [X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin) — 感谢该项目为自定义撤回提示短语功能提供实现思路
- [naizhao/WeChatTweak](https://github.com/naizhao/WeChatTweak/blob/master/MAINTAINING.md) — 社区 fork, 维护指南

## 友链

- [linux.do](https://linux.do) — 新的理想型社区
