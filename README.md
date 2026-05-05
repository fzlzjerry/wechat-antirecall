# wechat-antirecall

macOS 微信 4 防撤回补丁工具。参考 WeChatTweak 的版本配置和 Mach-O 地址补丁思路，默认只处理 `revoke` 目标，版本未知时拒绝写入。

## 支持的版本

| 构建号 | 架构 | 补丁目标 |
|--------|------|----------|
| 31927, 31960, 32281, 32288, 34371 | arm64 | `Contents/MacOS/WeChat` |
| 34817 | x86_64 | `Contents/MacOS/WeChat` |
| 36559 | x86_64 | `Contents/Frameworks/wechat.dylib` |
| 268575 | arm64 | `Contents/Resources/wechat.dylib` |

> **268575（微信 4.1.9）** 的补丁目标在 `wechat.dylib`，不是主二进制。该 dylib 不会被 `codesign --deep` 自动作为嵌套代码处理，工具会先单独重签被 patch 的 dylib，再重签整个 app，否则运行到撤回消息所在代码页时 macOS 会以 `Code Signature Invalid` 杀掉微信。

## 补丁模式

**静默模式（默认）**：直接跳过 `revokemsg` 系统消息解析分支，撤回的消息保持原样显示，无任何提示。

**提示模式（`--with-tip`）**：不跳过 `revokemsg` 解析，让微信继续读取 `replacemsg` 撤回提示，同时把撤回包里的 `newmsgid` 清零，阻止微信按原消息 SvrID 删除已有消息。效果与 BetterWX/WeChatTweak 的"保留提示、阻断删除"策略一致。

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
```

**第三步**：确认无误后安装。

```bash
swift build -c release

# 静默模式
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app

# 提示模式
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app
```

安装时默认在被 patch 的二进制旁边创建备份，文件名格式：

```
wechat.dylib.wechat-antirecall-backup-20260505-143000
```

### 重新安装 / 切换模式

如果已安装旧补丁（例如在撤回时闪退，或想从静默切换到提示模式），加 `--no-backup` 直接覆盖：

```bash
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app --no-backup
sudo .build/release/wechat-antirecall install --with-tip --app /Applications/WeChat.app --no-backup
```

### 验证签名

```bash
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

## 补丁配置格式

`patches.json` 配置来自 WeChatTweak / 社区 fork，只保留防撤回目标。

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

## 参考

- [sunnyyoung/WeChatTweak](https://github.com/sunnyyoung/WeChatTweak-macOS) — upstream，包含 `Block message recall` 功能
- [tanranv5/WeChatTweak](https://github.com/tanranv5/WeChatTweak) — 社区 fork，补充较新 x86_64 配置，引入 `binary` 字段
- [zetaloop/BetterWX](https://github.com/zetaloop/BetterWX) — Windows 版微信 4 的同类提示模式补丁
