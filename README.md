# wechat-antirecall

macOS 微信 4 的防撤回补丁工具。它只给 `patches.json` 里**已知构建号**打补丁，遇到未知版本会直接拒绝，不会靠猜地址去改二进制。

> ⚠️ 安装会修改 `/Applications/WeChat.app` 里的二进制并重新签名（ad-hoc）。**操作前请完全退出微信**，运行中打补丁可能触发 `Code Signature Invalid` 崩溃。安装时会自动在被修改文件旁生成备份。
>
> 遇到问题：先看 [故障排查](#故障排查) → 搜 issues → 再提 issue（请附上**微信版本号、构建号、系统环境**）。

底层实现、补丁地址、逆向记录、如何新增构建号，都在 [MAINTAINING.md](MAINTAINING.md)。本文只讲怎么用。

---

## 图形界面（GUI，推荐给普通用户）

不想碰终端？用图形界面 App「微信防撤回」——下载即用，点几下就能开启防撤回、自定义提示、多开、一键还原。

- **获取**：到 [Releases](https://github.com/fzlzjerry/wechat-antirecall/releases) 下载 `.dmg`，拖进「应用程序」。
- **首次打开**：在「应用程序」里**右键点它 → 打开**（因为未做 Apple 付费公证，直接双击会被 Gatekeeper 拦下）。
- **保持最新**：App 内「检查更新 → 拉取最新补丁数据」会拉取最新 `patches.json`，新版微信的静默防撤回**即时支持，无需重装 App**。（新版微信的自定义提示需要新的 App 发布或从源码构建。）
- **仅支持 Apple Silicon（M 系列）Mac。**

GUI 是一层薄壳：它内置预编译好的命令行工具，界面上的操作最终都是调用下面的 CLI，只是把「退出微信 / 管理员授权 / 权限引导 / 备份恢复」都做成了图形化流程。想了解它做了什么，看日志区的「查看详情」即可。

**自己构建 GUI**（需要 Xcode 工具链，Apple Silicon）：

```bash
bash Scripts/make-icon.sh    # 生成 App 图标（一次即可，已随仓库提供）
bash Scripts/make-app.sh     # 产出 dist/WeChatAntiRecall.app（ad-hoc 签名）
open dist/WeChatAntiRecall.app
```

发布流程（打 `v*` tag 触发 GitHub Actions 自动构建 DMG）见 [MAINTAINING.md](MAINTAINING.md)。

> 下面是命令行（CLI）用法，供进阶用户和 GUI 背后的机制参考。

---

## 功能一览

| 功能 | 说明 | 开关 |
| --- | --- | --- |
| **静默防撤回** | 别人撤回的消息原样留在聊天里，不显示任何提示。 | 默认 |
| **提示模式** | 保留微信原生的"xx 撤回了一条消息"提示，同时不删除原消息。 | `--with-tip`（已弃用） |
| **自定义撤回提示** | 把**别人**撤回的提示换成你自定义的短语，支持发送者、时间等占位符。 | `--runtime-tip` |
| **屏蔽自动更新** | 拦住微信自动升级，避免升级把补丁还原。 | `--block-update` / `--update-only` |
| **多开** | 复制出独立的微信 App，可同时登录多个账号。 | `clone` 命令 |

---

## 快速开始

```bash
# 1. 退出微信
pkill -x WeChat

# 2. 确认当前构建号是否被支持
swift run wechat-antirecall versions --app /Applications/WeChat.app

# 3. dry-run：只检查补丁点能否命中，不写任何文件
swift run wechat-antirecall install --dry-run --app /Applications/WeChat.app

# 4. 编译 release 并用 sudo 正式安装
swift build -c release
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app
```

装完请**完全退出并重开微信**。第一次使用建议照 [安装后请验证](#安装后请验证) 做一次实测。

> 想要自定义撤回提示，把第 3、4 步的 `install` 换成 `install --runtime-tip`，并先设置好短语（见 [自定义撤回提示](#自定义撤回提示)）。

---

## 支持的版本

工具按**构建号**（`CFBundleVersion`，即 `versions` 打印的那个数字）匹配，不是营销版本号。

| 构建号 | 微信版本 | 静默防撤回 | 提示模式 | 自定义提示 | 屏蔽更新 | 多开补丁 |
| --- | --- | :---: | :---: | :---: | :---: | :---: |
| 268575 | — | ✓ | ✓ | — | ✓ | ✓ |
| 268596 | — | ✓ | ✓ | — | ✓ | — |
| 268597 | — | ✓ | ✓ | ✓ | ✓ | — |
| 268599 | — | ✓ | ✓ | ✓ | ✓ | — |
| 268601 | — | ✓ | ✓ | ✓ | ✓ | — |
| 268602 | — | ✓ | ✓ | ✓ | ✓ | — |
| 268831 | — | ✓ | ✓ | ✓ | — | — |
| 268849 | 4.1.10 | ✓ | ✓ | ✓ | ✓ | — |
| 268850 | 4.1.10 | ✓ | ✓ | ✓ | ✓ | — |
| 268851 | 4.1.10 | ✓ | ✓ | ✓ | ✓ | — |
| 269077 | 4.1.11 | ✓ | ✓ | ✓ | ✓ | — |
| 269110 | 4.1.11 | ✓ | ✓ | ✓ | ✓ | — |

- **自定义提示**（`--runtime-tip`）只支持标 ✓ 的构建号；`268575`、`268596` 不支持，传了会报错。
- **多开补丁**（`--multi-instance`）目前只有 `268575`。其余版本的多开请用 [`clone`](#多开clone) 命令，它不依赖构建号。
- 防撤回补丁改的是 `Contents/Resources/wechat.dylib`（不是主二进制）。工具会先单独重签这个 dylib，再重签整个 App。

微信 4.1.9 安装包（供回退／测试）：

- [微信 4.1.9.55][wechat-4-1-9-55] · [微信 4.1.9.57][wechat-4-1-9-57]

[wechat-4-1-9-55]: https://dldir1v6.qq.com/weixin/Universal/Mac/xWeChatMac_universal_4.1.9.55_38902.dmg
[wechat-4-1-9-57]: https://dldir1v6.qq.com/weixin/Universal/Mac/xWeChatMac_universal_4.1.9.57_38937.dmg

---

## 命令总览

```
wechat-antirecall versions    查看当前微信版本、构建号，以及是否被支持
wechat-antirecall install     打补丁（别名：patch）
wechat-antirecall clone       复制出独立微信 App，实现多开
wechat-antirecall restore     从备份恢复
wechat-antirecall tip-phrase  管理自定义撤回提示短语
wechat-antirecall help        查看完整参数
```

### install（打补丁）

```bash
sudo .build/release/wechat-antirecall install [参数] --app /Applications/WeChat.app
```

| 参数 | 作用 |
| --- | --- |
| `--app <路径>` | 目标 App，默认 `/Applications/WeChat.app` |
| `--config <路径>` | `patches.json` 路径，默认取当前目录或可执行文件旁 |
| *(不加 tip 参数)* | 静默防撤回（默认模式） |
| `--with-tip` | 提示模式（**已弃用**，见下方说明） |
| `--runtime-tip` | 自定义撤回提示，安装运行时 hook（自动启用提示模式） |
| `--runtime-dylib <路径>` | 手动指定 runtime dylib（自动启用 `--runtime-tip`） |
| `--block-update` | 同时屏蔽自动更新 |
| `--update-only` | 只屏蔽更新，不动防撤回 |
| `--multi-instance` | 历史多开补丁（仅 `268575`） |
| `--dry-run` | 只检查补丁点，不写文件 |
| `--no-backup` | 不创建新备份（覆盖安装 / 切换模式时用） |
| `--skip-resign` | 跳过重签名（仅测试用） |

常用组合：

```bash
# 静默防撤回
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app

# 自定义撤回提示 + 屏蔽更新
sudo .build/release/wechat-antirecall install --runtime-tip --block-update --app /Applications/WeChat.app

# 只屏蔽更新
sudo .build/release/wechat-antirecall install --update-only --app /Applications/WeChat.app
```

参数约束：

- **`--with-tip` 已弃用**：它是纯字节补丁、没有运行时 hook，对**你自己撤回**的消息会留下重复的撤回提示且无法处理。支持的构建号请改用 `--runtime-tip`；`--with-tip` 仅作为不支持 runtime-tip 的旧版本（`268575`、`268596`）的后备，单独使用时会打印弃用提示。
- `--update-only` 会隐含 `--block-update`，且**不能**与 `--with-tip`、`--runtime-tip`、`--multi-instance` 同用。
- `--with-tip`（需 `revoke-tip` 目标）、`--block-update`（需 `update` 目标）只在当前构建号于 `patches.json` 里提供对应目标时才生效，否则报错——工具不会静默降级。`--runtime-tip` 则由受支持构建号列表（上一条）把关，不支持的版本直接报错。

### clone（多开）

见下方 [多开（clone）](#多开clone)。

### restore（恢复备份）

见下方 [恢复备份](#恢复备份)。

### tip-phrase（自定义提示短语）

见下方 [自定义撤回提示](#自定义撤回提示)。

---

## 自定义撤回提示

自定义提示分两步：**① 设置短语**（写进你自己的微信偏好配置）+ **② 安装运行时 hook**（`install --runtime-tip`）。

**① 设置短语**（用普通用户执行，**不要加 `sudo`**）：

```bash
swift run wechat-antirecall tip-phrase get                                  # 查看当前短语
swift run wechat-antirecall tip-phrase set "已拦截 {from} 于 {time} 撤回的一条消息"
swift run wechat-antirecall tip-phrase preview "已拦截 {from} 撤回：{content}" --from 张三                 # 预览（默认当作文本消息）
swift run wechat-antirecall tip-phrase preview "已拦截 {from} 撤回：{content}" --from 张三 --type 图片      # 预览媒体消息 → {content} 显示 [图片]
swift run wechat-antirecall tip-phrase reset                                # 恢复默认
```

`preview` 可选：`--from <发送者>`、`--type <消息类型>`（如 `图片`、`语音`；决定 `{content}` 显示原文还是 `[类型]` 占位符）、`--message <正文>`（自定义示例正文）。

**② 安装运行时 hook**：

```bash
swift build -c release
sudo .build/release/wechat-antirecall install --runtime-tip --app /Applications/WeChat.app
```

改完短语后请**完全退出并重开微信**——已运行的微信可能还持有旧的偏好缓存。

### 短语规则

- 最长 **120 个字符**，不能包含换行，不能包含 CDATA 结束标记 `]]>`。
- `{from}` → 发送者的备注或昵称。
- `{time}` → 撤回时间，格式 `HH:mm`。
- `{content}` → 被撤回消息的内容（见下方说明）。
- 未设置时默认显示 `已拦截一条撤回消息`。
- **你自己撤回**的消息不套用自定义提示，保持微信原生的"你撤回了一条消息"。自定义提示只作用于**别人**的撤回。

### 关于 `{content}`

`{content}` 是一个受支持的占位符：`tip-phrase preview` 能正常预览它（文字消息显示原文，图片/语音等媒体显示 `[图片]`、`[语音]` 这类类型占位符）。

但**当前运行时并没有安装"接收消息时缓存原文"的 hook**，所以在真实运行的微信里 `{content}` 取不到内容，会按空处理——连同它前面的分隔符一起省略，不会留下孤零零的"撤回："。也就是说，短语里可以写 `{content}`，但目前它在实际拦截时始终为空。这部分还是脚手架，详见 [MAINTAINING.md](MAINTAINING.md)。

### 短语存储位置

```
~/Library/Containers/com.tencent.xinWeChat/Data/Library/Preferences/com.tencent.xinWeChat.plist
```

### 调试探针

默认关闭。只有在需要分析撤回 XML 或消息元数据时才打开：

```bash
swift run wechat-antirecall tip-phrase probe get     # 查看状态
swift run wechat-antirecall tip-phrase probe on      # 打开
swift run wechat-antirecall tip-phrase probe off     # 关闭
```

`probe on` 会把 `msgType`、`newmsgid`、撤回提示和 XML 片段写进 macOS Console。日志可能包含聊天元数据，**收集完请及时关闭**。

---

## 多开（clone）

`clone` 不改原始 `/Applications/WeChat.app`，而是复制出独立的 App bundle。它不依赖 `patches.json` 的构建号，任何版本都能用。

```bash
swift run wechat-antirecall clone --dry-run --app /Applications/WeChat.app --output-dir /Applications
swift build -c release
sudo .build/release/wechat-antirecall clone --app /Applications/WeChat.app --output-dir /Applications
```

默认生成 `WeChat 1.app`、`WeChat 2.app` 两个副本，各自独立的 Bundle ID（`com.tencent.xinWeChat.antirecall.clone1/2`）。每个副本通常要单独登录。

| 参数 | 作用 |
| --- | --- |
| `--output-dir <目录>` | 副本输出目录，默认 `/Applications` |
| `--count <n>` | 副本数量，默认 `2` |
| `--name-prefix <前缀>` | 副本名前缀，默认 `WeChat` |
| `--keep-url-schemes` | 保留副本的 URL Scheme。默认会移除副本注册的**全部** URL Scheme（含 `weixin`/`wechat`/`xweixin`），避免系统回调随机落到副本 |
| `--replace` | 目标已存在时，把旧副本改名为时间戳备份后再创建 |
| `--skip-resign` | 跳过重签名（仅测试用） |

副本的自定义提示配置只读它自己 Bundle ID 对应的容器 plist，不会回退读原始微信的短语。

> 想用 `--multi-instance` 补丁的历史多开（仅 `268575`），装好后用 `open -n /Applications/WeChat.app` 启动新实例，或用 [WeChatMulti](https://github.com/loohalh/WeChatMulti)。

---

## 重装 / 切换模式

已经装过补丁，想从静默切到提示、或重装 runtime，加 `--no-backup` 覆盖当前补丁即可：

```bash
sudo .build/release/wechat-antirecall install --runtime-tip --app /Applications/WeChat.app --no-backup
```

`--no-backup` 只是不再创建**新**备份，不会绕过权限、签名或 App Management 限制。

---

## 恢复备份

安装时会在被改文件旁生成备份，命名如 `wechat.dylib.wechat-antirecall-backup-20260505-143000`。恢复前**先退出微信**：

```bash
sudo .build/release/wechat-antirecall restore \
  --binary Contents/Resources/wechat.dylib \
  --backup /Applications/WeChat.app/Contents/Resources/wechat.dylib.wechat-antirecall-backup-YYYYMMDD-HHMMSS \
  --app /Applications/WeChat.app
```

- 恢复 `wechat.dylib` 备份后，注入的 runtime load command 会随之消失，`libWeChatAntiRecallRuntime.dylib` 即使还在目录里也不会再被加载。
- 如果装过 `--multi-instance`（会改主二进制），把 `--binary` 换成 `Contents/MacOS/WeChat`、`--backup` 换成对应备份即可。
- restore 默认会重签名，加 `--skip-resign` 可跳过（仅测试用）。

---

## 验证签名

```bash
# 常规防撤回 / 屏蔽更新
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/wechat.dylib
codesign --verify --deep --strict --verbose=2 /Applications/WeChat.app

# 装过 --runtime-tip 时，额外检查 runtime dylib
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/Resources/libWeChatAntiRecallRuntime.dylib

# 装过 --multi-instance 时，额外检查主二进制
codesign --verify --strict --verbose=2 /Applications/WeChat.app/Contents/MacOS/WeChat
```

---

## 安装后请验证

`--dry-run`、`swift build`、`swift test` 只能证明**补丁点原始字节匹配、代码能编译**——它们**无法**证明 hook 在真实撤回时确实生效，也无法证明屏蔽更新真的拦住了升级。这些运行时行为尚未在全部构建号上做过回归。

所以第一次在某个构建号上使用时，请手动确认：

- **防撤回 / 自定义提示**：用另一台设备或账号发一条消息再撤回，看原消息是否留存、提示是否符合预期。
- **屏蔽更新**：手动点微信"检查更新"，若不再有反应，说明补丁生效。（一旦更新漏过并自动升级，包括防撤回在内的所有补丁都会被还原。）

---

## 故障排查

### 安装

**权限不足** —— 看到类似
`"wechat.dylib" couldn't be copied because you don't have permission…`：
不要用 `swift run … install` 直接装。先编译 release，再用 `sudo` 跑：

```bash
swift build -c release
sudo .build/release/wechat-antirecall install --app /Applications/WeChat.app
```

若 `sudo` 下 `touch` 目标目录仍报 `Operation not permitted`，通常是 macOS 隐私拦截。到 **系统设置 → 隐私与安全性 → App 管理**（必要时再加 **完全磁盘访问权限**），给你用的终端（Terminal / iTerm / VS Code / Cursor 等）授权，退出重开终端再试。

**微信仍在运行** —— 提示 `WeChat 仍在运行` 时，先完全退出微信再安装或恢复。这是为了避免旧进程执行到被改代码页时被系统以 `Code Signature Invalid` 杀掉。

**找不到 runtime dylib** —— `--runtime-tip` 报找不到 `libWeChatAntiRecallRuntime.dylib`，先 `swift build -c release`；也可以用 `--runtime-dylib .build/release/libWeChatAntiRecallRuntime.dylib` 显式指定。

### 使用

**打开微信频繁弹权限申请窗** —— 到 **系统设置 → 隐私与安全性 → 完全磁盘访问权限**（或反复弹窗的对应权限）：选中`微信`，点底部 `−` 删除，再点 `+` 重新添加，弹出提示时选 `退出并重新打开` 生效。

**升级到 macOS 26 / 27 后，补丁版微信打不开**（点了没反应 / 图标弹一下就退）—— 给 `微信` 单独授予**完全磁盘访问权限**：
系统设置 → 隐私与安全性 → 完全磁盘访问权限 → `+` 选择 `/Applications/WeChat.app` → 打开开关 → 再开微信。

> 原因：打补丁会用 ad-hoc 签名重签微信，抹掉了原本的签名身份和 entitlements。微信把数据存在 `~/Documents/app_data`，而 `Documents` 是 macOS 的 TCC 保护目录；新版 macOS 会拒绝这个"没身份、没授权"的微信访问该目录，于是启动即退。授予完全磁盘访问权限后即可正常启动。
>
> 补丁每次重签后 cdhash 会变，所以**重新打补丁、或微信自身升级后，可能要把列表里旧的`微信`删掉重新添加一次**。自检：若终端直接跑 `/Applications/WeChat.app/Contents/MacOS/WeChat` 能起来、但双击 / Dock 起不来，基本就是这个权限问题。

---

## 从源码构建

```bash
swift build -c release      # 产出 .build/release/wechat-antirecall 和 runtime dylib
swift test                  # 运行单元测试
```

要求 macOS 12+ 和 Swift 5.9+。

## 维护者文档

补丁地址、`patches.json` 结构、运行时 hook 的两种机制（派发桩 vs 内联）、屏蔽更新补丁点的逆向来源、逐字节核对记录、`{content}` 现状、以及**如何新增一个构建号**，都在 → **[MAINTAINING.md](MAINTAINING.md)**。

## 参考

- [sunnyyoung/WeChatTweak-macOS](https://github.com/sunnyyoung/WeChatTweak-macOS) —— upstream，含 `Block message recall`
- [tanranv5/WeChatTweak](https://github.com/tanranv5/WeChatTweak) —— 社区 fork，补充 x86_64 配置，引入 `binary` 字段
- [zetaloop/BetterWX](https://github.com/zetaloop/BetterWX) —— Windows 版微信 4 的同类提示模式补丁
- [X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin) —— 自定义撤回提示短语功能参考
- [naizhao/WeChatTweak](https://github.com/naizhao/WeChatTweak/blob/master/MAINTAINING.md) —— 社区 fork 维护指南

## 友链

- [linux.do](https://linux.do) —— 新的理想型社区
