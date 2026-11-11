# 微信防撤回 for macOS

> [!TIP]
> **🖼️ 推荐项目：WallpaperMachine**
>
> 官网：**[wallpapermachine.app](https://www.wallpapermachine.app/)** · GitHub：**[WallpaperMachine/WallpaperMachine](https://github.com/WallpaperMachine/WallpaperMachine)**

一个面向普通用户的 macOS 微信 4 工具：保留被撤回的消息，也支持自定义提示、微信多开、屏蔽自动更新和一键还原。

**[下载最新版](https://github.com/fzlzjerry/wechat-antirecall/releases)** · [遇到问题](#遇到问题) · [进阶用法](#进阶用户命令行)

> **使用前先看**
>
> - 目前仅支持 **Apple Silicon（M 系列）Mac**。
> - 安装前请先**完全退出微信**。
> - 工具会修改微信 App，但每次安装都会自动保留备份，可以随时还原。
> - 如果微信升级后防撤回消失，通常重新检测并安装一次即可。
> - 支持 **微信 4.1.15.55（270135）**、**4.1.15.53（270133）**、**4.1.15.52（270132）**、**4.1.15.22（270102）**、**4.1.15.20（270100）** 与 **4.1.15.10（270090）**。270090 已实测确认防撤回和自动领取红包可用；270100 已完成静态地址核对；270102、270132、270133、270135 已通过静态核对与启动 hook 验证，仍需真实聊天与红包实测。
> - 已修复运行组件早于微信核心库加载时的启动闪退。已安装旧组件的用户需使用新版工具重新安装，单独更新补丁数据不会修复。

---

## 它能做什么

| 你想要的效果 | 对应功能 |
| --- | --- |
| 别人撤回后，消息仍留在聊天里 | **静默防撤回** |
| 显示“谁在什么时候撤回了什么” | **自定义提示** |
| 事后查看被拦截的撤回清单 | **撤回记录（默认关闭）** |
| 静音的群里出现关心的词时收到提醒 | **关键词提醒（默认关闭，适配构建同自动红包）** |
| 共享屏幕、录屏时不露出微信窗口 | **窗口隐私（默认关闭）** |
| 避免微信自动升级后覆盖补丁 | **屏蔽自动更新** |
| 同时登录多个微信账号 | **微信多开** |
| 自动领取新收到的普通红包 | **自动红包（269624 / 269628 / 270090 / 270100 / 270102 / 270132 / 270133 / 270135）** |
| 回到修改前的原版微信 | **恢复 / 卸载** |

普通用户只需要使用图形界面，不需要打开终端，也不需要理解补丁地址或构建参数。

---

## 3 分钟完成安装

### 1. 下载 App

打开 **[Releases](https://github.com/fzlzjerry/wechat-antirecall/releases)**，下载最新的 `.dmg`，然后把「微信防撤回」拖进「应用程序」。

### 2. 第一次打开

在「应用程序」中找到「微信防撤回」，**右键 → 打开 → 再次确认打开**。

如果直接双击后提示无法验证开发者，使用上面的右键打开方式即可。

### 3. 退出微信

安装补丁前，需要完全退出微信：

1. 在 Dock 中右键微信图标。
2. 选择「退出」。
3. 确认工具左下角显示 **“微信已退出”**。

### 4. 检测当前版本

打开「微信防撤回」后，首页会自动显示：

- 当前微信版本和构建号；
- 这个版本是否受支持；
- 防撤回是否已经开启。

如果显示“暂不支持”，先进入 **「检查更新」→「拉取最新补丁数据」**，然后返回首页重新检测。

### 5. 开启防撤回

在首页点击 **「开启防撤回」**，按提示完成授权。安装成功后重新打开微信。

第一次使用时，建议让另一个账号发一条测试消息再撤回，确认原消息仍然保留。

---

## 我应该选择哪种模式

### 静默防撤回（推荐）

别人撤回消息后，原消息继续保留，不额外显示提示。适合只想安静保留消息的用户。

操作路径：**首页 → 开启防撤回**。

### 自定义撤回提示

可以把微信原来的撤回提示替换成自己的文字，例如：

```text
已拦截 {from} 于 {time} 撤回：{content}
```

支持的占位符：

| 占位符 | 显示内容 |
| --- | --- |
| `{from}` | 撤回消息的发送者 |
| `{time}` | 撤回时间，例如 `23:18` |
| `{content}` | 文字内容，或 `[图片]`、`[视频]`、`[语音]` 等类型提示 |

设置方法：

1. 打开 **「自定义提示」**。
2. 输入短语并查看预览。
3. 首次使用时点击「保存并开启自定义提示」。
4. 以后修改短语只需点击「保存并应用」，不会重复签名微信。
5. 完全退出并重新打开微信。

> 如果页面提示无权读取已保存的短语，按页面按钮为本 App 开启「完全磁盘访问」，然后退出并重新打开本 App。

> `{content}` 的完整内容预览目前只在构建号 **269340、269341、269574、269575、269576、269577、269578、269579、269619、269624、269628、270090、270100、270102、270132、270133、270135** 上启用，并且只能读取本次微信启动后收到的消息。其他情况会自动省略内容，不会显示多余的冒号或空白。

### 屏蔽自动更新

微信升级通常会覆盖已经安装的补丁。可以在「高级安装」中同时打开 **“屏蔽自动更新”**。

如果你希望继续正常接收微信更新，就不要开启这个选项；微信升级后重新安装防撤回即可。

### 微信多开

打开 **「微信多开」**，选择副本数量后点击「创建多开副本」。工具会在「应用程序」中创建 `WeChat 1`、`WeChat 2` 等独立 App。

- 每个副本通常需要单独登录。
- 副本默认不会抢占微信网页链接。
- 多开不会修改原始微信，也不依赖当前微信构建号。

### 自动红包

支持 **微信 4.1.13（269624 / 269628）及 4.1.15（270090 / 270100 / 270102 / 270132 / 270133 / 270135）**，默认关闭。**用户已在微信 4.1.15.10（270090）实测确认普通红包自动领取可用。** 270100、270102、270132、270133 已完成静态地址与指纹核对，270102、270132、270133、270135 尚未实测领取。支持新构建需要重新安装新版运行组件，单独更新补丁数据不够；领取结果仍以微信显示为准。

打开「自动红包」，先按页面提示退出微信并安装或更新运行组件，再开启「自动领取新红包」。此功能使用自定义撤回提示模式；更新组件后需要重启微信。

此次新增构建需更新运行组件；旧组件不会因更新补丁数据自动获得红包适配。

命令行用户可直接使用下方的 [CLI 安装与自动红包命令](#自动红包设置)。

可设置收到红包后的等待时间。只处理开启后新收到的普通红包，跳过历史消息、自己发送和已领取的红包；每个红包只尝试一次，不自动重试失败请求。微信更新到其他构建后此功能不会调用旧地址。

协议调用链、原生对象布局和验证边界见 [逆向记录](Docs/red-packet-269624.md)。

### 窗口隐私

默认关闭。开启后，所有微信窗口都不会出现在屏幕共享、录屏和其他软件的截图里。微信自带的“隐藏窗口截图”选项只覆盖主窗口，单独打开的聊天窗口、图片查看器、朋友圈等不在其中，这里把它们都盖住。

1. 打开 **「窗口隐私」**。
2. 如果提示需要更新运行组件，先完全退出微信，点击「安装或更新运行组件」。此功能使用自定义撤回提示模式。
3. 打开开关。已经打开的微信窗口半秒内生效，不需要重启微信；关闭后会恢复原状。

需要知道的限制：

- 这是 macOS 提供的窗口属性（`sharingType`），效果取决于录屏或共享软件以及系统版本，**不能当作安全保证**。微信自带的“隐藏窗口截图”选项依赖同一个属性，限制相同。
- 微信自带的截图、录屏也会看不到微信窗口。需要截微信自己的界面时请先关闭。
- macOS 的通知横幅由系统绘制，不受影响。共享屏幕前请自行打开“勿扰”。
- 新窗口出现的瞬间可能有极短的露出。
- 关闭时只恢复本工具改过的窗口，不会动微信自己已经隐藏的窗口。
- 不依赖微信构建号，所有能安装自定义提示运行时的版本都可用。

### 关键词提醒

默认关闭。新收到的**文字消息**包含你设定的关键词时，弹一条 macOS 系统通知，被静音的群聊也一样。适合把重要的群设为免打扰，又不想错过“红包”“紧急”“你的名字”这类词。

1. 打开 **「关键词提醒」**，添加至少一个关键词（最多 20 个，每个最长 32 个字符）。
2. 如果提示需要更新运行组件，先完全退出微信，点击「安装或更新运行组件」。此功能使用自定义撤回提示模式。
3. 打开开关，然后完全退出并重新打开微信。第一次提醒时 macOS 可能会请求通知权限。

行为说明：

- 只检查文字消息，不区分大小写和全角半角；群聊里不会匹配发送者的账号。多个关键词同时命中时，按列表顺序取第一个。
- 通知里显示命中的关键词和消息开头约 80 个字，**看不到聊天名称**；点击通知会打开微信。
- 没有被静音的聊天，可能同时收到微信自己的通知和这条提醒。
- 只提醒开启之后新收到的消息，不补发历史消息，也不提醒你自己发出的消息。
- 匹配在微信进程里完成，消息内容不会保存到文件，也不会上传。
- 目前适配的构建与自动红包相同（见上），其余构建无法开启。

### 撤回记录

默认关闭。开启后，每次拦截到别人撤回消息，都会在本机追加一条记录：谁撤回了什么、什么时候。适合想事后回看“刚才撤回了什么”的用户。

1. 打开 **「撤回记录」**。
2. 如果提示需要更新运行组件，先完全退出微信，点击「安装或更新运行组件」。此功能使用自定义撤回提示模式。
3. 打开开关，然后完全退出并重新打开微信。
4. 之后被拦截的撤回会出现在页面的列表里，点「刷新」可重新读取。

记录里有什么：

- 撤回提示文本（含撤回者名称）和本机记录的时间；
- 会话 ID（群聊以 `@chatroom` 结尾）；
- 消息内容预览：文字消息显示文字，图片、语音等显示 `[图片]`、`[语音]`。只覆盖**本次启动微信之后**收到的消息，其余显示“内容未知”。

注意事项：

- 记录只保存在微信自己的容器目录里，不会上传，也不会写进系统日志。
- 页面读取该目录可能需要「完全磁盘访问权限」；没有授权时开关仍可使用，列表会提示如何授权。
- 你自己撤回的消息不会被记录。
- 日志最多保留约 4 MB（两个文件），超出后丢弃最旧的一半。可以随时在页面里「清空」。

### 密钥导出（CLI）

默认关闭。微信 4.x 用 SQLCipher 加密本地聊天数据库，密钥以 `x'<密钥><盐>'` 的形式缓存在微信进程自己的内存里。开启后，运行组件会**在微信进程内部**扫描自己的内存并把密钥快照写到微信容器的 `keys.json`——不需要重签微信、不需要 sudo，也不需要给任何工具授予开发者工具或完全磁盘之外的权限。

适合配合 [wx-cli](https://github.com/Steady775/wx-cli) 这类本地读取自己聊天记录的命令行工具：`key-export export` 会把每个密钥按盐值配对到具体的数据库文件，直接生成 wx-cli 的 `~/.wx-cli/all_keys.json`，之后 `wx sessions` / `wx history` 照常使用。

```bash
swift run -c release wechat-antirecall key-export on    # 需已安装含此组件的运行时
# 等微信运行并登录后最多约 30 秒生成快照
swift run -c release wechat-antirecall key-export list
swift run -c release wechat-antirecall key-export export   # 写 ~/.wx-cli/all_keys.json
swift run -c release wechat-antirecall key-export export --output /其他/路径.json
```

注意事项：

- 密钥在登录后才会出现在内存里；快照每 10 分钟自动刷新一次（期间最多 30 秒后首次生成）。切换账号后重新登录即可覆盖。
- **`keys.json` 与导出文件包含可用解密全部本地聊天记录的密钥，请像保管密码一样保管**；不再需要时删除对应文件或 `key-export off`。
- 快照存放在微信容器内（`~/Library/Containers/<bundle id>/Data/Library/Application Support/WeChatAntiRecall/keys.json`），读取和导出需要终端具备「完全磁盘访问权限」。

### 恢复 / 卸载

每次安装前，工具都会把原文件保存在微信 App 内部。需要恢复时：

1. 完全退出微信。
2. 打开 **「恢复 / 卸载」**。
3. 选择要恢复的时间。
4. 点击 **「还原这一次」**。
5. 重新打开微信。

恢复只会还原被修改的微信程序文件，不会删除聊天记录或账号数据。

---

## 检查更新

「检查更新」页面有两种更新：

### 补丁数据更新

用于支持新的微信构建号。文件很小，拉取后立即生效，不需要重新安装「微信防撤回」App。

适合以下情况：

- 微信刚刚升级；
- 首页显示“暂不支持”；
- 安装时提示补丁数据不匹配。

### 应用更新

用于获取新的界面、功能、修复和运行时支持。自定义提示需要适配新版微信时，通常需要更新 App 本身。

普通用户使用发布页面中的最新版即可；「从源码构建」是为开发者准备的功能。

---

## 遇到问题

### 「微信防撤回」打不开

在「应用程序」中找到它，使用 **右键 → 打开**，不要直接双击。

### 没有检测到微信

确认微信安装在默认位置：

```text
/Applications/WeChat.app
```

目前图形界面默认检测这个位置。

### 当前微信版本暂不支持

打开 **「检查更新」→「拉取最新补丁数据」**。更新后仍不支持，说明这个微信构建号还在适配中。

反馈问题时请附上首页显示的：

- 微信版本；
- 构建号；
- macOS 版本；
- 操作日志中最后几行错误。

### 安装时提示没有权限或 `Operation not permitted`

打开：

**系统设置 → 隐私与安全性 → App 管理**

允许「微信防撤回」修改其他 App。如果仍然失败，再到：

**系统设置 → 隐私与安全性 → 完全磁盘访问权限**

添加「微信防撤回」，打开开关后**退出并重新打开工具**再试。

### 安装后微信点了没反应

CLI 会在修改签名前自动保存微信主程序、Helper 和扩展的 entitlements，重签名后逐项比对；如果麦克风、摄像头、网络、沙盒或扩展权限有任何一项丢失，安装会直接报错而不会把签名步骤标记为成功。

重新签名仍然是 ad-hoc 签名，原厂的 Developer ID 身份会改变。新版 macOS 仍可能阻止重新签名后的微信访问自己的数据目录。处理方法：

1. 打开 **系统设置 → 隐私与安全性 → 完全磁盘访问权限**。
2. 点击 `+`，添加 `/Applications/WeChat.app`。
3. 打开微信旁边的开关。
4. 重新打开微信。

如果列表里已经有微信，先用 `−` 删除，再重新添加。微信升级或重新安装补丁后，偶尔需要再做一次。

### 安装时提示微信仍在运行

先完全退出微信再安装或恢复。不要在微信运行时修改程序文件，否则系统可能直接关闭微信进程。

### 微信升级后防撤回消失

这是正常现象，微信升级会替换已经修改的文件：

1. 打开「微信防撤回」。
2. 拉取最新补丁数据。
3. 确认新构建号已受支持。
4. 退出微信并重新安装。

### 安装成功，但真实撤回没有生效

先确认：

- 微信已经完全退出并重新打开；
- 测试的是别人撤回的消息；
- 当前构建号与首页显示一致；
- 没有在安装后又升级微信。

然后展开底部的「查看详情」，保存最后一段日志并提交 issue。

---

## 常见问题

### 会上传聊天内容吗？

撤回内容匹配在微信进程本地完成，缓存只存在于当前进程。调试探针默认关闭；开启后会把撤回 XML 和相关元数据写入本机 macOS Console。「撤回记录」默认关闭；开启后会把撤回提示和内容预览写入微信容器目录里的本地文件，不会上传。

### 会影响我自己撤回消息吗？

自定义提示只处理别人撤回的消息。你自己撤回时仍使用微信原来的提示。

### 需要关闭 SIP 吗？

不需要。工具只修改「应用程序」中的微信，不修改 macOS 系统文件。

### 支持 Intel Mac 吗？

当前发布的 GUI 只支持 Apple Silicon（M 系列）Mac。

### 如何查看详细操作过程？

点击窗口底部的 **「查看详情」**，可以看到检测、安装、签名和恢复日志。

---

<details>
<summary><strong>查看当前支持的微信构建号</strong></summary>

工具按微信的内部**构建号**精确匹配。你不需要手动查找，GUI 首页会自动检测。

| 微信版本 | 构建号 | 静默防撤回 | 自定义提示 | `{content}` 内容预览 | 屏蔽自动更新 | 历史多开补丁 |
| --- | --- | :---: | :---: | :---: | :---: | :---: |
| 较早构建 | `268575` | ✅ | — | — | ✅ | ✅ |
| 较早构建 | `268596` | ✅ | — | — | ✅ | — |
| 较早构建 | `268597` | ✅ | ✅ | — | ✅ | — |
| 较早构建 | `268599` | ✅ | ✅ | — | ✅ | — |
| 较早构建 | `268601` | ✅ | ✅ | — | ✅ | — |
| 较早构建 | `268602` | ✅ | ✅ | — | ✅ | — |
| 较早构建 | `268831` | ✅ | ✅ | — | — | — |
| 4.1.10 | `268849` | ✅ | ✅ | — | ✅ | — |
| 4.1.10 | `268850` | ✅ | ✅ | — | ✅ | — |
| 4.1.10 | `268851` | ✅ | ✅ | — | ✅ | — |
| 4.1.11 | `269077` | ✅ | ✅ | — | ✅ | — |
| 4.1.11 | `269079` | ✅ | ✅ | — | ✅ | — |
| 4.1.11 | `269110` | ✅ | ✅ | — | ✅ | — |
| 4.1.12 | `269332` | ✅ | ✅ | — | ✅ | — |
| 4.1.12 | `269333` | ✅ | ✅ | — | ✅ | — |
| 4.1.12 | `269334` | ✅ | ✅ | — | ✅ | — |
| 4.1.12 | `269338` | ✅ | ✅ | — | ✅ | — |
| 4.1.12 | `269340` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.12 | `269341` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269574` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269575` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269576` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269577` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269578` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269579` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269619` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269624` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.13 | `269628` | ✅ | ✅ | ✅ | ✅ | — |
| 4.1.15 | `270090` | 支持 | 支持 | 支持 | 支持 | — |
| 4.1.15 | `270100` | 支持 | 支持 | 支持 | 支持 | — |
| 4.1.15 | `270102` | 支持 | 支持 | 支持 | 支持 | — |
| 4.1.15 | `270132` | 支持 | 支持 | 支持 | 支持 | — |
| 4.1.15 | `270133` | 支持 | 支持 | 支持 | 支持 | — |
| 4.1.15 | `270135` | 支持 | 支持 | 支持 | 支持 | — |

说明：

- ✅ 表示该构建号支持；`—` 表示暂未支持。
- `{content}` 内容预览包括文字原文以及 `[图片]`、`[视频]`、`[语音]` 等媒体类型。
- 表中的“历史多开补丁”是旧式原地多开方式；GUI「微信多开」使用独立副本，**不依赖构建号，所有版本都能使用**。

</details>

<details>
<summary><strong>进阶用户：命令行</strong></summary>

## 进阶用户命令行

以下命令在仓库根目录执行，通过 `swift run` 运行 CLI，无需打包图形 App，也不依赖 `dist` 目录。

### 构建

```bash
swift build -c release --product WeChatAntiRecallRuntime
WXAR_RUNTIME="$(swift build -c release --show-bin-path)/libWeChatAntiRecallRuntime.dylib"
```

要求 macOS 12+、Swift 5.9+。

`swift run -c release wechat-antirecall` 会按需构建 CLI。运行组件路径通过 `--show-bin-path` 获取，不硬编码 SwiftPM 输出目录。安装前先完全退出微信；以下命令以普通用户运行。若系统拒绝访问微信设置，请为执行命令的终端（如 Terminal、iTerm 或 Warp）开启「完全磁盘访问」，退出并重新打开终端后重试。不要用 `sudo` 运行红包或提示设置命令，否则可能写入 root 用户的配置；`sudo` 也不能绕过 macOS 隐私权限。

### 查看版本和支持状态

```bash
swift run -c release wechat-antirecall versions --app /Applications/WeChat.app --config ./patches.json
```

### 只检查，不修改

```bash
swift run -c release wechat-antirecall install --dry-run --app /Applications/WeChat.app --config ./patches.json
```

### 安装静默防撤回

```bash
swift run -c release wechat-antirecall install --app /Applications/WeChat.app --config ./patches.json
```

### 安装自定义提示并屏蔽更新

```bash
swift run -c release wechat-antirecall tip-phrase set "已拦截 {from} 于 {time} 撤回：{content}" --app /Applications/WeChat.app
swift run -c release wechat-antirecall install \
  --runtime-tip \
  --runtime-dylib "$WXAR_RUNTIME" \
  --config ./patches.json \
  --block-update \
  --app /Applications/WeChat.app
```

### 创建多开副本

```bash
swift run -c release wechat-antirecall clone \
  --count 2 \
  --output-dir /Applications \
  --app /Applications/WeChat.app
```

### 自动红包设置

**先完全退出微信**。以下命令可独立执行：构建组件、安装防撤回与红包运行组件，然后开启自动红包。步骤通过 `&&` 串联，安装失败就不会继续开启。安装会自动备份并重新签名微信；不屏蔽更新，不改变自定义提示短语。

```bash
swift build -c release --product WeChatAntiRecallRuntime && \
swift run -c release wechat-antirecall install \
  --app /Applications/WeChat.app \
  --config ./patches.json \
  --runtime-tip \
  --runtime-dylib "$(swift build -c release --show-bin-path)/libWeChatAntiRecallRuntime.dylib" && \
swift run -c release wechat-antirecall red-packet on \
  --app /Applications/WeChat.app --delay-ms 500 && \
swift run -c release wechat-antirecall red-packet get \
  --app /Applications/WeChat.app --json
```

最后的 JSON 应显示 `settings.enabled: true`、`supported: true`、`runtimeAvailable: true`，然后重新打开微信。**此开关会自动发起普通红包的领取请求**；实际领取结果以微信显示为准。`--delay-ms` 可设为 0–5000，省略时保留当前等待时间，初始值为 500 毫秒。安装成功但设置写入失败时，先解决终端的完全磁盘访问权限，再单独重试上面的 `red-packet on` 和 `get`；不要重置微信配置。

查看设置和运行组件是否包含此功能：

```bash
swift run -c release wechat-antirecall red-packet get --app /Applications/WeChat.app --json
```

关闭自动红包：

```bash
swift run -c release wechat-antirecall red-packet off --app /Applications/WeChat.app
```

`red-packet` 设置命令使用普通用户权限；支持 `--app` 指定目标微信。目前仅适配构建 269624、269628、270090、270100、270102、270132、270133 与 270135。`get` 显示配置和组件检测结果。

### 撤回记录设置

```bash
swift run -c release wechat-antirecall recall-log on --app /Applications/WeChat.app
swift run -c release wechat-antirecall recall-log list --limit 50 --app /Applications/WeChat.app
swift run -c release wechat-antirecall recall-log get --app /Applications/WeChat.app --json
swift run -c release wechat-antirecall recall-log off --app /Applications/WeChat.app
swift run -c release wechat-antirecall recall-log clear --app /Applications/WeChat.app
```

`on` 需要已安装包含撤回记录的自定义提示运行时（`get --json` 的 `runtimeAvailable` 为 `true`），开启后重启微信生效。`list` 最新的在前，`--limit` 取 1–1000，默认 200。读取日志需要终端有完全磁盘访问权限；`get` 在读不到日志时 `entryCount` 为空，但设置仍然可用。

### 密钥导出设置

```bash
swift run -c release wechat-antirecall key-export on --app /Applications/WeChat.app
swift run -c release wechat-antirecall key-export list --app /Applications/WeChat.app
swift run -c release wechat-antirecall key-export get --app /Applications/WeChat.app --json
swift run -c release wechat-antirecall key-export export --output ~/.wx-cli/all_keys.json --app /Applications/WeChat.app
swift run -c release wechat-antirecall key-export off --app /Applications/WeChat.app
```

`on` 需要已安装包含密钥导出的自定义提示运行时（`get --json` 的 `runtimeAvailable` 为 `true`）。开启后运行组件最多 30 秒写出第一份密钥快照（微信需已登录），每 10 分钟自动刷新。`export` 按盐值把密钥配对到 `xwechat_files` 下的数据库文件，生成 wx-cli 的 `all_keys.json`（默认 `~/.wx-cli/all_keys.json`，0600 权限）。读取快照需要终端有完全磁盘访问权限。

### 关键词提醒设置

```bash
swift run -c release wechat-antirecall keyword-alert on --keyword 红包 --keyword 紧急 --app /Applications/WeChat.app
swift run -c release wechat-antirecall keyword-alert set --keyword 红包 --keyword 紧急 --app /Applications/WeChat.app
swift run -c release wechat-antirecall keyword-alert get --app /Applications/WeChat.app --json
swift run -c release wechat-antirecall keyword-alert off --app /Applications/WeChat.app
```

`on` 需要已安装包含关键词提醒的自定义提示运行时（`get --json` 的 `runtimeAvailable` 为 `true`），且当前构建已适配（`supported`）；`--keyword` 可重复，省略时沿用已保存的列表。`set` 只改关键词列表，不改开关；不带 `--keyword` 会清空列表（开启状态下不允许清空）。`off` 保留关键词。设置在重启微信后生效。

### 窗口隐私设置

```bash
swift run -c release wechat-antirecall window-privacy on --app /Applications/WeChat.app
swift run -c release wechat-antirecall window-privacy get --app /Applications/WeChat.app --json
swift run -c release wechat-antirecall window-privacy off --app /Applications/WeChat.app
```

`on` 需要已安装包含窗口隐私的自定义提示运行时（`get --json` 的 `runtimeAvailable` 为 `true`）。开关通过 `CFPreferences` 写入，运行中的微信约每半秒读取一次，所以不需要重启。

### 从备份恢复

```bash
swift run -c release wechat-antirecall restore \
  --binary Contents/Resources/wechat.dylib \
  --backup /Applications/WeChat.app/Contents/Resources/wechat.dylib.wechat-antirecall-backup-YYYYMMDD-HHMMSS \
  --app /Applications/WeChat.app
```

完整参数：

```bash
swift run -c release wechat-antirecall help
```

</details>

<details>
<summary><strong>开发者：从源码构建图形界面</strong></summary>

```bash
bash Scripts/make-icon.sh
bash Scripts/make-app.sh
open dist/WeChatAntiRecall.app
```

底层实现、补丁配置、逆向记录、新构建适配方法和发布流程见 **[MAINTAINING.md](MAINTAINING.md)**。

</details>

---

## 相关项目

- [sunnyyoung/WeChatTweak-macOS](https://github.com/sunnyyoung/WeChatTweak-macOS)
- [tanranv5/WeChatTweak](https://github.com/tanranv5/WeChatTweak)
- [zetaloop/BetterWX](https://github.com/zetaloop/BetterWX)
- [X1a0He/X1a0HeWeChatPlugin](https://github.com/X1a0He/X1a0HeWeChatPlugin)

## 友链

- [linux.do](https://linux.do) —— 新的理想型社区
