# 维护指南

面向维护者：`patches.json` 结构、各补丁目标的含义、运行时 hook 的两种机制、屏蔽更新补丁点的逆向来源、逐字节核对记录、`{content}` 实现，以及**如何新增一个构建号**。

用户向的使用说明在 [README.md](README.md)。

自动红包的协议、对象布局与 ABI 证据见 [红包逆向记录](Docs/red-packet-269624.md)。该功能复用已有消息 finalizer hook，默认关闭；目前适配 269624、269628、270090、270100、270102、270132、270133、270135、270352 与 270390，范围独立于防撤回构建表。用户已在 270090 实测确认防撤回与自动红包可用。

---

## patches.json 结构

`patches.json` 沿用 WeChatTweak / 社区 fork 的 Mach-O 字节补丁思路，补充了微信 4 的防撤回、提示、多开和屏蔽更新目标。

```json
{
  "version": "268596",
  "targets": [
    {
      "identifier": "revoke",
      "binary": "Contents/Resources/wechat.dylib",
      "entries": [
        { "arch": "arm64", "addr": "47647a0", "expected": "E00F0034", "asm": "7F000014" }
      ]
    }
  ]
}
```

字段：

| 字段 | 说明 |
| --- | --- |
| `version` | 微信构建号（`CFBundleVersion`），工具据此匹配。 |
| `targets[].identifier` | 补丁目标名（见下表），决定被哪些命令行参数选中。 |
| `targets[].binary` | 相对 App bundle 的二进制路径；省略时默认 `Contents/MacOS/WeChat`。微信 4 的防撤回目标都在 `Contents/Resources/wechat.dylib`。 |
| `entries[].arch` | `arm64` 或 `x86_64`。 |
| `entries[].addr` | 十六进制虚拟地址（切片内 vmaddr）。 |
| `entries[].asm` | 要写入的补丁字节（十六进制）。 |
| `entries[].expected` | 补丁前的原始字节，单个字符串或字符串数组。工具写前会校验，不匹配就报错、不静默降级。 |

补丁应用逻辑在 `MachOPatcher`（`Sources/WeChatAntiRecall/CLI.swift`）：解析 fat / thin Mach-O，按段表把 `addr` 映射到文件偏移，校验 `expected` 后写入 `asm`。若当前字节已等于 `asm`，视为"已打补丁"跳过。

---

## 补丁目标（identifier）

| identifier | 含义 | 被哪个参数选中 |
| --- | --- | --- |
| `revoke` | 静默防撤回 | 默认（不加 tip 参数） |
| `revoke-tip` | 提示模式 | `--with-tip` |
| `runtime-tip` | 内联 hook 的入口改写（仅内联构建；269340/269341/269574/269575/269576/269577/269578/269579/269619/269624/269628/270090/270100/270102/270132/270133/270135/270352/270390 各含两处） | `--runtime-tip` |
| `update` | 屏蔽自动更新 | `--block-update` / `--update-only` |
| `multiInstance` | 多开（主二进制） | `--multi-instance` |
| `multiInstance-extra` | 多开的附加补丁（dylib） | `--multi-instance` |

目标选择逻辑在 `resolveTargets`（`CLI.swift`）。几个要点：

- `--update-only` 只选 `update`，与其它模式互斥。
- `revoke-tip` 的 `expected` 同时接受**原始字节**和**已装静默补丁的字节**（见 patches.json 里 `revoke-tip` 的数组 `expected`），这样能直接从静默模式切到提示模式。
- `runtime-tip` 目标**只在内联 hook 构建里存在**（`268849`+）。派发桩构建（`268597`–`268831`）没有这个目标，`--runtime-tip` 只做 dylib 注入。

---

## 防撤回补丁

`Contents/Resources/wechat.dylib` 里的 `parseRevokeXML` 是核心函数。

- **静默（`revoke`）**：把入口处一条分支 `E00F0034`（`cbz`）改成 `7F000014`（无条件跳转 / `b`），跳过删除原消息的逻辑。
- **提示（`revoke-tip`）**：入口保持 / 还原成 `E00F0034`，再把 `str x0,[x19,#0x168]`（`60B600F9`）改成 `str xzr,…`（`7FB600F9`），把 `newmsgid` 写零——微信因此保留原消息但仍显示撤回提示。

因为改的是 dylib 而非主二进制，`resign()` 会**先单独重签被 patch 的 dylib，再重签整个 App**，避免运行到被改代码页时触发 `Code Signature Invalid`。

---

## 自定义提示（runtime-tip）的两种机制

`--runtime-tip` 会把 `libWeChatAntiRecallRuntime.dylib` 拷进 `Contents/Resources/`，并往 `wechat.dylib` 注入一条 `LC_LOAD_DYLIB`（install name `@loader_path/libWeChatAntiRecallRuntime.dylib`）。dylib 加载后 hook `parseRevokeXML`，把别人撤回的提示替换成配置短语。挂载方式分两类（见 `Runtime.mm` 里的两张表）：

### 1. 派发桩（dispatch stub）—— 268597 ~ 268831

这些构建的 `parseRevokeXML` 保留了编译器插入的热修派发桩，runtime 直接复用它挂钩，**不需要静态改写入口**，所以 patches.json 里没有 `runtime-tip` 目标。配置在 `Runtime.mm` 的 `revokeHookConfigs`（build → 函数体地址 + `newMsgId`/`replaceMsg` 字段偏移 `0x168`/`0x170`）。

### 2. 内联 hook（inline hook）—— 268849+

这些构建去掉了派发桩，改用**静态入口改写 + 运行时 trampoline**：

- 安装时把目标函数入口的 3 条指令改成 `adrp x16,SLOT; ldr x16,[x16]; br x16`（patches.json 的 `runtime-tip` 目标；269340/269341/269574/269575/269576/269577/269578/269579/269619/269624/269628/270090/270100/270102/270132/270133/270135/270352/270390 同时改写撤回解析器和 Message 终结器）。`SLOT` 落在 `wechat.dylib` `__DATA` 段尾的零填充空隙里。
- runtime 的 constructor 注册 `_dyld_register_func_for_add_image`，覆盖已加载及随后加载的镜像。回调通过 `dladdr(header)` 精确匹配 `Contents/Resources/wechat.dylib`，使用传入的 header/slide 建立 trampoline（重放原 3 条指令、再跳回入口后第 4 条），在核心库初始化前把 hook 指针写进 `SLOT`。runtime 通过**解码被改写的入口**自动定位 `SLOT`，无需硬编码。
- 配置在 `Runtime.mm` 的 `inlineRevokeHookConfigs`（build → 入口地址、原始 3 条指令、continuation 地址、字段偏移）。

| build | 入口地址 | SLOT | 备注 |
| --- | --- | --- | --- |
| 268849 | `0x488c4c4` | `0x952bf00` | 微信 4.1.10 |
| 268850 | `0x488c4c4` | `0x952bf00` | 4.1.10 热修，逐字节等同 268849 |
| 268851 | `0x488c4c4` | `0x952bf00` | 4.1.10 热修，逐字节等同 268850 |
| 269077 | `0x48a4d68` | `0x93b3f00` | 微信 4.1.11，几何特征在整个 arm64 切片里唯一命中 |
| 269079 | `0x48a7c4c` | `0x93b7f00` | 微信 4.1.11 热修，**非**字节等同 269077（整片重定位），几何特征仍唯一命中 |
| 269110 | `0x4509eb8` | `0x986bf00` | 微信 4.1.11，补丁点和 SLOT 均从本构建重新定位 |
| 269332 | `0x462f420` | `0x9a53f00` | 微信 4.1.12，`parseRevokeXML` 被重编译（详见下方核对记录），字段偏移改为 `0x198`/`0x1A0` |
| 269333 | `0x463ed18` | `0x9a6bf00` | 微信 4.1.12 热修，整片重定位。与 269332 不同：`parseRevokeXML` 的几何特征仍逐字命中（无需参考二进制 diff），字段偏移仍 `0x198`/`0x1A0` |
| 269334 | `0x461d624` | `0x9a87f00` | 微信 4.1.12 热修；269332+ 几何特征仍唯一命中，字段偏移仍 `0x198`/`0x1A0` |
| 269338 | `0x462da00` | `0x9a9ff00` | 微信 4.1.12 热修；269332+ 几何特征仍唯一命中，字段偏移仍 `0x198`/`0x1A0`，屏蔽更新 8 处相对 269334 均匀 `+0x1000` |
| 269340 | `0x462e200` + `0x45ce1a4` | `0x9a9ff00` + `0x9a9ff08` | 微信 4.1.12 热修；撤回 XML hook 与通用 Message 终结器 hook 分离，后者填充 `{content}` 缓存 |
| 269341 | `0x462e60c` + `0x45ce5b0` | `0x9a9ff00` + `0x9a9ff08` | 微信 4.1.12 热修；撤回路径相对 269340 移动 `+0x40C`，更新方法和两个 SLOT 保持不变 |
| 269574 | `0x4905488` + `0x48a3b20` | `0x9ecbf00` + `0x9ecbf08` | 微信 4.1.13；解析器字段移动到 `0x1C8`/`0x1D0`，Message 字段仍为 `0xF8`/`0x0C`/`0x130` |
| 269575 | `0x4904ed0` + `0x48a3568` | `0x9ecbf00` + `0x9ecbf08` | 微信 4.1.13 热修；相对 269574 均匀 `-0x5B8`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269576 | `0x490521c` + `0x48a38b4` | `0x9ecbf00` + `0x9ecbf08` | 微信 4.1.13 热修；相对 269575 均匀 `+0x34C`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269577 | `0x4958824` + `0x48f64dc` | `0x9f57f00` + `0x9f57f08` | 微信 4.1.13.9；解析器相对 269576 `+0x53608`，终结器 `+0x52C28`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269578 | `0x495884c` + `0x48f6504` | `0x9f57f00` + `0x9f57f08` | 微信 4.1.13.10；相对 269577 均匀 `+0x28`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269579 | `0x4958830` + `0x48f64e8` | `0x9f57f00` + `0x9f57f08` | 微信 4.1.13.11；相对 269578 均匀 `-0x1C`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269619 | `0x497f908` + `0x491cb1c` | `0x9f9ff00` + `0x9f9ff08` | 微信 4.1.13.51；解析器相对 269579 `+0x270D8`，终结器 `+0x26634`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269624 | `0x49adcc8` + `0x494aedc` | `0xa03ff00` + `0xa03ff08` | 微信 4.1.13.56；解析器与终结器相对 269619 均匀 `+0x2E3C0`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 269628 | `0x49aef90` + `0x494c1a4` | `0xa043f00` + `0xa043f08` | 微信 4.1.13.60；解析器与终结器相对 269624 均匀 `+0x12C8`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 270090 | `0x4bbe5cc` + `0x4b5b0a0` | `0xa35ff00` + `0xa35ff08` | 微信 4.1.15.10；独立核对函数边界、字段及调用点，不能整体平移旧地址表 |
| 270100 | `0x4bc4d34` + `0x4b61808` | `0xa367ff0` + `0xa367ff8` | 微信 4.1.15.20；几何特征仍唯一命中。`__DATA` 在 `__common` 后只剩 `0x58` 字节空隙，SLOT 取段尾最后两个 qword |
| 270102 | `0x4bc5168` + `0x4b61c3c` | `0xa367ff0` + `0xa367ff8` | 微信 4.1.15.22；独立定位并经 IDA 9.4 核对。字段与空隙边界不变，解析器跨页后入口桩 ADRP 编码改变 |
| 270132 | `0x4d16ce8` + `0x4cb37bc` | `0xa533ff0` + `0xa533ff8` | 微信 4.1.15.52；独立定位并经 IDA 9.4 核对，所有入口及 DATA 槽重新编码 |
| 270133 | `0x4d15438` + `0x4cb1f0c` | `0xa51fff0` + `0xa51fff8` | 微信 4.1.15.53；独立定位并经 IDA 9.4 核对。相对 270132 并非均匀平移（解析器/终结器 `-0x18B0`，更新方法 `-0x2000`，`__DATA` 缩小），所有入口及 DATA 槽重新编码 |
| 270135 | `0x4d1f8d8` + `0x4cbc3ac` | `0xa52bff0` + `0xa52bff8` | 微信 4.1.15.55；独立定位并经 IDA 9.4 核对。相对 270133 并非均匀平移，所有入口及 DATA 槽重新编码 |
| 270352 | `0x4e7d4dc` + `0x4e1a094` | `0xa68bff0` + `0xa68bff8` | 微信 4.2.0.16；独立定位，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |
| 270390 | `0x4613ec4` + `0x45c0b2c` | `0x9e2fff0` + `0x9e2fff8` | 微信 4.2.0.54；解析器重新编译，守卫移至 `+0x278`、字段写入移至 `+0xA40`，字段偏移不变 |

⚠️ **入口改写和 dylib 注入必须成对安装**：`--runtime-tip` 会一起完成二者，`RuntimeTipInstaller` 先跑注入。绝不要单独只打入口补丁——缺少 dylib 时 `SLOT` 不会被赋值，函数会跳空指针崩溃。`restore` 恢复 `wechat.dylib` 备份会同时撤销所有入口补丁、`SLOT` 和注入。

内联 hook 引擎（指令编码、trampoline、跳转槽派发）有单元测试覆盖（`InlineHookEngineTests`、`RuntimeRewriteTests`）。

2026-09-13 修复 **270090 启动闪退**：实际加载器会先加载 runtime 依赖，此时系统 dyld 列表还没有核心库。旧 constructor 只枚举一次便返回，两个 SLOT 留为零；收到消息时 `0x4B5A1EC` 调用终结器，入口 `BR X16` 因 `X16=0` 崩溃（LR=`core+0x4B5A1F0`）。同步 add-image 回调解决的是加载时序，不改变补丁地址或字段布局；不能改成主队列异步重试或固定延迟，因为第一次核心函数调用可能先发生。

修复验证使用独立 bundle ID 的真实微信副本：LLDB 确认 `wechatImageAdded` 位于 `dyld4::RuntimeState::notifyLoad` 调用栈中，两个 SLOT 在 `WeChatMain` 前写入；用已终结的合成 Message 调用原闪退入口成功返回，随后到达扫码登录界面；173 项现有测试通过。上述自动化验证未登录真实账号；随后用户在 270090 实测确认防撤回和普通红包自动领取均可用。调试证据在 `work/20260913-runtime-startup-crash/evidence/`。修复需要重新安装新版 runtime，`patches.json` 及其校验和不变。

---

## `{content}` 实现

对上表已配置双 hook 的 arm64 构建（269340/269341/269574/269575/269576/269577/269578/269579/269619/269624/269628/270090/270100/270102/270132/270133/270135/270352/270390）的聚焦分析确认：撤回 XML 解析器服务消息扩展类型 `71/72`，不是所有接收消息的公共路径；输出对象里的 `newmsgid` 也不能当作普通 Message 的 server ID。269340/269341 的字段为 `+0x198`；其余上述构建为 `+0x1C8`，`replaceMsg` 为 `+0x1D0`。各构建入口地址见上表。

真正的接收路径使用第二个内联 hook。270090 的 `sub_4B5B0A0` 与 270100 的 `sub_4B61808` 是通用 Message 终结器。270090 网络消息构造函数 `sub_4B59D48` 在 `0x4B5A1EC`、270100 的 `sub_4B604B0` 在 `0x4B60954`、270102 的 `sub_4B608E4` 在 `0x4B60D88`、270132 的 `sub_4CB2464` 在 `0x4CB2908`、270133 的 `sub_4CB0BB4` 在 `0x4CB1058` 调用终结器之前已填好：

- `serverId`：Message `+0xF8`；
- `msgType`：Message `+0x0C`；
- `content`（`std::string`）：Message `+0x130`。

构造函数随后无条件调用终结器；runtime 在原终结器之前按 `serverId` 缓存：文本做 trim 和 UTF-8 边界安全截断；媒体使用真实 `msgType` 映射为图片、语音、视频、动画表情、位置、链接、音视频通话或系统消息占位符。撤回 XML 到来时再用其中的 `<newmsgid>` 查表并替换 `{content}`。

双 hook 的两个 SLOT 地址见上表，270090 使用 `0xa35ff00` 与相邻的 `0xa35ff08`，270100 / 270102 使用 `0xa367ff0` 与 `0xa367ff8`，270132 使用 `0xa533ff0` 与 `0xa533ff8`，270133 使用 `0xa51fff0` 与 `0xa51fff8`，270135 使用 `0xa52bff0` 与 `0xa52bff8`。缓存只存在于当前微信进程，最多 512 条；文本预览最多 240 个 UTF-8 字节。冷启动前收到、已淘汰或 server ID 为 0 的消息仍会 miss，此时 `replaceContentPlaceholder` 会连同分隔符一起剥掉。其他已支持构建尚未反向确认通用 Message 字段布局，因此仍按冷缓存处理 `{content}`。

---

## 撤回记录（recall-log）

默认关闭的本地清单，与撤回提示共用 `parseRevokeXML` hook，**不新增任何每构建地址**。

- **设置**：偏好键 `WeChatAntiRecall_RecallLog` = `{enabled: Bool}`，由 CLI 经 `CFPreferences` 写入微信域（与 `tip-phrase`、`red-packet` 同一条路径）。runtime 在每次撤回时用 `CFPreferencesCopyAppValue` 读取，缺失、类型不是严格布尔或字典损坏都视为关闭，所以关闭立即生效，无需重启微信。
- **挂载点**：`hookedParseRevokeXML` 在 `selfRecall` 提前返回**之后**、改写提示**之前**调用 `recall_log::record`。自己的撤回不记录。`{content}` 的缓存查询被提到这里，记录和提示共用同一次查询。
- **文件**：`<容器>/Library/Application Support/WeChatAntiRecall/recall-log.jsonl`（目录 0700、文件 0600，`O_NOFOLLOW`）。微信有沙盒，所以 runtime 里的 `NSHomeDirectory()` 就是容器；CLI 按 `~/Library/Containers/<bundle id>/Data/…` 读取，多开副本因 bundle id 不同各有一份。
- **格式**：每行一个 JSON 对象，键有序，`v` 为 1。字段：`loggedAt`（本机观察到撤回的 Unix 秒）、`createTime`（撤回 XML 里的 `createtime`，可为 null；**未核实它是原消息时间还是撤回时间**，所以界面只显示 `loggedAt`）、`session`、`msgId`、`newMsgId`（十进制字符串，避免 64 位精度问题）、`notice`（微信渲染好的提示，最长 512 字节）、`content`（接收路径缓存的预览，null 表示冷缓存，不等于空消息）。读取端跳过无法解析或 `v` 不是 1 的行并计数。
- **去重与轮转**：runtime 在进程内记住最近 256 个 `newmsgid`，跳过微信重复下发的同一条撤回；读取端再按 `newMsgId` 去重（跨重启）。单个文件超过 2 MiB 时重命名为 `recall-log.1.jsonl`（覆盖旧的一份），所以最多保留约两倍大小。写入走专用串行队列，不阻塞消息线程。
- **运行时标记**：`WeChatAntiRecallRecallLog:2`（`wechat_antirecall_recall_log_runtime_version`）。CLI 在已安装的 dylib 里搜索它来判断 `runtimeAvailable`；改变日志格式、语义或所需构建 hook 时递增。版本 2 新增微信 4.2 hook，日志格式仍为 1。
- **权限**：GUI/CLI 读取别人的容器可能需要完全磁盘访问；读不到时 CLI 抛出含「权限」「完全磁盘访问」的错误，GUI 据此显示授权引导。
- **测试**：`RecallLogTests` 覆盖编码（含非法 UTF-8、截断）、去重、轮转、符号链接拒绝、严格布尔设置、生产路径的开关行为，以及 runtime 写出的行能被 Swift 读取端解析。真实撤回需要两个账号，目前只做了离线验证。

---

## 密钥导出（key-export）

默认关闭的本地密钥快照，**不挂任何 hook、不新增任何每构建地址**——模式匹配独立于微信版本，微信更新后只要密钥仍是 `x'…'` 形态就继续工作。

- **动机**：数据库工具（wx-cli 等）通常用 `task_for_pid` 扫微信内存提取 SQLCipher raw key，这要求微信是 ad-hoc 签名并带来 TCC/重签副作用（见 wx-cli 的 macOS 权限指南）。本 runtime 已在微信进程内，扫 `mach_task_self()` 零权限。
- **触发**：`KeyExport.mm` 自己的 constructor 起一个 30 秒间隔的 dispatch timer（leeway 5 秒）。每次 fire 在专用串行队列上检查节流（成功后 10 分钟、尝试后 60 秒内跳过）→ 读偏好开关（`WeChatAntiRecall_KeyExport` = `{enabled: Bool}`，严格布尔，与 recall-log 同一条 CFPreferences 路径）→ 扫描。constructor 只注册 timer，不碰微信内部状态，所以不受加载时序影响（对比 MAINTAINING 2026-09-13 的 constructor 教训）。
- **扫描**：`mach_vm_region(mach_task_self())` 枚举 RW 区域，`mach_vm_read` 按 2 MiB 分块（保留 99 字节全模式重叠防跨块），匹配 `x'` + 96 个 hex + `'`（64 key + 32 salt），小写化、按 key+salt 去重。与 wx-cli `scanner/macos.rs` 的 matcher 语义一致。`VM_REGION_BASIC_INFO_COUNT_64` 硬编码 9（历史坑，不能 sizeof）。
- **文件**：`<容器>/Library/Application Support/WeChatAntiRecall/keys.json`（目录 0700、临时文件 0600 + `O_NOFOLLOW`，写完 `rename` 原子替换）。格式 `{"v":1,"dumpedAt":<unix>,"keys":[{"key","salt"}]}`。快照是覆盖写不是追加，读取端要么看到旧快照要么看到新的。
- **CLI**：`key-export get|on|off|list|export`。`export` 在 CLI 侧做 salt→db 配对：递归扫 `~/Library/Containers/<bundle id>/Data/Documents/xwechat_files` 下 `.db` 前 16 字节 salt（`SQLite format 3` 开头的明文库跳过），生成 wx-cli 的 `all_keys.json`（`{"<相对路径>":{"enc_key":…}}`，默认 `~/.wx-cli/all_keys.json`，0600）。**相对路径用双方 `resolvingSymlinksInPath` 后的 pathComponents 前缀比较计算**——FileManager 目录 API 返回解析了 symlink 的 URL（`/var → /private/var`），字符串 `dropFirst` 会错位（`/tmp` 测试环境实测踩坑）。
- **运行时标记**：`WeChatAntiRecallKeyExport:1`（`wechat_antirecall_key_export_runtime_version`），CLI 搜索已安装 dylib 判断 `runtimeAvailable`。
- **安全边界**：密钥只在用户自己的设备上、用户显式开启后导出；`keys.json`/`all_keys.json` 等价于明文凭据（README 已注明）。扫描只读自身进程内存，写只落容器内目录。
- **测试**：`KeyExportTests` 覆盖 pattern 匹配（大小写、非法 hex、引号、去重、垃圾嵌入、2 MiB 边界）、**真实 mach 路径端到端**（测试进程堆上植入 pattern，`scan_self_for_test` 必须扫到）、原子写与权限、严格布尔设置、CLI 文件解析、salt 配对（明文/截断跳过、symlink 相对路径）、选项解析。

---

## 关键词提醒（keyword-alert）

默认关闭的本地通知，挂在**通用 Message 终结器** hook 上（`hookedFinalizeMessage` 在原终结器和红包观察之后调用 `wechat_antirecall_keyword_alert_observe`），**不新增任何每构建地址**。

- **读取 Message 字段**：`MessageProbe.h` 的 `message_probe::readReceived`，实现在 `RedPacket.mm`，因为只有红包模块持有每构建的 profile（`messageVtable` 比对 + 632 字节布局检查）。偏移：`type +0x0C`、`serverId +0xF8`、`from +0x18`（单聊为发送者，群聊为 `@chatroom` 群 ID）、`to +0x30`（接收账号）、`created +0x114`、`content +0x130`。所以此功能只在有红包 profile 的构建上可用，CLI 的 `supported` 即 `RedPacketSettings.supportedBuilds`；**新增红包构建时这里自动跟随，但要确认上述偏移**。
- **设置**：偏好键 `WeChatAntiRecall_KeywordAlert` = `{enabled: Bool, keywords: [String]}`。runtime 严格解析：`enabled` 必须是真布尔，关键词必须已 trim、1–32 个 UTF-16 单元、无控制字符、最多 20 个，**任何一项不合格整份设置视为无效并保持关闭**。CLI 保存前用同样的规则归一化（trim、去重忽略大小写）。设置每秒最多重读一次。
- **新鲜度**：复用 `red_packet::fresh`（60 秒窗口，且 `created` 不得早于开启时刻）。启动时的基线是 runtime 加载时刻，所以登录同步的历史消息不会提醒；运行中从关到开则取当时。
- **匹配**：只看 `type == 1` 的文字。群聊（`from` 以 `@chatroom` 结尾）先剥掉 `sender:\n` 前缀再匹配，避免关键词命中发送者账号；单聊不剥，因为正文里可能自带 `x:\ny`。比较用 `NSCaseInsensitiveSearch | NSWidthInsensitiveSearch`，按配置顺序取第一个命中。预览取正文前 80 个字（按字符簇截断，换行压成空格）。
- **自己发的消息**：必须满足 `to == 当前账号` 且 `from != 账号` 且群前缀发送者 `!= 账号`。账号来自红包模块的 `Api::account()`，这是调用 WeChat 的原生函数，**只能在主队列调用**，所以字段先在消息线程拷贝出来，匹配之后再 `dispatch_async` 到主队列做账号、新鲜度、`serverId` 去重（复用 `red_packet::Ledger`）并发通知。
- **通知**：`UNUserNotificationCenter`，沿用红包“仅提醒”的授权流程；授权往返期间设置或新鲜度可能变化，所以投递前在主队列再检查一次。标题 `关键词提醒：<词>`，正文为预览。**拿不到聊天名称**：Message 里只有群 ID，没有昵称；和红包提醒一样不显示原始 ID。
- **运行时标记**：`WeChatAntiRecallKeywordAlert:2`，CLI 在已安装的 dylib 里搜索它判断 `runtimeAvailable`。版本 2 新增微信 4.2 的 Message hook 与原生 profile，旧组件必须更新。
- **测试**：`KeywordAlertTests` 覆盖严格设置解析、匹配（类型、大小写、全角、顺序、群前缀、预览截断）、自发消息过滤、CLI 选项和偏好存储，并核对 CLI 写出的值能被 runtime 接受。观察路径本身依赖真实的 Message 对象，只有真机能验证；尚未在真实微信里实测。

---

## 窗口隐私（window-privacy）

默认关闭。**不新增任何每构建地址，也不 hook WeChat 的函数**：只用公开的 AppKit 属性 `NSWindow.sharingType`。

- **为什么不 hook `SetWindowSharingPolicy`**：270135 的 0x474ee58（`device_util_mac.mm`）确实是微信设置该属性的唯一入口，但那样每个构建都要重新定位。微信通过 `objc_msgSend` 调用 `setSharingType:`，而我们只需要让**所有**窗口都隐藏，不必拦截它的调用，直接在窗口上设置即可。
- **机制**：`wechatImageAdded` 在发现微信核心库加载时调用 `wechat_antirecall_window_privacy_start`，**早于**撤回 hook 的安装，所以不受 hook 是否支持该构建的影响。它在主队列上起一个 0.5 秒的定时器，遍历 `NSApp.windows`；另外订阅 `NSWindowDidBecomeKey/Main/Expose`，窗口一变成前台就立刻处理，缩短新窗口的露出时间。
- **设置**：偏好键 `WeChatAntiRecall_WindowPrivacy` = `{enabled: Bool}`，严格布尔，其余一律视为关闭。只读 cfprefsd，**不做 plist 回退**，因为这里每秒读两次，反复解析整份偏好文件不划算；CLI 本来就经 cfprefsd 写入。
- **恢复**：第一次改某个窗口前，用弱引用表记下它原来的 `sharingType`；关闭时只恢复表里的窗口。微信自己已经设成 `none` 的窗口不记录、不恢复，所以不会被暴露。如果微信在我们隐藏之后又把窗口设回别的值，下次扫描会重新隐藏，并把那个新值当作要恢复的值。
- **已知限制**：效果取决于捕获端和 macOS 版本（没有在录屏软件里实测过）；微信自带截图也会看不到微信窗口；系统绘制的通知横幅不受影响；窗口出现到被处理之间有极短的间隙。
- **运行时标记**：`WeChatAntiRecallWindowPrivacy:1`。runtime 现在额外链接 AppKit（`Package.swift`）；微信本身已加载 AppKit，所以不增加依赖。
- **测试**：`WindowPrivacyTests` 用真实的离屏 `NSWindow` 跑和定时器相同的 `sweep`：隐藏与恢复、保留窗口原值、不碰已被微信隐藏的窗口、微信重新设置后的重新隐藏、重复开启不丢原值；没有窗口服务（无图形会话）时这几项会跳过。

---

## 屏蔽更新（update）

补丁点是在相关更新函数入口写 `ret`（`C0035FD6`），或把强制更新开关的访问器改成返回 0 / 直接 `ret`。各构建号的推导来源不同：

- **268601 系**：与已验证的 `268601` 对应同一组函数，8 处除地址重定位外字节完全一致，1 处（`0x1d2a2c`）为同一函数、入口之后有改动，但补丁在函数入口写 `ret`、改动部分被跳过。
- **269077**：手头没有 `268849` 系参考 `wechat.dylib`（4.1.10 DMG 是 `268831` 派发桩构建），所以不是按字节 diff 得到的，而是解析 `XAppUpdateManager` 这个 Objective-C 类的 selector→IMP 表、按方法名定位（已在 `268831` 二进制上交叉核对：同名方法、同样的入口指令）。共 8 处：4 个触发方法入口写 `ret`（`startUpdater`、`checkForUpdates:`、`startBackgroundUpdatesCheck:`、`enableAutoUpdate:`），外加两个强制更新开关访问器——`automaticallyDownloadsUpdates`（字段 `0x18`）、`canCheckForUpdate`（字段 `0x19`）的 getter 改成返回 0、setter 改成 `ret`。

注意：

- `268831` **没有** `update` 目标（当时未回归），所以它不支持 `--block-update`。
- 微信 4.1.10 另带 Sparkle（`SPUUpdater`）更新通道，本补丁**不覆盖**。
- 屏蔽更新的运行时效果尚未在全部构建号上回归，安装后请手动"检查更新"确认。

---

## 逐字节核对记录

历史条目中的“当前安装”指各次分析当日。2026-09-13 核对 `LC_FUNCTION_STARTS` 后纠正：269628 的完整解析器也是 `0x111C`（4380）字节；旧记录的 4072 字节是当时的定向分析窗口，不是完整函数边界。270090 同样为 `0x111C`，不能把固定窗口结束位置当成新版本函数增长的证据。

- **270352 / 270390**：2026-11-13 分别对本机微信 4.2.0.16 与官网下载的 4.2.0.54 独立适配。270390 的解析器和多处红包函数已重编译，不能整体平移旧表。样本校验和、完整地址、调用链、组件版本与验证边界见 [微信 4.2 适配记录](Docs/wechat-4.2.md)。

- **268850 / 268851**：是 `268849` 的连续热修，全部 12 个补丁点 + `SLOT` 零填充槽位都逐字节一致（已对各自的 `wechat.dylib` 逐地址核对），配置直接复用 `268849`。
- **269077**：`parseRevokeXML` 函数体不变（入口 `stp x24,x23` 等三条 + `entry+0x270` 的 `cbz w0` + `entry+0xA04` 的 `str x0,[x19,#0x168]`），整体重定位到 `0x48a4d68`；三处补丁点（`revoke` `0x48a4fd8`、`revoke-tip` `0x48a576c`、内联 hook 入口 `0x48a4d68`）原始字节都已逐地址核对。
- **269079**：4.1.11 热修，**不是**字节等同 269077——整片重定位，所有站点都移位。`parseRevokeXML` 函数体不变（同一入口三条 `stp` + `entry+0x270` 的 `cbz w0` + `entry+0xA04` 的 `str x0,[x19,#0x168]`），整体重定位到 `0x48a7c4c`，几何特征在整个 arm64 切片里仍唯一命中。字段偏移 `0x168`/`0x170` 是**从本二进制里的 `str`/`ldr` 指令重新解码**得到的（非照抄）。防撤回三处补丁点（`revoke` `0x48a7ebc`、`revoke-tip` `0x48a8650`、内联 hook 入口 `0x48a7c4c`）原始字节逐地址核对；SLOT 取 `__common` 之后的 `__DATA` 尾部零填充 `0x93b7f00`，`adrp/ldr/br` 编码经 `decodeEntryStubSlot` 逻辑回环验证。屏蔽更新 8 处经 `XAppUpdateManager` selector→IMP 重新定位，各站点入口字节与 269077 语义一致（同前缀、访问器字段 `0x18`/`0x19`）。
- **269110**：4.1.11 构建，`parseRevokeXML` 几何特征在 arm64 切片中唯一命中，入口为 `0x4509eb8`，`revoke` 为 `0x450a128`，`revoke-tip` 字段写入为 `0x450a8bc`。SLOT `0x986bf00` 位于 `__common` 结束地址 `0x986a258` 与 `__DATA` 结束地址 `0x986c000` 之间的零填充，入口桩回环解码到同一地址。屏蔽更新的 8 个地址通过本构建的 `XAppUpdateManager` 相对方法表按 selector→IMP 重新解析，原始入口字节和字段 `0x18`/`0x19` 均逐点核对。
- **269332**：微信 4.1.12，**`parseRevokeXML` 被重新编译**——旧的几何特征（入口 `stp x24,x23` + `cbz w0` 在 `entry+0x270` + `str x0,[x19,#0x168]` 在 `entry+0xA04`）不再逐字命中，整片也重定位。定位方式是**对参考二进制做 diff**：从腾讯 CDN 取 4.1.11（`WeChatMac_4.1.11.dmg`，实测为构建 `269111`，`parseRevokeXML` 入口 `0x4509ed4`，几何特征仍唯一命中），把该函数体按"屏蔽地址相关立即数后的指令形状"在 4.1.12 切片里滑窗匹配，唯一强命中在 `0x462f420`（匹配率 0.76，次优仅 0.17；入口前缀仍是 `stp x24,x23 / stp x22,x21 / stp x20,x19`）。`cbz w0` 守卫仍在 `entry+0x270`（`0x462f690`），但其后被编译器插入了一次调用，把 `newmsgid` 写入下推到 `entry+0xA10`（`0x462fe30`）。**关键：消息结构体布局变了**——`newMsgId` 从 `0x168` 移到 `0x198`，`replaceMsg`（`std::string`）从 `0x170` 移到 `0x1A0`。两个偏移都从**本二进制**的 `str`/`ldr` 指令重新解码：`newmsgid` 写入是 `str x0,[x19,#0x198]`，而函数体内 4 处 `ldr x0,[x19,#0x1A0]` 与参考里 4 处 `ldr x0,[x19,#0x170]` 一一对应（参考里已无 `0x170` 之外的对应、目标里已无 `0x170` 访问）。`revoke`（`0x462f690`，`cbz w0,+0x208`→`b +0x208`）、`revoke-tip` 字段写入（`0x462fe30`）、内联 hook 入口（`0x462f420`）原始字节逐点核对。SLOT `0x9a53f00` 取 `__common` 结束地址 `0x9a53718` 与 `__DATA` 结束地址 `0x9a54000` 之间的零填充，`adrp/ldr/br` 入口桩经回环解码验证到同一地址。屏蔽更新 8 处经本构建 `XAppUpdateManager` 的 selector→IMP 表重新解析，8 个方法入口字节与参考 `269111` **逐字节一致**（仅地址重定位），访问器字段仍为 `0x18`/`0x19`。所有补丁点已通过真实工具 `install --dry-run`（silent / runtime-tip / block-update 三种模式）确认原始字节匹配。
- **269333**：微信 4.1.12 热修（`CFBundleShortVersionString` 仍为 4.1.12，`CFBundleVersion` 269333）。整片相对 269332 重定位，所有站点移位。与 269332 不同，本构建**无需参考二进制 diff**——`parseRevokeXML` 的几何特征在整个 arm64 切片里**唯一逐字命中**：入口前缀 `stp x24,x23 / stp x22,x21 / stp x20,x19`（`F85FBCA9F65701A9F44F02A9`）、`entry+0x270` 的 `cbz w0,+0x208`、函数体内**一处** `str x0,[x19,#0x198]` 和**恰好四处** `ldr x0,[x19,#0x1A0]`，整体重定位到 `0x463ed18`。字段偏移 `0x198`/`0x1A0` 从**本二进制**的 `str`/`ldr` 指令重新解码（未照抄）。`revoke`（`0x463ef88`，`cbz w0,+0x208`→`b +0x208`，落点同 `0x463f190`）、`revoke-tip` 字段写入（`0x463f728`，`str x0,[x19,#0x198]`→`str xzr,…`）、内联 hook 入口（`0x463ed18`）原始字节逐点核对。SLOT `0x9a6bf00` 取 `__common` 结束地址 `0x9a68a18` 与 `__DATA` 结束地址 `0x9a6c000` 之间的零填充，`adrp/ldr/br` 入口桩（`70A102B0108247F900021FD6`）经回环解码验证到同一地址。屏蔽更新 8 处经本构建 `XAppUpdateManager` 的 selector→IMP 表重新解析（`startUpdater` `0x26e4c0`、`checkForUpdates:` `0x2706ec`、`startBackgroundUpdatesCheck:` `0x2709bc`、`enableAutoUpdate:` `0x270ddc`，访问器对 `0x27b1c0`/`0x27b1c8`/`0x27b1d0`/`0x27b1d8`），8 个方法入口字节与 269332 **逐字节一致**（仅地址重定位），访问器为连续的 8 字节函数、字段仍 `0x18`/`0x19`。所有补丁点已通过真实工具 `install --dry-run`（silent / runtime-tip / block-update 三种模式）确认原始字节匹配。

- **269334**：微信 4.1.12 热修（`CFBundleVersion` 269334）。269332+ 的函数几何特征在整个 arm64 切片中仍唯一命中：入口 `0x461d624`，`entry+0x270` 的 `cbz w0,+0x208` 在 `0x461d894`，`entry+0xA10` 的 `str x0,[x19,#0x198]` 在 `0x461e034`，函数体内仍只有一处该 store 和四处 `ldr x0,[x19,#0x1A0]`。字段偏移由本构建指令重新解码为 `0x198`/`0x1A0`。SLOT `0x9a87f00` 位于 `__common` 结束地址 `0x9a86558` 与 `__DATA` 结束地址 `0x9a88000` 之间的零填充，入口桩（`50A302D0108247F900021FD6`）回环解码到同一地址。屏蔽更新 8 处从本构建 `XAppUpdateManager` 的相对方法表重新解析：`startUpdater` `0x26c4c0`、`checkForUpdates:` `0x26e6ec`、`startBackgroundUpdatesCheck:` `0x26e9bc`、`enableAutoUpdate:` `0x26eddc`，访问器对 `0x2791c8`/`0x2791d0`/`0x2791d8`/`0x2791e0`；各入口原始字节与既有补丁语义一致，访问器字段仍为 `0x18`/`0x19`。

- **269338**：微信 4.1.12 热修（`CFBundleVersion` 269338）。269332+ 的函数几何特征在整个 arm64 切片中仍**唯一逐字命中**（7504 处入口前缀里只有一处同时满足 `entry+0x270` 的 `cbz w0,+0x208`、恰好一处 `str x0,[x19,#0x198]`、恰好四处 `ldr x0,[x19,#0x1A0]`）：入口 `0x462da00`，`revoke` 的 `cbz w0,+0x208` 在 `entry+0x270`=`0x462dc70`（`40100034`→`82000014`，落点同 `0x462de78`），`revoke-tip` 的 `str x0,[x19,#0x198]` 在 `entry+0xA10`=`0x462e410`（`60CE00F9`→`7FCE00F9`）。字段偏移 `0x198`/`0x1A0` 从本构建指令重新解码。SLOT `0x9a9ff00` 取 `__DATA` 结束地址 `0x9aa0000` 减 `0x100`，位于 `__common` 结束地址 `0x9a9ea68` 与 `__DATA` 结束之间的零填充，入口桩（`90A302D0108247F900021FD6`）经 `decodeEntryStubSlot` 回环解码到同一地址。屏蔽更新 8 处从本构建 `XAppUpdateManager` 的相对 selector→IMP 表按方法名重新解析：`startUpdater` `0x26d4c0`、`checkForUpdates:` `0x26f6ec`、`startBackgroundUpdatesCheck:` `0x26f9bc`、`enableAutoUpdate:` `0x26fddc`，访问器对 `0x27a1c8`/`0x27a1d0`/`0x27a1d8`/`0x27a1e0`；8 个方法入口字节与 269334 **逐字节一致**（整片相对 269334 均匀重定位 `+0x1000`），`automaticallyDownloadsUpdates`/`canCheckForUpdate` 的 `ldrb`/`strb` 重新解码出访问器字段仍为 `0x18`/`0x19`。所有补丁点已通过真实工具 `install --dry-run`（silent / runtime-tip / block-update 三种模式）确认原始字节匹配。

- **269340**：微信 4.1.12 热修（`CFBundleVersion` 269340）。在 IDA Pro 9.4 中对 arm64 切片做聚焦分析：包装函数 `0x462dfec` 调用的核心函数 `0x462e200` 带有 `TryParseMessageXML` 日志字符串，调用点明确只传 `x0` 输出对象、`x1` 原始内容 `std::string *`、`x2` 标志指针三个参数；同时 vtable `0x9479db0` 的类型列表方法 `0x462df44` 返回 `71/72`，证明它是撤回相关类型扩展而非通用接收路径。269332+ 的补丁几何仍唯一命中：入口 `0x462e200`，`revoke` 守卫 `entry+0x270`=`0x462e470`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x462ec10`（`60CE00F9`→`7FCE00F9`），输出字段仍为 `0x198`/`0x1A0`。通用 Message 终结器 `sub_45CE1A4` 的入口为 `0x45ce1a4`；网络构造函数 `sub_45CCE50` 先填入 server ID `+0xF8`、msgType `+0x0C`、content `+0x130`，再调用终结器，而终结器从 `+0x218` 取扩展对象并通过 vtable `+0x18` 分发，故在此处增加第二个 receive-cache hook。`__DATA` 结束仍为 `0x9aa0000`、`__common` 结束为 `0x9a9ea68`；撤回槽 `0x9a9ff00` 的入口桩为 `90A302B0108247F900021FD6`，相邻接收槽 `0x9a9ff08` 的入口桩为 `90A602B0108647F900021FD6`。屏蔽更新 8 处为 `0x26e4c0`、`0x2706ec`、`0x2709bc`、`0x270ddc`、`0x27b1d0`、`0x27b1d8`、`0x27b1e0`、`0x27b1e8`，原始字节与既有方法语义一致。真实 `/Applications/WeChat.app` 已通过 `install --dry-run` 的 silent / runtime-tip / block-update 三种模式逐点确认。
- **269341**：微信 4.1.12 热修（`CFBundleVersion` 269341，arm64 切片 SHA-256 `76ff311df01419109d3a57f3fe356ed3dc18a8e6599b85c90e91072375cda625`）。IDA Pro 9.4 批处理扫描与全片字节几何交叉核对后，269332+ 撤回解析器特征仍唯一命中：入口 `0x462e60c`，守卫 `entry+0x270`=`0x462e87c`，`newmsgid` 写入 `entry+0xA10`=`0x462f01c`；函数内 `str x0,[x19,#0x198]` 仍唯一，四处 `ldr x0,[x19,#0x1A0]` 继续确认字段布局。通用 Message 路径移动到构造函数 `sub_45CD25C` 与终结器 `sub_45CE5B0`：构造函数把来源 `+0x50` 写到 Message `+0xF8`，通过 `sub_45CDF24` 把类型写到 `+0x0C`，把内容复制到 `+0x130`，随后无条件 `bl 0x45ce5b0`；终结器的 `ldrb/cmp/ccmp` 前缀逐字节不变，并继续从 `+0x218` 经 vtable `+0x18` 分发。`__DATA`/`__common` 边界仍为 `0x9aa0000`/`0x9a9ea68`，所以两个 SLOT 与入口桩字节保持不变。8 个更新补丁点及其原始字节也与 269340 相同。真实二进制已通过 silent、runtime-tip、runtime-tip + block-update、update-only 四种 dry-run；临时 APFS 副本完成实际安装后，LLDB 确认两个入口桩分别写入 `90A302B0108247F900021FD6`/`90A602B0108647F900021FD6`，两个 SLOT 分别解析到 `hookedParseRevokeXML`/`hookedFinalizeMessage`。
- **269574**：微信 4.1.13（`CFBundleVersion` 269574；arm64 切片 SHA-256 `ccc2b08b5d4ae47ad23fc349b98697484d7c7c1c5ba46add4e709f7bad20f53c`）。以官方 269341 arm64 切片为参考，把地址相关立即数归一化后做全函数匹配，7732 个候选入口中只有 `0x4905488` 呈现强匹配（重叠率 `0.7888`，次优约 `0.4322`）；radare2 恢复出的函数大小、指令数、基本块数、圈复杂度与 269341 完全一致（4072/1018/140/77）。唯一调用方仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。守卫保持在 `entry+0x270`=`0x49056f8`（`40100034`→`82000014`），`newmsgid` 写入保持在 `entry+0xA10`=`0x4905e98`，但指令重新解码为 `str x0,[x19,#0x1C8]`（`60E600F9`→`7FE600F9`），函数内恰好四处对应 load 确认 `replaceMsg=+0x1D0`。通用 Message 终结器入口为 `0x48a3b20`，`ldrb/cmp/ccmp` 形状在新切片中唯一命中；网络构造函数 `0x48a27b8` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件调用终结器。`__common` 结束地址 `0x9ecb018` 到 `__DATA` 虚拟结束地址 `0x9ecc000` 是零填充，两个 SLOT 取 `0x9ecbf00`/`0x9ecbf08`；入口桩 `30AE02D0108247F900021FD6` 与 `50B10290108647F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 的 selector→IMP 表按方法名重新解析，访问器字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `53/53` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、119 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269575**：微信 4.1.13 热修（`CFBundleVersion` 269575；arm64 切片 SHA-256 `135d3ff749583a6d31893f143613fb3dfa8fe7e1945f7219b03e6c81d975b938`）。269574 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中，并均匀重定位 `-0x5B8`：入口 `0x4904ed0`，守卫 `entry+0x270`=`0x4905140`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x49058e0`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x4904e4c` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器同样 `-0x5B8` 到 `0x48a3568`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x48a2200` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件 `bl 0x48a3568`。`__common` 结束地址 `0x9ecadd8` 到 `__DATA` 虚拟结束地址 `0x9ecc000` 仍是零填充，两个 SLOT 保持 `0x9ecbf00`/`0x9ecbf08`；入口桩 `30AE02F0108247F900021FD6` 与 `50B10290108647F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析，访问器字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `69/69` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、121 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269576**：微信 4.1.13 热修（`CFBundleVersion` 269576；`WeChatBundleVersion` `4.1.13.8`；arm64 切片 SHA-256 `ce63ff3e7ad4e20dbce1842dd67764ab097f42ae4134d6746e94ee7d25dfe891`）。269574/269575 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中，并均匀重定位 `+0x34C`（相对 269575）：入口 `0x490521c`，守卫 `entry+0x270`=`0x490548c`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x4905c2c`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x4905198` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器同样 `+0x34C` 到 `0x48a38b4`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x48a254c` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件 `bl 0x48a38b4`。`__common` 结束地址 `0x9ecae18` 到 `__DATA` 虚拟结束地址 `0x9ecc000` 仍是零填充，两个 SLOT 保持 `0x9ecbf00`/`0x9ecbf08`；入口桩 `30AE02D0108247F900021FD6` 与 `50B10290108647F900021FD6` 均经编码/解码回环验证（撤回入口跨过 4K 页边界，因此 ADRP 相对 269575 变化）。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27c814`、`checkForUpdates:` `0x27e94c`、`startBackgroundUpdatesCheck:` `0x27ec10`、`enableAutoUpdate:` `0x27eff0`，访问器对 `0x28935c`/`0x289364`/`0x28936c`/`0x289374`，字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `69/69` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、123 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269577**：微信 4.1.13.9（`CFBundleVersion` 269577；arm64 切片 SHA-256 `8d5d5c37efc88d4d9ff5d6f9204a58d2375fecc381c09e38d153e49c80ba85bc`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中；相对 269576，解析器重定位 `+0x53608`，终结器 `+0x52C28`，更新方法 `+0x854`。入口 `0x4958824`，守卫 `entry+0x270`=`0x4958a94`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x4959234`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x49587a0` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器到 `0x48f64dc`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x48f5174` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件 `bl 0x48f64dc`。`__common` 结束地址 `0x9f54a48` 到 `__DATA` 虚拟结束地址 `0x9f58000` 是零填充，两个 SLOT 取 `0x9f57f00`/`0x9f57f08`；入口桩 `F0AF02F0108247F900021FD6` 与 `10B302B0108647F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27d068`、`checkForUpdates:` `0x27f1a0`、`startBackgroundUpdatesCheck:` `0x27f464`、`enableAutoUpdate:` `0x27f844`，访问器对 `0x289bb0`/`0x289bb8`/`0x289bc0`/`0x289bc8`，字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `69/69` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、125 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269578**：微信 4.1.13.10（`CFBundleVersion` 269578；`WeChatBundleVersion` `4.1.13.10`；arm64 切片 SHA-256 `eaa877e144bd45e78098f88d8981f203ec52fba830c3bd79532e176dcafeb82c`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中，并均匀重定位 `+0x28`（相对 269577）：入口 `0x495884c`，守卫 `entry+0x270`=`0x4958abc`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x495925c`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x49587c8` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器同样 `+0x28` 到 `0x48f6504`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x48f519c` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件 `bl 0x48f6504`。`__common` 结束地址 `0x9f54a48` 到 `__DATA` 虚拟结束地址 `0x9f58000` 仍是零填充，两个 SLOT 保持 `0x9f57f00`/`0x9f57f08`；入口桩 `F0AF02F0108247F900021FD6` 与 `10B302B0108647F900021FD6` 均经编码/解码回环验证（解析器与终结器都仍在同一 4K 页内，因此 ADRP 与 269577 相同）。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27d068`、`checkForUpdates:` `0x27f1a0`、`startBackgroundUpdatesCheck:` `0x27f464`、`enableAutoUpdate:` `0x27f844` 保持不变，访问器对平移到 `0x289bb8`/`0x289bc0`/`0x289bc8`/`0x289bd0`，字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `69/69` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、127 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269579**：微信 4.1.13.11（`CFBundleVersion` 269579；`WeChatBundleVersion` `4.1.13.11`；arm64 切片 SHA-256 `3b19426183206408af0297489464078df1a709b23dae92fdbf5a7c6d305cfe83`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中，并均匀重定位 `-0x1C`（相对 269578）：入口 `0x4958830`，守卫 `entry+0x270`=`0x4958aa0`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x4959240`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x49587ac` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器同样 `-0x1C` 到 `0x48f64e8`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x48f5180` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件 `bl 0x48f64e8`。`__common` 结束地址 `0x9f54b48` 到 `__DATA` 虚拟结束地址 `0x9f58000` 仍是零填充，两个 SLOT 保持 `0x9f57f00`/`0x9f57f08`；入口桩 `F0AF02F0108247F900021FD6` 与 `10B302B0108647F900021FD6` 均经编码/解码回环验证（解析器与终结器都仍在同一 4K 页内，因此 ADRP 与 269578 相同）。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27d068`、`checkForUpdates:` `0x27f1a0`、`startBackgroundUpdatesCheck:` `0x27f464`、`enableAutoUpdate:` `0x27f844` 保持不变，访问器对平移回 `0x289bb0`/`0x289bb8`/`0x289bc0`/`0x289bc8`（相对 269578 `-8`，与 269577 相同），字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `69/69` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、129 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269619**：微信 4.1.13.51（`CFBundleVersion` 269619；`WeChatBundleVersion` `4.1.13.51`；arm64 切片 SHA-256 `f167b56722d61412df3a7765e2481a050aa9e635a0dcb5a24b1e974d56039e68`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中；相对 269579，解析器重定位 `+0x270D8`，终结器 `+0x26634`。入口 `0x497f908`，守卫 `entry+0x270`=`0x497fb78`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x4980318`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x497f884` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器到 `0x491cb1c`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x491b7c4` 仍把 `serverId` 从来源 `+0x50` 写到 `+0xF8`（`ldr x8,[x23,#0x50]` / `str x8,[x19,#0xF8]`）、内容 `add x0,x19,#0x130`、经 `0x491c490` 把 `msgType` 写到 `+0x0C` 后无条件 `bl 0x491cb1c`。`__common` 结束地址 `0x9f9f3e8` 到 `__DATA` 虚拟结束地址 `0x9fa0000` 是零填充，两个 SLOT 取 `0x9f9ff00`/`0x9f9ff08`；入口桩 `10B10290108247F900021FD6` 与 `10B402F0108647F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27cd98`、`checkForUpdates:` `0x27efc4`、`startBackgroundUpdatesCheck:` `0x27f294`、`enableAutoUpdate:` `0x27f6b4`，访问器对 `0x289f34`/`0x289f3c`/`0x289f44`/`0x289f4c`，字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对补丁点函数做定向分析（167MB 切片的全库自动分析在一小时内未完成）：解析器边界 4072 字节 / 966 条指令 / 140 个基本块，Hex-Rays 原型为三参数 `__int64 (x0, x1, _BYTE *x2)`，唯一代码 xref 来自 `0x497f884`；守卫为 `CBZ W0`，`newmsgid` 写入为 `STR X0, [X19,#0x1C8]`；终结器 28 个代码 xref（27 个直接 `BL` 加 1 个尾调用）；网络构造函数无条件 `sub_491CB1C(a1, 1)`，并保留 `+0xF8` / `+0x130` 访问。12 处原始字节均一致。自动比较 `69/69` 通过。debug 构建、131 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。
- **269624**：微信 4.1.13.56（`CFBundleVersion` 269624；`WeChatBundleVersion` `4.1.13.56`；arm64 切片 SHA-256 `7cf3d4effabc96bdb23fd2da21486388cbcea5fa1f6dfd72a872e0deba60d601`；完整 fat SHA-256 `fe0ce66a8972a5eec9df2238ea93ae07f41f288c6367cd635f6efe7d5d4e1c00`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中；相对 269619，解析器与终结器均均匀重定位 `+0x2E3C0`。入口 `0x49adcc8`，守卫 `entry+0x270`=`0x49adf38`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x49ae6d8`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x49adc44` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器到 `0x494aedc`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x4949b84` 仍把 `serverId` 从来源 `+0x50` 写到 `+0xF8`（`ldr x8,[x23,#0x50]` / `str x8,[x19,#0xF8]`）、内容 `add x0,x19,#0x130`、经 `0x494a850` 把 `msgType` 写到 `+0x0C` 后无条件 `bl 0x494aedc`。`__common` 结束地址 `0xa03d428` 到 `__DATA` 虚拟结束地址 `0xa040000` 是零填充，两个 SLOT 取 `0xa03ff00`/`0xa03ff08`；入口桩 `90B402D0108247F900021FD6` 与 `B0B702B0108647F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27ceac`、`checkForUpdates:` `0x27f0d8`、`startBackgroundUpdatesCheck:` `0x27f3a8`、`enableAutoUpdate:` `0x27f7c8`，访问器对 `0x28a048`/`0x28a050`/`0x28a058`/`0x28a060`（相对 269619 均匀 `+0x114`），字段仍为 `0x18`/`0x19`。终结器有 28 个直接 `BL` 加 1 个尾调用 `B`。12 处原始字节均与真实 `/Applications/WeChat.app` 逐点核对。debug 构建、133 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。IDA Professional 9.4 对 168MB 切片的定向 Hex-Rays 反编译在约 18 分钟内未完成（与 269619 全库自动分析超时同类），因此本构建以几何特征唯一命中、字段指令重解码、入口桩回环和 dry-run 字节匹配为准。
- **269628**：当前安装的微信 4.1.13.60（`CFBundleVersion` 269628；`WeChatBundleVersion` `4.1.13.60`；arm64 切片 SHA-256 `c4cc52d856929ce294dfcf63461f81ac646353ff0987a43ad5f4ebbfe9262e42`；完整 fat SHA-256 `deba415351c832722b97fa64649990ebb693a5851080c08d2aed068c3f29ee7e`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中；相对 269624，解析器与终结器均均匀重定位 `+0x12C8`。入口 `0x49aef90`，守卫 `entry+0x270`=`0x49af200`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x49af9a0`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x49aef0c` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器到 `0x494c1a4`，`ldrb/cmp/ccmp` 形状唯一命中（相对 269624 归一化重叠率 `1.0`）；网络构造函数 `0x494ae4c` 仍把 `serverId` 从来源 `+0x50` 写到 `+0xF8`（`ldr x8,[x23,#0x50]` / `str x8,[x19,#0xF8]`）、内容 `add x0,x19,#0x130`、经 `0x494bb18` 把 `msgType` 写到 `+0x0C` 后无条件 `bl 0x494c1a4`。`__common` 结束地址 `0xa041678` 到 `__DATA` 虚拟结束地址 `0xa044000` 是零填充，两个 SLOT 取 `0xa043f00`/`0xa043f08`；入口桩 `B0B402B0108247F900021FD6` 与 `B0B702F0108647F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27becc`、`checkForUpdates:` `0x27e0f8`、`startBackgroundUpdatesCheck:` `0x27e3c8`、`enableAutoUpdate:` `0x27e7e8`，访问器对 `0x289068`/`0x289070`/`0x289078`/`0x289080`（相对 269624 均匀 `-0xFE0`），字段仍为 `0x18`/`0x19`。终结器有 28 个直接 `BL` 加 1 个尾调用 `B`。12 处原始字节均与真实 `/Applications/WeChat.app` 逐点核对。随后使用 IDA Professional 9.4 对补丁点函数做定向分析（与 269619/269624 相同，168MB 切片跳过全库自动分析和 Hex-Rays）：解析器边界 4072 字节 / 966 条指令 / 140 个基本块，唯一代码 xref 来自 `0x49aef0c`；守卫为 `CBZ W0`，`newmsgid` 写入为 `STR X0, [X19,#0x1C8]`；终结器 29 个代码 xref；网络构造函数保留 `+0xF8` / `+0x130` 访问。12 处原始字节均一致。自动比较 `55/55` 通过。debug 构建、173 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。

- **270090**：微信 4.1.15.10，完整 fat SHA-256 `b5060c38b6e45df22bf867ed33533d51c00e49d4c28c16c04290ec0b5769323c`，arm64 切片 SHA-256 `c1fe19a25b58cd34a19771748a8c8da6ac3b7b7e8695f6e3c49702c9b68fcca9`。解析器 `0x4BBE5CC..0x4BBF6E8`；撤回守卫 `0x4BBE83C` 的 `CBZ W0,0x4BBEA44` 改为同目标无条件跳转（`40100034` → `82000014`）；`0x4BBEFDC` 的 `STR X0,[X19,#0x1C8]` 改为 `STR XZR`（`60E600F9` → `7FE600F9`）。唯一直接调用点 `0x4BBE548` 明确传 x0 输出对象、x1 XML 字符串、x2 标志指针；包装器先复制到输出 `+0x1D0`。类型列表方法写入 71/72。终结器 `0x4B5B0A0..0x4B5B1B4` 有 28 个直接 BL，前缀仍为 `086049391F0500712008407A`；网络构造函数 `0x4B59D48..0x4B5A41C` 在 `0x4B59E5C` 写 ID `+0xF8`，`0x4B59E80` 通过 string 赋值写内容 `+0x130`，经 `0x4B5AA14` 在 `0x4B5AA4C` 写类型 `+0x0C`。`__common` 结束 `0xA35F3E8`，`__DATA` 结束 `0xA360000`，两个 SLOT 位于二者之间。8 个更新入口从 `XAppUpdateManager` 方法表独立恢复为 `0x2768AC`、`0x278AD8`、`0x278DA8`、`0x2791C8`、`0x283A48`、`0x283A50`、`0x283A58`、`0x283A60`，访问器字段仍为 `0x18`/`0x19`。

  本地证据在 `work/20260913-wechat-270090-support/evidence/`：`E-002` 记录结构定位，`E-003` 记录接收链，`E-004` 为 IDA 9.4 导出，`E-005` 记录原始指令与真实函数边界。大二进制关闭全库自动分析，部分 Hex-Rays 输出存在 SP 警告；调用约定以调用点反汇编为准。release 构建及签名、173 项测试、5 种真实二进制 dry-run、隔离副本 3 种安装/幂等/还原、字节不匹配拒绝、运行组件 trampoline 与红包 ABI 离线检查均通过。初始适配阶段的验证限于上述离线检查；随后完成加载时序修复和隔离副本启动取证，用户已在真实微信中确认防撤回与自动红包可用。红包地址和组件标记 `:3` 见专门文档。

- **270100**：2026-09-19 安装的微信 4.1.15.20（`CFBundleVersion` 270100；`WeChatBundleVersion` `4.1.15.20`；完整 fat SHA-256 `b69ce670e1d898cef70f18cb487945e728540c2ed888ebede3923b9973db727d`；arm64 切片 SHA-256 `1ad2f70c7c747f00d1ded5ae84eba94efae03b2a2d002c763cbb6a7c03a03123`）。269574+ 撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中。入口 `0x4BC4D34`，守卫 `entry+0x270`=`0x4BC4FA4`（`40100034`→`82000014`，落点 `0x4BC51AC`），`newmsgid` 写入 `entry+0xA10`=`0x4BC5744`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。`LC_FUNCTION_STARTS` 边界为 `0x4BC4D34..0x4BC5E50`（4380=`0x111C` 字节）。唯一直接调用点 `0x4BC4CB0` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器 `0x4B61808..0x4B6191C`（276 字节），`ldrb/cmp/ccmp` 前缀 `086049391F0500712008407A` 唯一命中，28 个直接 `BL`；网络构造函数 `0x4B604B0..0x4B60B84` 在 `0x4B605C4` 写 ID `+0xF8`，`0x4B605E8` 通过 `add x0,x19,#0x130` 写内容，经 `0x4B6117C` 在 `0x4B611B4` 写类型 `+0x0C`，随后无条件 `bl 0x4B61808`（`mov w1,#1`）。`__common` 结束 `0xA367FA8`，`__DATA` 结束 `0xA368000`，空隙仅 `0x58` 字节，两个 SLOT 取 `0xA367FF0`/`0xA367FF8`；入口桩 `10BD02F010FA47F900021FD6` 与 `30C002D010FE47F900021FD6` 均经编码/解码回环验证。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表按方法名重新解析：`startUpdater` `0x274F04`、`checkForUpdates:` `0x277130`、`startBackgroundUpdatesCheck:` `0x277400`、`enableAutoUpdate:` `0x277820`，访问器对 `0x2820A0`/`0x2820A8`/`0x2820B0`/`0x2820B8`，字段仍为 `0x18`/`0x19`。IDA Professional 9.4 对补丁点函数做定向分析（关闭全库自动分析）：解析器唯一代码 xref 来自 `0x4BC4CB0`；Hex-Rays 仍有 SP 警告，调用约定以调用点反汇编为准。红包九处运行时指纹与数据槽按同尺寸函数匹配及调用点 ADRP 独立恢复，组件标记更新为 `:4`。

- **270102**：2026-09-30 安装的微信 4.1.15.22（`CFBundleVersion` 270102；完整 fat SHA-256 `d89434bb90b65991aa35a32e6b48a5825b0b1906e7142b12387c32fd76996b94`；arm64 切片 SHA-256 `07e35c5d8ea0d97f1f16d79a5efec42fa1ca97213f634d473631beeaae8f0841`）。按本构建几何特征、`LC_FUNCTION_STARTS`、调用点及 `XAppUpdateManager` 相对方法表独立定位，IDA Professional 9.4 / Hex-Rays 交叉核对。撤回解析器 `0x4BC5168..0x4BC6284`（4380 字节），守卫 `0x4BC53D8` 的 `40100034` 改为 `82000014`，目标均为 `0x4BC55E0`；字段写入 `0x4BC5B78` 的 `60E600F9` 改为 `7FE600F9`。字段仍为 `newMsgId=+0x1C8` / `replaceMsg=+0x1D0`，唯一直接调用点 `0x4BC50E4` 明确按 x0/x1/x2 传参。Message 终结器 `0x4B61C3C..0x4B61D50`（276 字节）有 28 个直接调用点；网络构造函数 `0x4B608E4..0x4B60FB8` 在 `0x4B609F8` 写 ID `+0xF8`，在 `0x4B60A1C` 取 content `+0x130` 调用 string 赋值，类型辅助函数 `0x4B615B0` 在 `0x4B615E8` 写 `+0x0C`，随后在 `0x4B60D88` 调用终结器。更新的 8 个 IMP 及原始字节与 270100 相同。`__DATA` 仍为读写，`__common` 结束 `0xA367FA8`，段结束 `0xA368000`；两个 SLOT `0xA367FF0` / `0xA367FF8` 在所有 section 外的零填充区。解析器入口跨页，入口桩必须更新为 `10BD02D010FA47F900021FD6`；终结器入口桩仍为 `30C002D010FE47F900021FD6`，两者都已回环解码到目标槽。红包九处指纹、数据地址、请求号与 ABI 独立核对，组件标记升为 `:6`，避免旧组件在新构建上误报可用。多开继续通过独立 bundle ID 的 `clone`，没有为当前构建新增历史 `multiInstance` 字节补丁。

  本地证据位于 `work/20260930-wechat-270102-support/evidence/`：`E-002` / `E-003` 为定位与接收链，`E-004` 为 IDA 撤回/更新核对，`E-010` / `E-011` 为槽位与全部补丁字节验证，`ida-red-packet/` 与 `ida-red-packet-auxiliary/` 合计导出 28 个红包相关函数。完整 Xcode 构建、188 项测试、6 种真实二进制 dry-run、独立副本的静默/提示/仅更新/runtime 安装与幂等、逐字节备份还原、字节不匹配拒绝均通过。副本安装验证发现并修复了清理扩展属性破坏 JSON 资源签名的问题（详见“GUI 与发布”），最终递归严格签名验证通过。LLDB 在 `WeChatMain` 前确认两个 SLOT 分别指向 `hookedParseRevokeXML` / `hookedFinalizeMessage`（`startup-270102.json`）；打包工具的签名、当前构建检测及四项运行组件自检通过（`packaged-validation.json`）。原 `/Applications/WeChat.app` 的核心二进制 SHA-256 未变。上述验证不代表真实撤回、自动领取或屏蔽更新已完成业务实测。


- **270132**：2026-09-30 微信自动更新后的 4.1.15.52（`CFBundleVersion` 270132；完整 fat SHA-256 `b60951ebea5c00e458c87657b4cc5ee21ea6a216cea30feb1c235cbb5beb3841`；arm64 SHA-256 `784f43567e0945bb587baf58784382c03e60839248c78baebc9fe28e0a2b0326`）。按新二进制几何特征、`LC_FUNCTION_STARTS`、真实调用点及更新方法表重新定位，IDA Professional 9.4 / Hex-Rays 复核。解析器 `0x4D16CE8..0x4D17E04`（4380 字节）；守卫 `0x4D16F58` 的 `40100034` 改为 `82000014`，仍跳到 `0x4D17160`；字段写入 `0x4D176F8` 的 `60E600F9` 改为 `7FE600F9`。`newMsgId` / `replaceMsg` 仍为 `+0x1C8` / `+0x1D0`，调用点 `0x4D16C64` 仍使用 x0/x1/x2。Message 终结器 `0x4CB37BC..0x4CB38D0`（276 字节）有 28 个直接调用点；网络构造函数 `0x4CB2464..0x4CB2B38` 在 `0x4CB2578` 写 ID `+0xF8`，`0x4CB259C` 复制内容 `+0x130`，类型辅助函数 `0x4CB3130` 在 `0x4CB3168` 写 `+0x0C`，随后 `0x4CB2908` 调用终结器。8 个更新 IMP 为 `0x28D9A4` / `0x28FBD0` / `0x28FEA0` / `0x2902C0` / `0x29AB38` / `0x29AB40` / `0x29AB48` / `0x29AB50`，访问器字段仍为 `+0x18` / `+0x19`。`__common` 结束 `0xA5339A8`，`__DATA` 结束 `0xA534000`，剩余 `0x658` 字节零填充；两个读写 SLOT 取 `0xA533FF0` / `0xA533FF8`，在所有 section 之外。双入口桩为 `F0C002B010FA47F900021FD6` / `10C4029010FE47F900021FD6`，已回环解码。红包地址与 ABI 另行核对，组件标记升级为 `:7`，详见红包文档。

  本地证据位于 `work/20260930-wechat-270132-support/evidence/`；`E-002` / `E-003` / `E-004` 为定位、接收链和 IDA 复核，红包函数导出在 `ida-red-packet/` 与 `ida-red-packet-auxiliary/`。完整 Xcode 构建、192 项测试、三种真实二进制 dry-run、独立副本的 runtime 安装/幂等/逐字节还原及最终递归严格签名验证全部通过。LLDB 在 `WeChatMain` 前确认两个 hook 已初始化（`startup-270132.json`）；打包工具的签名和四项组件自检通过。仅用 `--runtime-tip` 安装后逐字节核对更新的 8 个 IMP 仍为原始指令（`installer/summary.json`）。支持表包含更新目标，但安装命令只选 `--runtime-tip` 时不会启用屏蔽更新，也不会创建多开副本。真实撤回、红包领取与更新行为仍需业务实测。

- **270135**：2026-10-14 微信自动更新后的 4.1.15.55（`CFBundleVersion` 270135；`WeChatBundleVersion` 4.1.15.55；完整 fat SHA-256 `5f5a81c4d8b000dec1c7203738fc4dba75ce752b55874fc1b6b5869f9dfb1027`；arm64 SHA-256 `6a5bd0cbb39ad3092c15e9debda2db4969eedf1b58caad244d88033a996833a7`）。以 270133 切片为参照独立重新定位（非整体平移），IDA Professional 9.4 / Hex-Rays 复核。解析器 `0x4D1F8D8..0x4D209F4`（4380 字节）；守卫 `0x4D1FB48` 的 `40100034` 改为 `82000014`；字段写入 `0x4D202E8` 的 `60E600F9` 改为 `7FE600F9`；`newMsgId` / `replaceMsg` 仍为 `+0x1C8` / `+0x1D0`，调用点 `0x4D1F854`。Message 终结器 `0x4CBC3AC..0x4CBC4C0`（276 字节）有 28 个调用点；网络构造函数 `0x4CBB054` 在 `0x4CBB168` 写 ID `+0xF8`，`0x4CBB18C` 复制内容 `+0x130`，类型辅助函数 `0x4CBBD20` 在 `0x4CBBD58` 写 `+0x0C`，随后 `0x4CBB4F8` 调用终结器。8 个更新 IMP 为 `0x28D9F0` / `0x28FC1C` / `0x28FEEC` / `0x29030C` / `0x29AB8C` / `0x29AB94` / `0x29AB9C` / `0x29ABA4`。`__common` 结束 `0xA52BEB8`，`__DATA` 结束 `0xA52C000`，剩余 `0x148` 字节；SLOT 取 `0xA52BFF0` / `0xA52BFF8`。双入口桩 `70C0029010FA47F900021FD6` / `70C302F010FE47F900021FD6`。红包地址表独立重定位，组件标记升级为 `:9`。

  本地证据位于 `work/20261014-wechat-270135-support/evidence/`：`E-020` 为 28 个红包函数相对 270133 的逐指令比对（差异 2 处，均为 `receive_result_fields` 中一个静态初始化守卫字节 `LDRB/STRB [X8,#3]`——数据页内偏移恰为 3，不是结构体字段，已人工核对），`E-021` 为解析器 1095 条 / 终结器 69 条指令比对（差异 0）。完整构建、200 项测试、4 种真实二进制 dry-run、独立副本 runtime 安装/幂等/还原/签名验证均通过；LLDB 在 `WeChatMain` 前确认两个 SLOT 指向 `hookedParseRevokeXML` / `hookedFinalizeMessage`。真实撤回、红包领取与更新行为仍需业务实测。

- **270133**：2026-10-14 本机微信 4.1.15.53（`CFBundleVersion` 270133；`WeChatBundleVersion` 4.1.15.53；完整 fat SHA-256 `20dd901b4678d7b163806deadb35b4542c58651ad546efed5bc8703f6bbdcde4`；arm64 SHA-256 `c54dc4f6a945032225c0773bc62ed54de5a1f34f07513246c35f391cb6b30bbb`）。以 270132 切片为参照，按几何特征、`LC_FUNCTION_STARTS`、真实调用点及更新方法表独立重新定位（不是整体平移），并经 IDA Professional 9.4 / Hex-Rays 复核。解析器 `0x4D15438..0x4D16554`（4380 字节，与 270132 同尺寸）；守卫 `0x4D156A8` 的 `40100034` 改为 `82000014`，仍跳到 `0x4D158B0`；字段写入 `0x4D15E48` 的 `60E600F9` 改为 `7FE600F9`。`newMsgId` / `replaceMsg` 仍为 `+0x1C8` / `+0x1D0`，调用点 `0x4D153B4`。Message 终结器 `0x4CB1F0C..0x4CB2020`（276 字节）有 28 个直接调用点；网络构造函数 `0x4CB0BB4..0x4CB1288` 在 `0x4CB0CC8` 写 ID `+0xF8`，`0x4CB0CEC` 复制内容 `+0x130`，类型辅助函数 `0x4CB1880` 在 `0x4CB18B8` 写 `+0x0C`，随后 `0x4CB1058` 调用终结器。8 个更新 IMP 为 `0x28B9A4` / `0x28DBD0` / `0x28DEA0` / `0x28E2C0` / `0x298B38` / `0x298B40` / `0x298B48` / `0x298B50`，访问器字段仍为 `+0x18` / `+0x19`。`__common` 结束 `0xA51FA68`，`__DATA` 结束 `0xA520000`，剩余 `0x598` 字节零填充；两个读写 SLOT 取 `0xA51FFF0` / `0xA51FFF8`。双入口桩为 `50C002D010FA47F900021FD6` / `70C302D010FE47F900021FD6`，已回环解码。红包地址表独立重定位，组件标记升级为 `:8`，详见红包文档。

  本地证据位于 `work/20261014-wechat-270133-support/evidence/`：`E-002` / `E-003` 为定位与接收链，`E-004` 为 IDA 撤回/更新核对（字段访问扫描比 270132 多报一条 `0x4D158D4: ldr d0,[x9,#0x1c8]`，实为 `adrp x9,#0x857a000` 之后的数据页常量加载，不是 `newMsgId` 字段访问；`E-021` 的解析器 1095 条 / 终结器 69 条指令比对在忽略分支目标及 ADRP 数据页内偏移后差异为 0，解析器原始重叠率 0.837 完全由重定位立即数造成），`E-011` 为全部补丁字节验证，`E-020` 为 28 个红包相关函数相对 270132 的逐指令等价比对（忽略分支/符号及 ADRP 数据页内偏移后差异为 0，并经反例验证该比对能发现真实偏移变化）。完整构建、196 项测试、4 种真实二进制 dry-run（静默 / runtime / runtime+屏蔽更新 / 仅更新）、独立副本的 runtime 安装/幂等/逐字节还原/最终签名验证均通过。LLDB 在 `WeChatMain` 前确认两个 SLOT 分别指向 `hookedParseRevokeXML` / `hookedFinalizeMessage`（`startup-270133.json`）。仅用 `--runtime-tip` 安装时不会改写更新 IMP。**未做**真实撤回、红包领取或屏蔽更新的业务实测。

---

## X1a0He 2.9.0 逆向对照

研究对象为 [X1a0HeWeChatPlugin 2.9.0 发布二进制](https://github.com/X1a0He/X1a0HeWeChatPlugin/releases/tag/2.9.0)，不是公开源码。arm64 dylib 为 7,377,840 字节，SHA-256 `2cc3e3b0ca8bc65a369c1074f2aa7cc7f54eb8572cb18e7f5e17fbc1687c3bb2`，UUID `A6A47027-32D9-3E47-8607-61C15D1DCDD1`；pkg 中的 dylib 与单独发布文件一致。以下地址均是**插件自身**地址，不是微信 270090 的补丁地址。仅做静态 IDA 分析及字符串解码，未执行插件或安装器。

### 已确认的实现

| 环节 | 二进制证据 | 与本项目的区别 |
| --- | --- | --- |
| 注入 | pkg 的 `postinstall` 将插件依赖注入 `Resources/wechat.dylib`，缺失时找 `Frameworks/wechat.dylib` | 同样注入核心 dylib，并非只注入主可执行文件 |
| 挂钩引擎 | `_DobbyHook` `0x4FAB48`，包装器 `0xBC834`；`0xC75C0` 获取 ObjC IMP，另有 `method_setImplementation` | 同时覆盖原生函数和 ObjC 方法，比本项目两处静态入口改写更广 |
| 定位 | `0xD4714` / `0xEAFC4` 扫描通配 arm64 指令特征，按 executable segment / slice 查找，并缓存到 `search_pattern_v2` | 本项目安装时仍使用独立确认的精确构建表和 expected 字节；不把动态扫描直接放进安装路径 |
| 防撤回 | `0x2000EC` 安装全类型 `CoReplace` 替换路径 hook；替代函数 `0x2D5390` 使用 `0x6EF950`–`0x6EF980` 等原生辅助入口 | 不是只改 XML 解析器，也不是简单把撤回函数改成 return |
| 消息保留 | `0x2D5390` 查询原生消息、保留 shared ownership、重建 `0x280` 字节结果，原消息与提示分开处理 | 该结果对象不能当作本项目 632 字节 Message 或 848 字节 display 直接复制 |
| 策略 | `0x2D5390` 有自己/他人及消息类型分支；`0x2E0D74` 有联系人黑名单/白名单/off | 本次不引入新的过滤、自动转发或下载功能 |
| 去重 | `0x20D854` 处理 svrId / running，事件上下文 `+193` 有原子 processed 标志 | 证明有一次性处理控制，不足以证明完整 TTL、淘汰或账号切换语义 |
| 更新 | `0x1452B8` 安装 `XAppUpdateManager` 启动、手动/后台检查、安装就绪及下载开关 hook | 本项目保留既有 8 处更新控制点，不附带禁日志上报、安全模式等行为 |

`CoReplace` 依赖目标或辅助入口缺失时，上游安装分支保留微信原生行为；已经进入替代函数后，还存在调用原函数和返回空结果等不同失败路径，不能概括成“任何错误都阻止撤回”。自己身份的完整推导、完整逐版本地址表及所有消息类型边界尚未恢复。

上游 `0x14EC24` 打开 `recalled_message_records.sqlite`，`0x159A58` 从 SQLite 恢复历史背景/撤回元数据。这**不能证明**该库保存完整原消息或媒体；已观察到的撤回原消息查询走原生辅助函数，不能仅凭二进制里有 SELECT 字符串就认定为直接读取聊天数据库。

### 延迟加载与采用范围

`0x22928C` 调用 readiness 检查 `0x22A0B0`，未就绪时通过 `dispatch_once` 安装后备路径；`0x30E104` 使用 `dlsym(RTLD_DEFAULT, 动态名称)` 定位目标，挂接 `0x30F9E0`，后者比较符号名并重试就绪检查，诊断明确提到 `WeChatMain`。动态重建的 hook 目标名称尚未恢复，因此不能断言它全局替换了 `dlsym`。

最初的普通 `dlopen(wechat.dylib)` 隔离实验在依赖库 constructor 中能看到核心映像，输出 `PASS_DELAYED_LOAD_DEPENDENCY_VISIBLE`，但它**没有覆盖微信加载器预先加载依赖的实际路径**。随后 270090 闪退的真实副本调试证明：runtime constructor 中核心不可见，之后 WCDYWrapper 的 `0x67ED8 → 0x1ABF0 → 0x9430C → 0x95E04` 路径通过系统 `dlopen` 注册核心。当前已改为系统 dyld 同步 add-image 通知，不需要挂接上游私有 loader 函数、引入 wrapper ABI 或定时重试；详见前面的启动闪退修复记录。

本次借鉴的是：把特征扫描作为离线研究工具、用真实函数边界与调用链批准版本配置、区分原消息与合成提示、明确原生对象所有权，以及可选前提失败时不冒险调用未知地址。前两点用于本次 270090 独立适配，并修正了旧分析窗口与函数边界混淆的问题。若将来增加冷缓存查询或去重，应先独立证明账号/会话/server ID 的键范围与生命周期；上游闭源实现不能替代这些证据。

未发现仓库实现源码或许可证，不复制其 dylib 或反编译代码。本次也不继承安装器删除插件配置、重置 ScreenCapture 授权等副作用。完整证据与反编译片段保留在本地忽略目录 `work/20260913-wechat-270090-support/upstream/evidence.json` 及同目录 IDA 数据库；公开说明依据 [仓库 README](https://github.com/X1a0He/X1a0HeWeChatPlugin) 与 [2.9.0 发布页](https://github.com/X1a0He/X1a0HeWeChatPlugin/releases/tag/2.9.0) 对照，不把 README 的实测声明作为本项目实测结果。

---

## 新增一个构建号

大致流程：

1. **拿到目标 `wechat.dylib`**：从对应版本的微信 App 里取 `Contents/Resources/wechat.dylib`。
2. **定位 `parseRevokeXML`**：按已知函数体几何特征（入口 `stp` 序列、`cbz w0`、`str x0,[x19,#0x168]`）在 arm64 切片里搜，确认唯一命中。
   - **几何特征失配时**（函数被重编译，命中数为 0 或 >1，如 `269332`）：改用**参考二进制 diff**。取一个已支持的邻近构建（如从腾讯 CDN `WeChatMac_4.1.x.dmg` 下载 4.1.11），在参考里用几何特征定位 `parseRevokeXML`，把函数体"屏蔽掉地址相关立即数（`adrp`/`bl`/`b`/`b.cond`/`cbz`/`ldr literal` 的偏移）后的指令形状"在新切片里滑窗匹配，唯一强命中即目标函数；再用 `SequenceMatcher` 对齐把 `cbz`/`str` 逐条映射过去。
   - **边界与匹配置信度**：先读 `LC_FUNCTION_STARTS` 确定真实函数范围；不要把旧脚本的固定 4072 字节窗口当作函数长度。记录候选数量、最佳与次佳匹配，随后用字段写入、直接调用方和类型派发交叉核对。内容字段可能通过 string 赋值调用写入，不能只寻找 `STR ...,#0x130`。
3. **确定补丁点**：
   - `revoke`：入口 `cbz`（`E00F0034` → `7F000014`）。**注意分支偏移可能变**（`269332` 是 `cbz w0,+0x208`），补丁的 `b` 要跳到与 `cbz` 相同的目标。
   - `revoke-tip`：入口保持 + `str x0,[x19,#0x168]`（`60B600F9` → `7FB600F9`）。**字段偏移不要照抄**：从本二进制的 `str` 指令重新解码 `newMsgId` 偏移（`269332` 已从 `0x168` 变为 `0x198`），`replaceMsg` = `newMsgId + 8`（再用函数体内 `ldr …,[x19,#replace]` 交叉核对）。
   - 屏蔽更新：按上一节的方式（字节 diff 老版本，或解析 `XAppUpdateManager` 方法表）。
4. **判断 hook 机制**：函数还带派发桩 → 走 `revokeHookConfigs`（无 `runtime-tip` 目标）；已无派发桩 → 走内联 hook，新增 `runtime-tip` 目标 + `inlineRevokeHookConfigs` 条目，并在 `__DATA` 尾找一处零填充空隙做 `SLOT`。若要支持 `{content}`，还必须从该构建重新确认通用 Message 接收/终结路径以及 serverId、msgType、content 三个字段偏移，再增加独立槽位；不得把撤回 handler 的输出字段当作普通 Message 字段照抄。
5. **登记支持**：把构建号加进 `RuntimeTipInstaller.supportedBuildVersions`（`CLI.swift`）和 `Runtime.mm` 相应的表。
6. **重算校验和**：改完 `patches.json` 后跑 `bash Scripts/hash-patches.sh` 刷新 `patches.json.sha256`，两个文件一起提交——GUI 的 OTA「拉取最新补丁数据」会拿它校验，sidecar 过期会让新构建号拉不下来。
7. **校验**：`swift build`、`swift test`，再对真实二进制 `install --dry-run`（silent / runtime-tip / block-update 三种模式）确认每个补丁点原始字节匹配。
8. **运行时回归**：`--dry-run` / 编译 / 测试都无法证明 hook 真正生效——务必在真实微信上发消息 + 撤回、检查更新，做一次实测（见 README 的"安装后请验证"）。

> 提醒：`RuntimeTipInstaller.supportedBuildVersions`（`CLI.swift`）、`revokeHookConfigs` / `inlineRevokeHookConfigs`（`Runtime.mm`）、`patches.json`、以及它的 `patches.json.sha256`（`Scripts/hash-patches.sh` 重算）四处要保持一致。

---

## 代码地图

| 文件 | 职责 |
| --- | --- |
| `Sources/WeChatAntiRecall/CLI.swift` | 命令解析、Mach-O 补丁 / dylib 注入、备份、重签名、`tip-phrase` 存储 |
| `Sources/WeChatAntiRecall/Clone.swift` | `clone` 命令：复制 App、改写 Info.plist、独立 Bundle ID |
| `Sources/WeChatAntiRecallRuntime/Runtime.mm` | 运行时 hook：`parseRevokeXML` 派发桩 / 内联挂载、提示渲染、时间 / 内容缓存、调试探针 |
| `Sources/WeChatAntiRecallRuntime/RecallLog.mm` | 撤回记录：设置读取、JSONL 编码、去重、轮转、后台写入 |
| `Sources/WeChatAntiRecallRuntime/KeywordAlert.mm` / `MessageProbe.h` | 关键词提醒：设置解析、匹配、通知；以及红包模块导出的已验证 Message 字段读取 |
| `Sources/WeChatAntiRecallRuntime/WindowPrivacy.mm` | 窗口隐私：定时 + 通知触发的 `NSWindow.sharingType` 隐藏与恢复 |
| `Sources/WeChatAntiRecall/WindowPrivacy.swift` | `window-privacy` 命令的选项与偏好存储 |
| `Sources/WeChatAntiRecall/KeywordAlert.swift` | `keyword-alert` 命令的选项、关键词归一化、偏好存储 |
| `Sources/WeChatAntiRecall/RecallLog.swift` | `recall-log` 命令的选项、偏好存储、日志读取与清空 |
| `patches.json` | 每个构建号的字节补丁 |
| `Sources/WeChatAntiRecall/JSONOutput.swift` | `--json` 的 `Encodable` DTO + 共享编码器（GUI 契约） |
| `Sources/WeChatAntiRecallGUI/` | SwiftUI 图形界面（薄壳，shell-out 调用预编译 CLI） |
| `Scripts/make-app.sh` / `make-icon.sh` | 组装 `.app` / 生成图标 |
| `.github/workflows/{ci,release}.yml` | PR 构建测试 + universal canary / tag 发布 DMG |
| `Tests/` | 补丁配置、Mach-O 注入、内联 hook 引擎、提示渲染、`clone`、`--json` 输出的单元测试 |

---

## `--json` 契约（GUI 依赖）

`versions`、`install`、`clone` 支持 `--json`，输出机器可读 JSON（GUI 不解析本地化中文 stdout）。

- **成功**：`versions` 输出 `VersionsReport`（`app` / `supported` / `runtimeTipSupported` / `installedBuildTargets` / `features` / `catalog`）；`install`/`clone` 在 `--dry-run` 下输出逐条补丁点状态。
- **失败**：`main()` 检测到参数含 `--json` 时，把顶层错误输出为 `{"schemaVersion":1,"error":{kind,message,…}}` 到 **stdout**（仍 `exit 1`）；不带 `--json` 时保持原 stderr 行为。
- 每个报告带 `schemaVersion`（当前 `1`），用于检测 CLI/GUI 版本不匹配。改动输出结构时**递增它**。
- **权威事实**：自定义提示是否可用只看 `runtimeTipSupported`（源自编译期的 `supportedBuildVersions`），**不能**从 `patches.json` 里是否存在 `runtime-tip` 目标推断——见上文崩溃互锁。
- DTO 定义在 `JSONOutput.swift`；不要给 `Decodable`-only 的领域类型（`PatchEntry` 等）加 `Encodable`。

## GUI 与发布

- GUI 是 `Sources/WeChatAntiRecallGUI/` 的 SwiftUI 可执行目标，通过 `Process` / `osascript` 调用 **bundle 内**的预编译 `wechat-antirecall`，并显式传绝对 `--config` / `--runtime-dylib` / `--app`；`tip-phrase` 走普通用户权限（绝不提权，否则写错 home 的容器 plist）。
- **安装权限模型（重要）**：`/Applications/WeChat.app` 通常**归当前用户所有**，真正拦住修改的是 macOS 的 **App 管理 TCC**，不是 Unix 权限。**提权（osascript admin）并不能绕过它**——ad-hoc 签名的 App、以及它 `do shell script … with administrator privileges` 派生的 root 子进程，若"负责 App"没有 **App 管理 / 完全磁盘访问**授权，`access(W_OK)` 在 euid=0 下仍返回 EPERM。因此 `install`/`restore` 先用 `AppState.probeInstallAccess` 做一次**非提权写探针**（往 `Contents/Resources` 写个临时文件）分三类：`writableAsUser`（本 App 已有磁盘访问 → 直接以用户身份 `runUser` 安装，**无需密码**，也避开了 root 子进程 TCC 归属的坑）、`needsElevation`（bundle 归 root → 走 `runAdmin`）、`blockedByTCC`（bundle 归当前用户但写不了 → 弹「完全磁盘访问」引导横幅，**不再白弹密码**）。dry-run 故意**不**校验写权限（只校验字节），探针才是提权前的闸门。
- **ad-hoc 授权是按构建的**：cdhash 每次重签都会变，用户每次重新打补丁 / 微信升级后可能要在「完全磁盘访问」列表里删旧的重新加。
- **重签名与扩展属性**：`resign()` 只尽力执行 `xattr -dr com.apple.quarantine <app>`，然后做最终 `codesign --verify --deep --strict`。不可清除全部扩展属性：270102 内嵌 XPlayer 的 `Frameworks/vk_swiftshader_icd.json` 用 `com.apple.cs.CodeDirectory` / `CodeRequirements` / `CodeSignature` 保存签名，旧 `xattr -cr` 会在验证成功后删掉这些签名，造成安装器报告成功但后续验证失败。2026-09-30 增加带已签名 JSON 的回归用例并修复。OS 保护的 `com.apple.provenance` 保留；无法移除隔离标记也不直接报安装失败，最终代码签名检查仍必须通过。
- 本地构建：`bash Scripts/make-app.sh`（默认 arm64；`ARCHS="arm64 x86_64"` 才做 universal，但 `Runtime.mm` 用了无 `#if __arm64__` 守卫的 arm64 专有 API，universal 可能硬编译失败——`ci.yml` 的 canary 就是验证这个）。
- 发布：打 `v*` tag → `release.yml` 在 `macos-14` 构建 + `make-app.sh` + `hdiutil` 打 DMG + `gh release create`。默认 ad-hoc 签名（无付费证书），用户首次需右键→打开。有 Developer ID 时给 `make-app.sh` 传 `CODESIGN_ID` 并加公证步骤即可。
- 更新地址烘焙在 `Sources/WeChatAntiRecallGUI/Services/UpdateService.swift` 的 `Upstream`（`fzlzjerry/wechat-antirecall`）。换仓库改这里。
