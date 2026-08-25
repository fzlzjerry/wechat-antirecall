# 维护指南

面向维护者：`patches.json` 结构、各补丁目标的含义、运行时 hook 的两种机制、屏蔽更新补丁点的逆向来源、逐字节核对记录、`{content}` 实现，以及**如何新增一个构建号**。

用户向的使用说明在 [README.md](README.md)。

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
| `runtime-tip` | 内联 hook 的入口改写（仅内联构建；269340/269341/269574/269575/269576/269577/269578/269579 各含两处） | `--runtime-tip` |
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

- 安装时把目标函数入口的 3 条指令改成 `adrp x16,SLOT; ldr x16,[x16]; br x16`（patches.json 的 `runtime-tip` 目标；269340/269341/269574/269575/269576/269577/269578/269579 同时改写撤回解析器和 Message 终结器）。`SLOT` 落在 `wechat.dylib` `__DATA` 段尾的零填充空隙里。
- dylib 加载时建立 trampoline（重放原 3 条指令、再跳回入口后第 4 条），并把 hook 函数指针写进 `SLOT`。runtime 通过**解码被改写的入口**自动定位 `SLOT`，无需硬编码。
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
| 269579 | `0x4958830` + `0x48f64e8` | `0x9f57f00` + `0x9f57f08` | 当前安装的微信 4.1.13.11；相对 269578 均匀 `-0x1C`，字段仍为 `0x1C8`/`0x1D0` 与 `0xF8`/`0x0C`/`0x130` |

⚠️ **入口改写和 dylib 注入必须成对安装**：`--runtime-tip` 会一起完成二者，`RuntimeTipInstaller` 先跑注入。绝不要单独只打入口补丁——缺少 dylib 时 `SLOT` 不会被赋值，函数会跳空指针崩溃。`restore` 恢复 `wechat.dylib` 备份会同时撤销所有入口补丁、`SLOT` 和注入。

内联 hook 引擎（指令编码、trampoline、跳转槽派发）有单元测试覆盖（`InlineHookEngineTests`、`RuntimeRewriteTests`）。

---

## `{content}` 实现

对 269340/269341/269574/269575/269576/269577/269578/269579 arm64 切片的聚焦分析确认：撤回 XML 解析器只服务消息扩展类型 `71/72`，不是所有接收消息的公共路径；输出对象里的 `newmsgid` 也不能当作普通 Message 的 server ID。269340/269341 的字段为 `+0x198`，269574/269575/269576/269577/269578/269579 移动到 `+0x1C8`；八个解析器入口依次为 `0x462e200`、`0x462e60c`、`0x4905488`、`0x4904ed0`、`0x490521c`、`0x4958824`、`0x495884c`、`0x4958830`。

真正的接收路径使用第二个内联 hook：269340 的 `sub_45CE1A4`、269341 的 `sub_45CE5B0`、269574 的 `sub_48A3B20`、269575 的 `sub_48A3568`、269576 的 `sub_48A38B4`、269577 的 `sub_48F64DC`、269578 的 `sub_48F6504` 以及 269579 的 `sub_48F64E8` 是通用 Message 终结器。269579 的网络消息构造函数 `sub_48F5180` 在调用终结器之前仍已填好：

- `serverId`：Message `+0xF8`；
- `msgType`：Message `+0x0C`；
- `content`（`std::string`）：Message `+0x130`。

构造函数随后无条件调用终结器；runtime 在原终结器之前按 `serverId` 缓存：文本做 trim 和 UTF-8 边界安全截断；媒体使用真实 `msgType` 映射为图片、语音、视频、动画表情、位置、链接、音视频通话或系统消息占位符。撤回 XML 到来时再用其中的 `<newmsgid>` 查表并替换 `{content}`。

269340/269341 的 `runtime-tip` 使用 `SLOT 0x9a9ff00` 与相邻的 `0x9a9ff08`；269574/269575/269576 使用 `__DATA` 尾部的 `0x9ecbf00` 与 `0x9ecbf08`；269577/269578/269579 使用 `0x9f57f00` 与 `0x9f57f08`。缓存只存在于当前微信进程，最多 512 条；文本预览最多 240 个 UTF-8 字节。冷启动前收到、已淘汰或 server ID 为 0 的消息仍会 miss，此时 `replaceContentPlaceholder` 会连同分隔符一起剥掉。其他已支持构建尚未反向确认通用 Message 字段布局，因此仍按冷缓存处理 `{content}`。

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
- **269579**：当前安装的微信 4.1.13.11（`CFBundleVersion` 269579；`WeChatBundleVersion` `4.1.13.11`；arm64 切片 SHA-256 `3b19426183206408af0297489464078df1a709b23dae92fdbf5a7c6d305cfe83`）。269574+ 的撤回解析器几何特征在整个 arm64 切片中仍唯一逐字命中，并均匀重定位 `-0x1C`（相对 269578）：入口 `0x4958830`，守卫 `entry+0x270`=`0x4958aa0`（`40100034`→`82000014`），`newmsgid` 写入 `entry+0xA10`=`0x4959240`（`60E600F9`→`7FE600F9`）。字段由本构建指令重新解码为 `newMsgId=+0x1C8`、`replaceMsg=+0x1D0`。唯一调用方 `0x49587ac` 仍按 `x0` 输出对象、`x1` 原始 XML、`x2` 标志指针传参。通用 Message 终结器同样 `-0x1C` 到 `0x48f64e8`，`ldrb/cmp/ccmp` 形状唯一命中；网络构造函数 `0x48f5180` 仍把 `serverId`/`msgType`/`content` 写到 `+0xF8`/`+0x0C`/`+0x130` 后无条件 `bl 0x48f64e8`。`__common` 结束地址 `0x9f54b48` 到 `__DATA` 虚拟结束地址 `0x9f58000` 仍是零填充，两个 SLOT 保持 `0x9f57f00`/`0x9f57f08`；入口桩 `F0AF02F0108247F900021FD6` 与 `10B302B0108647F900021FD6` 均经编码/解码回环验证（解析器与终结器都仍在同一 4K 页内，因此 ADRP 与 269578 相同）。8 个更新补丁点通过本构建 `XAppUpdateManager` 相对方法表（selref + chained fixup）按方法名重新解析：`startUpdater` `0x27d068`、`checkForUpdates:` `0x27f1a0`、`startBackgroundUpdatesCheck:` `0x27f464`、`enableAutoUpdate:` `0x27f844` 保持不变，访问器对平移回 `0x289bb0`/`0x289bb8`/`0x289bc0`/`0x289bc8`（相对 269578 `-8`，与 269577 相同），字段仍为 `0x18`/`0x19`。随后使用 IDA Professional 9.4 + Hex-Rays 对 arm64 切片做完整自动分析：函数边界、唯一解析器调用、三个参数、全部字段访问、通用终结器调用链、八个 Objective-C 方法名/语义及 12 处原始字节均一致，自动比较 `69/69` 通过（IDA 将终结器的 27 个直接 `BL` 加 1 个尾调用 `B` 统计为 28 个代码 xref）。release 构建、129 项完整测试以及 silent、runtime-tip、runtime-tip + block-update、update-only 四种真实安装包 dry-run 均通过。

---

## 新增一个构建号

大致流程：

1. **拿到目标 `wechat.dylib`**：从对应版本的微信 App 里取 `Contents/Resources/wechat.dylib`。
2. **定位 `parseRevokeXML`**：按已知函数体几何特征（入口 `stp` 序列、`cbz w0`、`str x0,[x19,#0x168]`）在 arm64 切片里搜，确认唯一命中。
   - **几何特征失配时**（函数被重编译，命中数为 0 或 >1，如 `269332`）：改用**参考二进制 diff**。取一个已支持的邻近构建（如从腾讯 CDN `WeChatMac_4.1.x.dmg` 下载 4.1.11），在参考里用几何特征定位 `parseRevokeXML`，把函数体"屏蔽掉地址相关立即数（`adrp`/`bl`/`b`/`b.cond`/`cbz`/`ldr literal` 的偏移）后的指令形状"在新切片里滑窗匹配，唯一强命中即目标函数；再用 `SequenceMatcher` 对齐把 `cbz`/`str` 逐条映射过去。
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
- **重签名与 `com.apple.provenance`**：`resign()` 在 codesign 成功**之后**才做的 `xattr -cr <app>` 是"尽力而为"（`runProcessStatus`，失败不致命）。macOS 15+ 很多文件带 OS 保护的 `com.apple.provenance` xattr，用户身份 `xattr -c` 都删不掉（EPERM）——它无害（bundle 此时已签好），以前却会把一个本已成功的安装报成失败。
- 本地构建：`bash Scripts/make-app.sh`（默认 arm64；`ARCHS="arm64 x86_64"` 才做 universal，但 `Runtime.mm` 用了无 `#if __arm64__` 守卫的 arm64 专有 API，universal 可能硬编译失败——`ci.yml` 的 canary 就是验证这个）。
- 发布：打 `v*` tag → `release.yml` 在 `macos-14` 构建 + `make-app.sh` + `hdiutil` 打 DMG + `gh release create`。默认 ad-hoc 签名（无付费证书），用户首次需右键→打开。有 Developer ID 时给 `make-app.sh` 传 `CODESIGN_ID` 并加公证步骤即可。
- 更新地址烘焙在 `Sources/WeChatAntiRecallGUI/Services/UpdateService.swift` 的 `Upstream`（`fzlzjerry/wechat-antirecall`）。换仓库改这里。
