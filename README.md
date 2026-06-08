# wechat-antirecall

macOS 微信 4 防撤回补丁工具。工具只会处理 `patches.json` 中已知的
WeChat 构建号；遇到未知版本会拒绝写入，避免猜地址造成损坏。

> 1、使用前建议先读完“快速开始”和“恢复备份”。安装会修改
> `/Applications/WeChat.app` 内的二进制并重新签名，务必先完全退出微信。

> 2、遇到问题请先查看 安装故障排查(FAQ) 、使用故障排查(FAQ)、搜索 issues 解决

> 3、提issues 请备注 版本号、构建号、使用环境


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
| 268575 | arm64 | 静默防撤回、提示模式、多开、屏蔽更新 | `Contents/MacOS/WeChat`、`Contents/Resources/wechat.dylib` |
| 268596 | arm64 | 静默防撤回、提示模式、屏蔽更新 | `Contents/Resources/wechat.dylib` |
| 268597 | arm64 | 静默防撤回、提示模式、自定义提示、屏蔽更新 | `Contents/Resources/wechat.dylib` |
| 268599, 268601, 268602 | arm64 | 静默防撤回、提示模式、自定义提示、屏蔽更新 | `Contents/Resources/wechat.dylib` |
| 268831 | arm64 | 静默防撤回、提示模式、自定义提示 | `Contents/Resources/wechat.dylib` |
| 268849 | arm64 | 静默防撤回、提示模式、自定义提示(内联 hook)、屏蔽更新(未回归) | `Contents/Resources/wechat.dylib` |
| 268850 | arm64 | 同 268849（+1 热修，补丁点逐字节一致） | `Contents/Resources/wechat.dylib` |

可下载的微信 4.1.9 安装包：

- [微信 4.1.9.55 (38902)][wechat-4-1-9-55]
- [微信 4.1.9.57 (38937)][wechat-4-1-9-57]

[wechat-4-1-9-55]: https://dldir1v6.qq.com/weixin/Universal/Mac/xWeChatMac_universal_4.1.9.55_38902.dmg
[wechat-4-1-9-57]: https://dldir1v6.qq.com/weixin/Universal/Mac/xWeChatMac_universal_4.1.9.57_38937.dmg

微信 4.1.9 及 4.1.10 的防撤回补丁目标在
`Contents/Resources/wechat.dylib`，不是主二进制。工具会先单独重签被
patch 的 dylib，再重签整个 app，避免运行到被修改代码页时触发
`Code Signature Invalid`。

## 选择模式

- **静默防撤回**：默认模式。不显示撤回提示，原消息保留在聊天中。
- **提示模式**：加 `--with-tip`。保留微信原本的撤回提示，同时阻止删除原消息。
- **自定义提示**：加 `--runtime-tip`。支持构建号 `268597`、`268599`、`268601`、`268602`、`268831`、`268849`、`268850`，会安装
  `libWeChatAntiRecallRuntime.dylib` 并注入 `LC_LOAD_DYLIB`。`268597`–`268831`
  复用微信自带的派发桩挂载；`268849` 没有派发桩，改用内联 hook（静态改写
  `parseRevokeXML` 入口为 `adrp/ldr/br`，运行时再由 dylib 建 trampoline 并写回
  跳转槽）。
- **全版本多开**：使用 `clone` 命令复制出独立 App，例如 `WeChat 1.app`、`WeChat 2.app`。
  这个流程不依赖 `patches.json` 的构建号地址。
- **历史多开补丁**：`install --multi-instance` 仍保留，当前仅（微信 4.1.9）
  构建号 `268575` 支持。
- **屏蔽更新**：加 `--block-update`。仅支持矩阵中标注“屏蔽更新”的构建号；
  如果只想屏蔽更新，不改防撤回，用 `--update-only`。

构建号 `268831` 目前支持静默防撤回、提示模式和自定义提示，不支持
`--block-update` 或 `--multi-instance` 补丁。

构建号 `268849`（微信 4.1.10）支持静默防撤回、提示模式、`--runtime-tip`
自定义提示和 `--block-update` 屏蔽更新，不支持 `--multi-instance` 多开。

自定义提示（内联 hook）的安全特性与 `--with-tip` 不同，需要单独说明：

- 该构建去掉了运行时 hook 所需的派发桩，所以 `--runtime-tip` 改用内联 hook。
  安装时会**静态改写** `parseRevokeXML` 入口（`0x488c4c4`）的 3 条指令为
  `adrp x16,SLOT; ldr x16,[x16]; br x16`，SLOT 落在 `wechat.dylib` 的 `__DATA`
  尾部零填充区（`0x952bf00`）。运行时 dylib 在加载时建立 trampoline（重放原
  3 条指令再跳回 `0x488c4d0`）并把 hook 函数指针写入 SLOT。
- 入口改写和 dylib 注入由 `--runtime-tip` 一并完成，二者只会同时安装；缺少
  dylib 时 SLOT 不会被赋值，函数会跳空指针导致崩溃。因此**不要**手动只打入口
  补丁。`restore` 恢复 `wechat.dylib` 备份会同时撤销入口补丁、SLOT 与注入，
  二者一起回滚。
- hook 引擎本身（指令编码、trampoline、跳转槽派发）有单元测试覆盖；入口补丁
  点已对真实二进制 dry-run 校验。但“撤回时确实走到自定义文案”需要真实撤回
  事件才能确认，尚未在 268849 上做运行时回归——首次使用请用一条真实撤回消息
  验证。

屏蔽更新的 9 处补丁点与已验证的 `268601` 对应的是同一组函数：其中 8 处除
地址重定位外字节完全一致，1 处（`0x1d2a2c`）为同一函数、入口之后有改动，但
补丁是在函数入口写 `ret`、改动部分被直接跳过。需要注意：4.1.10 另带 Sparkle
（`SPUUpdater`）更新通道，本补丁不覆盖；更新拦截也尚未在 268849 上做运行时
回归。安装后请手动“检查更新”确认是否被拦截——一旦更新漏过并自动升级，会把
包括防撤回在内的所有补丁还原。

构建号 `268850` 是 `268849` 的 +1 热修：全部 12 个补丁点与 SLOT 零填充槽位
都逐字节一致，配置直接复用 `268849`，能力与注意事项相同。

`--runtime-tip` 会自动启用提示模式，不需要再加 `--with-tip`。
`--update-only` 不能与 `--with-tip`、`--runtime-tip`、`--multi-instance`
同时使用。

`clone` 生成的副本默认使用独立 `CFBundleIdentifier`，并移除
`weixin`、`wechat`、`xweixin` URL Scheme，避免系统回调随机落到副本。
每个副本通常需要单独登录。

历史 `--multi-instance` 补丁安装完成后，可以用下面命令启动新实例：

```bash
open -n /Applications/WeChat.app
```

也可以使用多开启动器：[WeChatMulti](https://github.com/loohalh/WeChatMulti)。

## 标准安装流程

### 1. 检查当前微信

```bash
# 退出当前打开的微信
pkill -x WeChat
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

需要历史 `268575` 多开补丁时：

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

## 全版本多开 / App 克隆

`clone` 不修改原始 `/Applications/WeChat.app`，而是复制出独立 App bundle。
默认生成 2 个副本：

```bash
swift run wechat-antirecall clone --dry-run --app /Applications/WeChat.app --output-dir /Applications
swift build -c release
sudo .build/release/wechat-antirecall clone --app /Applications/WeChat.app --output-dir /Applications
```

默认结果：

```text
/Applications/WeChat 1.app
/Applications/WeChat 2.app
```

默认副本身份：

```text
com.tencent.xinWeChat.antirecall.clone1
com.tencent.xinWeChat.antirecall.clone2
```

常用参数：

- `--count <n>`：设置副本数量，默认 `2`。
- `--name-prefix <name>`：设置副本名前缀，默认 `WeChat`。
- `--keep-url-schemes`：保留 `weixin`、`wechat`、`xweixin` URL Scheme。
  默认会移除，避免 LaunchServices 回调冲突。
- `--replace`：目标副本已存在时，把旧副本改名为时间戳备份后再创建。
- `--skip-resign`：跳过重签名，只建议测试临时 fake app 时使用。

副本的自定义提示配置优先读取当前副本 bundle id 对应的容器 plist。
如果副本没有配置，不会回退读取原始
`com.tencent.xinWeChat` 的自定义提示短语。

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
- **自己撤回**的消息不会套用自定义提示，保持微信原生的“你撤回了一条消息 /
  You recalled a message”。自定义提示只用于拦截**别人**的撤回。

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

`268599`、`268601`、`268602`、`268849`、`268850` 的 runtime hook 会先确认 XML 是 `<revokemsg>` 撤回事件，
再读取和改写撤回提示字段。视频、链接等非撤回 XML 不会进入撤回消息字段读取路径。

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

如果安装了 `--multi-instance`，还会修改主二进制，可额外检查：

```bash
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/MacOS/WeChat
```

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

如果要恢复 `--multi-instance` 涉及的主二进制备份，改用：

```bash
sudo .build/release/wechat-antirecall restore \
  --binary Contents/MacOS/WeChat \
  --backup /Applications/WeChat.app/Contents/MacOS/WeChat.wechat-antirecall-backup-YYYYMMDD-HHMMSS \
  --app /Applications/WeChat.app
```

恢复 `wechat.dylib` 备份后，runtime 的 load command 会随备份一起消失。
`Contents/Resources/libWeChatAntiRecallRuntime.dylib` 即使还在目录里，也不会再被加载。



## 安装故障排查(FAQ)


### 1、权限不足

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

#### sudo 仍然写不进去

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

### 2、微信仍在运行

工具提示 `WeChat 仍在运行` 时，请先完全退出微信再安装或恢复。这个检查是为了
避免旧进程在执行到被修改代码页时被 macOS 以 `Code Signature Invalid` 终止。

### 3、找不到 runtime dylib

如果 `--runtime-tip` 提示找不到 `libWeChatAntiRecallRuntime.dylib`，先运行：

```bash
swift build -c release
```

也可以显式指定 dylib：

```bash
sudo .build/release/wechat-antirecall install --runtime-dylib .build/release/libWeChatAntiRecallRuntime.dylib --app /Applications/WeChat.app
```

## 使用故障排查(FAQ)


### 1、打开 `微信` 频繁弹权限申请窗


设置 - 隐私与安全性 - 完全磁盘访问权限(或者重复弹窗的对应权限)： 选择`微信`,点列表底部 `-` 删除，再点列表底部 `+` 选择 `微信`， 添加后会弹出生效提示窗，选择 `退出并重新打开` 生效



## 维护 patches.json

`patches.json` 来自 WeChatTweak / 社区 fork 的 Mach-O patch 思路，并补充了
微信 4 的防撤回、提示模式、多开和屏蔽更新目标。

示例：

```json
{
  "version": "268596",
  "targets": [
    {
      "identifier": "revoke",
      "binary": "Contents/Resources/wechat.dylib",
      "entries": [
        {
          "arch": "arm64",
          "addr": "47647a0",
          "expected": "E00F0034",
          "asm": "7F000014"
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
