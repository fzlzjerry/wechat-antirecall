# wechat-antirecall

macOS 微信 4 防撤回补丁工具。工具只会处理 `patches.json` 中已知的
WeChat 构建号；遇到未知版本会拒绝写入，避免猜地址造成损坏。

> 使用前建议先读完“快速开始”和“恢复备份”。安装会修改
> `/Applications/WeChat.app` 内的二进制并重新签名，务必先完全退出微信。

## 快速开始

最安全的流程是：先确认版本，再 dry-run，最后用 release 可执行文件安装。

```bash
swift run wechat-antirecall versions --app /Applications/WeChat.app
swift run wechat-antirecall install --with-tip --dry-run --app /Applications/WeChat.app
swift build -c release
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app
```

安装时会在被修改的二进制旁边自动创建备份，例如：

```text
wechat.dylib.wechat-antirecall-backup-20260505-143000
```

恢复命令见 [恢复备份](#恢复备份)。

## 支持版本

| 构建号 | 架构 | 支持能力 | 补丁目标 |
| --- | --- | --- | --- |
| 31927, 31960, 32281, 32288, 34371 | arm64 | 静默防撤回 | `Contents/MacOS/WeChat` |
| 34817 | x86_64 | 静默防撤回 | `Contents/MacOS/WeChat` |
| 36559 | x86_64 | 静默防撤回 | `Contents/Frameworks/wechat.dylib` |
| 268575 | arm64 | 静默防撤回、提示模式、多开、屏蔽更新 | `Contents/MacOS/WeChat`、`Contents/Resources/wechat.dylib` |
| 268596 | arm64 | 静默防撤回、提示模式、屏蔽更新 | `Contents/Resources/wechat.dylib` |
| 268597 | arm64 | 静默防撤回、提示模式、自定义提示、屏蔽更新 | `Contents/Resources/wechat.dylib` |
| 268599 | arm64 | 静默防撤回、提示模式、自定义提示、屏蔽更新 | `Contents/Resources/wechat.dylib` |

微信 4.1.9 的防撤回和屏蔽更新补丁目标在
`Contents/Resources/wechat.dylib`，不是主二进制。工具会先单独重签被
patch 的 dylib，再重签整个 app，避免运行到被修改代码页时触发
`Code Signature Invalid`。

## 选择模式

- **静默防撤回**：默认模式。不显示撤回提示，原消息保留在聊天中。
- **提示模式**：加 `--with-tip`。保留微信原本的撤回提示，同时阻止删除原消息。
- **自定义提示**：加 `--runtime-tip`。支持构建号 `268597`、`268599`，会安装
  `libWeChatAntiRecallRuntime.dylib` 并注入 `LC_LOAD_DYLIB`。
- **无限多开**：加 `--multi-instance`。当前仅构建号 `268575` 支持。
- **屏蔽更新**：加 `--block-update`。如果只想屏蔽更新，不改防撤回，用
  `--update-only`。

`--runtime-tip` 会自动启用提示模式，不需要再加 `--with-tip`。
`--update-only` 不能与 `--with-tip`、`--runtime-tip`、`--multi-instance`
同时使用。

多开安装完成后，可以用下面命令启动新实例：

```bash
open -n /Applications/WeChat.app
```

也可以使用多开启动器：[WeChatMulti](https://github.com/loohalh/WeChatMulti)。

## 标准安装流程

### 1. 检查当前微信

```bash
swift run wechat-antirecall versions --app /Applications/WeChat.app
```

如果输出 `current WeChat build is not supported by patches.json`，不要继续安装。

### 2. dry-run

dry-run 不会改文件，用来确认补丁地址能命中。

```bash
swift run wechat-antirecall install --dry-run --app /Applications/WeChat.app
swift run wechat-antirecall install --with-tip --dry-run --app /Applications/WeChat.app
swift run wechat-antirecall install --with-tip --block-update --dry-run --app /Applications/WeChat.app
swift run wechat-antirecall install --update-only --dry-run --app /Applications/WeChat.app
```

需要多开时：

```bash
swift run wechat-antirecall install --with-tip --multi-instance --dry-run --app /Applications/WeChat.app
swift run wechat-antirecall install --with-tip --block-update --multi-instance --dry-run --app /Applications/WeChat.app
```

### 3. 安装

安装前请先完全退出微信。不要在微信仍运行时写入补丁。

```bash
swift build -c release
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app
```

常用安装组合：

```bash
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app
sudo .build/release/wechat-antirecall install --with-tip --block-update --app /Applications/WeChat.app
sudo .build/release/wechat-antirecall install --update-only --app /Applications/WeChat.app
sudo .build/release/wechat-antirecall install --with-tip --multi-instance --app /Applications/WeChat.app
```

`patch` 是 `install` 的别名。完整参数可以运行：

```bash
swift run wechat-antirecall help
```

## 自定义撤回提示

自定义提示由两部分组成：

1. `tip-phrase` 写入当前用户的微信容器偏好配置。
2. `install --runtime-tip` 把运行时 hook 安装进 WeChat app。

`tip-phrase` 必须用普通用户执行，不要加 `sudo`。

```bash
swift run wechat-antirecall tip-phrase get
swift run wechat-antirecall tip-phrase preview "已拦截 {from} 于 {time} 撤回的一条消息" --from 张三
swift run wechat-antirecall tip-phrase set "已拦截 {from} 于 {time} 撤回的一条消息"
swift run wechat-antirecall tip-phrase reset
```

短语规则：

- 最长 120 个字符。
- 不能包含换行。
- 不能包含 CDATA 结束标记 `]]>`。
- `{from}` 会替换成发送者备注或昵称。
- `{time}` 会替换成撤回时间，格式为 `HH:mm`。
- 未配置时默认显示 `已拦截一条撤回消息`。

配置文件位置：

```text
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences/com.tencent.xinWeChat.plist
```

安装运行时 hook：

```bash
swift build -c release
.build/release/wechat-antirecall install --runtime-tip --dry-run --app /Applications/WeChat.app
sudo .build/release/wechat-antirecall install --runtime-tip --app /Applications/WeChat.app
```

`268599` 的 runtime hook 会先确认 XML 是 `<revokemsg>` 撤回事件，再读取和
改写撤回提示字段。视频、链接等非撤回 XML 不会进入撤回消息字段读取路径。

修改短语后请完全退出并重新打开微信。已启动的 WeChat 进程可能持有旧的
偏好缓存，重启后 runtime 会重新读取容器 plist。

### 调试探针

撤回调试探针默认关闭。只有在需要继续分析撤回 XML 或消息元数据时再打开。

```bash
swift run wechat-antirecall tip-phrase probe get
swift run wechat-antirecall tip-phrase probe on
swift run wechat-antirecall tip-phrase probe off
```

`probe on` 会把 `msgType`、`newmsgid`、撤回提示和 XML 片段写入
macOS Console。日志可能包含聊天相关元数据，收集完请及时关闭。

## 重新安装或切换模式

如果已经安装过旧补丁，想从静默模式切到提示模式，或重新安装 runtime，可以加
`--no-backup` 覆盖当前补丁：

```bash
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --runtime-tip --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --update-only --app /Applications/WeChat.app --no-backup
```

`--no-backup` 只是不再创建新备份，不能绕过权限、签名或 App Management 限制。

## 验证签名

微信 4.1.9 的常规防撤回或屏蔽更新：

```bash
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/wechat.dylib
codesign --verify --deep --strict --verbose=2 /Applications/WeChat.app
```

旧版本如果 patch 的是主二进制或 `Contents/Frameworks/wechat.dylib`，请把第一条命令
换成对应的补丁目标。

安装 `--runtime-tip` 后可以额外检查 runtime dylib：

```bash
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/libWeChatAntiRecallRuntime.dylib
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/wechat.dylib
codesign --verify --deep --strict --verbose=2 /Applications/WeChat.app
```

## 恢复备份

恢复前请先退出微信。

```bash
sudo .build/release/wechat-antirecall restore \
  --binary Contents/Resources/wechat.dylib \
  --backup /Applications/WeChat.app/Contents/Resources/wechat.dylib.wechat-antirecall-backup-YYYYMMDD-HHMMSS \
  --app /Applications/WeChat.app
```

旧版本如果补丁目标是主二进制，改用：

```bash
sudo .build/release/wechat-antirecall restore \
  --binary Contents/MacOS/WeChat \
  --backup /Applications/WeChat.app/Contents/MacOS/WeChat.wechat-antirecall-backup-YYYYMMDD-HHMMSS \
  --app /Applications/WeChat.app
```

恢复 `wechat.dylib` 备份后，runtime 的 load command 会随备份一起消失。
`Contents/Resources/libWeChatAntiRecallRuntime.dylib` 即使还在目录里，也不会再被加载。

## 故障排查

### 权限不足

如果看到类似错误：

```text
error: "wechat.dylib" couldn't be copied because you don't have permission to access "Resources".
```

不要直接用 `swift run ... install` 安装。请先构建 release，再用 `sudo`
执行 `.build/release/wechat-antirecall`。

```bash
swift build -c release
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app
```

`--no-backup` 不能解决权限问题，后续 patch 和重签名仍然需要写入 app bundle。

### sudo 仍然写不进去

先确认 `sudo` 是否真的能写目标目录：

```bash
sudo sh -c 'id -u; touch /Applications/WeChat.app/Contents/Resources/.wechat-antirecall-write-test && rm /Applications/WeChat.app/Contents/Resources/.wechat-antirecall-write-test'
```

如果第一行输出 `0`，但 `touch` 仍然报 `Operation not permitted`，通常是
macOS 隐私权限拦截。到：

- `System Settings -> Privacy & Security -> App Management`
- 必要时再到 `Full Disk Access`

给当前运行命令的应用授权，例如 Terminal、iTerm、VS Code、Cursor 或 Codex。
改完后退出并重新打开终端，再重新执行安装命令。

### 微信仍在运行

工具提示 `WeChat 仍在运行` 时，请先完全退出微信再安装或恢复。这个检查是为了
避免旧进程在执行到被修改代码页时被 macOS 以 `Code Signature Invalid` 终止。

### 找不到 runtime dylib

如果 `--runtime-tip` 提示找不到 `libWeChatAntiRecallRuntime.dylib`，先运行：

```bash
swift build -c release
```

也可以显式指定 dylib：

```bash
sudo .build/release/wechat-antirecall install --runtime-dylib .build/release/libWeChatAntiRecallRuntime.dylib --app /Applications/WeChat.app
```

## 维护 patches.json

`patches.json` 来自 WeChatTweak / 社区 fork 的 Mach-O patch 思路，并补充了
微信 4 的防撤回、提示模式、多开和屏蔽更新目标。

示例：

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

说明：

- `binary` 省略时默认是 `Contents/MacOS/WeChat`。
- `expected` 支持单个十六进制字符串或字符串数组。
- 提示模式会同时接受原始字节和已安装静默补丁的字节，方便直接切换模式。
- 显式请求 `--with-tip` 或 `--block-update` 时，当前构建号必须提供
  `revoke-tip` 或 `update` 目标；工具不会静默降级。

## 参考

- [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak-macOS) - upstream，包含 `Block message recall` 功能
- [tanranv5/WeChatTweak](https://github.com/tanranv5/WeChatTweak) - 社区 fork，补充较新 x86_64 配置，引入 `binary` 字段
- [zetaloop/BetterWX](https://github.com/zetaloop/BetterWX) - Windows 版微信 4 的同类提示模式补丁
- [X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin) - 自定义撤回提示短语功能参考
- [naizhao/WeChatTweak](https://github.com/naizhao/WeChatTweak/blob/master/MAINTAINING.md) - 社区 fork，维护指南

## 友链

- [linux.do](https://linux.do) - 新的理想型社区
