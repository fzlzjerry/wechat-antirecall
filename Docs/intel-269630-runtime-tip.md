# Intel x86_64：微信 4.1.13 / 269630 runtime-tip 实测与参考实现

Related to [#55](https://github.com/fzlzjerry/wechat-antirecall/issues/55)。

**结论：实体 Intel Mac 上，独立的 x86_64 runtime hook 已能保留对方撤回的消息并显示 `[已拦截撤回]`，自己撤回仍走原生行为。**

**范围：这是实验性参考实现和协作证据，不是 GUI/CLI 已支持 Intel 的发布声明。** 不修改 `patches.json`、SwiftPM target、发行架构或支持列表；不替 #55 的完整 Intel 发布验收打勾。这里的“新版本”只指下列实际测试的 build，不代表任何未来版本。

## 测试环境和结果

- 验收日期：2026-09-10。
- 实体 Intel x86_64，macOS 13.7.8。
- `CFBundleShortVersionString=4.1.13`、`CFBundleVersion=269630`。
- 原 App `CFBundleIdentifier=com.tencent.xinWeChat`。
- 编译独立 runtime：Apple clang 14.0.3、C++17、Foundation。
- 本机 Swift 为 5.8.1，低于项目 manifest 的 5.9；未将独立 clang 自测说成整个 SwiftPM/GUI 编译通过。

| 场景 | 实验副本 | 正式路径 `/Applications/WeChat.app` |
| --- | --- | --- |
| 对方撤回：原消息保留并显示 `[已拦截撤回]` | 用户人工确认通过 | 用户人工确认通过 |
| 自己撤回：原消息移除、原生提示、无 `[已拦截撤回]` | 用户人工确认通过 | 用户人工确认通过 |
| runtime 加载与 hook 安装 | 固定状态输出、映像检查通过 | 固定状态输出、映像检查通过 |
| `codesign --verify --deep --strict` | 通过 | 通过（ad-hoc） |

人工 UI 结果是测试者反馈，不是自动化截图或 E2E 断言；没有上传聊天截图、账号、消息、二维码或原始日志。登录/网络在测试期间可用，但尚无独立完整回归；麦克风、摄像头、所有消息类型、群聊、多语言、跨设备本人撤回、长期稳定性和实际回滚尚未完整验证。

## 可复现文件

- [参考 runtime](../Scripts/experimental/intel-269630/RuntimeTipIntel.mm)：正式路径版本的源码快照，保持与实机验收版本相同；仍保留实验时期的固定状态字符串。
- [合成夹具](../Scripts/experimental/intel-269630/fixtures.S)：手写 assembly，非提取的微信二进制。
- [受控测试](../Scripts/experimental/intel-269630/runtime_test.cpp)：调用真实 installer/wrapper，在当前测试进程的匿名内存上验证，不启动微信。
- [测试入口](../Scripts/experimental/intel-269630/run_tests.py)：串行 Debug、Release、ASan/UBSan、重复运行及错误路径 dlopen 拒绝。
- [只读预检](intel-preflight.md)：Python 标准库工具，区分 catalog 覆盖与业务验收，不安装补丁。

需要 Python 3.10+ 与 macOS Command Line Tools。仓库根目录执行：

```sh
python3 -B -m unittest discover -s Scripts/tests -p 'test_intel_preflight.py' -v
python3 -B Scripts/experimental/intel-269630/run_tests.py
python3 -B Scripts/intel-preflight.py --app /path/to/original/WeChat.app --summary
```

第一项在合成 Mach-O 上验证 thin/fat、slice 范围、重复架构、CPU mismatch、路径逃逸与 catalog 解析；第二项要求 Intel macOS。构建输出只在临时目录，退出自动清理。没有自动安装、签名、停止或启动微信的入口。

runtime 源码目前固定 `/Applications/WeChat.app`、`com.tencent.xinWeChat`、build、UUID、入口和 store 字节，不是可传任意 App 的通用 hook。**请勿直接复制 `.payload` 到现用 App；本 PR 不提供无人值守安装器。**

## 原始二进制标识

所有哈希取自修改前原件，不是 ad-hoc 重签后的二进制。

| 项目 | 值 |
| --- | --- |
| 二进制 | `Contents/Resources/wechat.dylib` |
| 完整 fat SHA-256 | `cb6cdce4af05ddfecd750f691b4370320d138d3802d19030d65bf8a0dbc99c12` |
| x86_64 slice SHA-256 | `837c498eb1f7bf403948bdf53d5808e54d4173b46b62ed89890a1b4e0135dda6` |
| x86_64 UUID | `93FCF137-72E5-34A1-82FE-9110EF54C3C3` |
| slice 起点 / 长度 | `16384 / 178952288` bytes |

## 只读定位证据

地址为 x86_64 slice 内未 slide 的 VA，不是整个 fat 文件 offset。文件位置按 segment/section 映射；运行地址使用 dyld slide + VA。

| 位置 | VA / 偏移 | 原始字节或语义 |
| --- | --- | --- |
| 撤回 parser 入口 | `0x512C510` | `554889E5415741564155415453` |
| caller 的调用点 | `0x512C49E` | `E86D000000` → `call 0x512C510` |
| newmsgid store | `0x512CD72` | `488983C8010000` → `mov qword ptr [rbx+0x1C8],rax` |
| replaceMsg 访问 | `0x512CE08` | `4C8DB3D0010000` → `lea r14,[rbx+0x1D0]` |
| 输出字段 | `+0x1C8 / +0x1D0` | `uint64_t newmsgid / libc++ std::string replaceMsg` |
| parser ABI | 三参数 | `bool (void *, std::string *, void *)` |

定位采用邻近官方 build 269629 作参考、函数边界与 Capstone 分块反汇编、caller 和字段指令交叉确认。字符串锚点包括 `revoke_climsgid`、`TryParseMessageX`、`ParseMessageXml`、`OnMessageRevoke`，但直接字符串 xref 扫描没有命中；**不是凭字符串地址打补丁**。分块扫描也不是完整反编译覆盖证明。

未完成本 build 的 IDA Pro/Hex-Rays 全库交叉确认；此项是 #55 仍待维护者或协作者补齐的证据。函数入口已确认，但这里不提交未经独立复核的完整函数结束 VA。没有复用 #55 的 269574 地址。

## hook 与双路径语义

入口覆盖按完整指令边界取 13 bytes：`push rbp; mov rbp,rsp; push r15; push r14; push r13; push r12; push rbx`，没有 RIP-relative 指令。入口用 `movabs rax,<wrapper>; jmp rax; nop`；trampoline 重放原序言后用 `FF2500000000` 加绝对目标回到 `entry+13`，回跳不破坏寄存器或 flags。

这不是通用 x86_64 relocator；新序言若含相对寻址或相对控制流，必须重新实现/验证，不能把本次 13-byte 长度照抄。安装只在加载初始化期间进行，不支持运行中异步热补丁。

wrapper 先调用原 parser，保留原返回值。随后验证对象访问权限、24-byte libc++ 字符串布局、撤回 XML、唯一非零数字 `<newmsgid>` 与输出 ID 相等、原提示非空且含撤回语义。只有匹配的对方撤回才：

1. `replaceMsg = "[已拦截撤回] " + 原生提示`；
2. 字符串赋值成功后，再将 `newmsgid` 清零；
3. 不修改 XML 或第三参数 flag。

本人撤回识别：提示以 `You recalled `、`你撤回`、`你收回`、`你回收` 开头，或 XML 含对应片段时原样返回。这是**文案启发式，不是发送者身份验证**；可能因为昵称/XML 中出现这些词而跳过对方撤回，未覆盖的语言也不保证正确。对象、XML、ID 或字符串校验失败时不做后处理，保留原生路径。

该原型没有通用 Message finalizer hook，没有 `{content}` 缓存、任意模板、更新阻止、红包自动化或 ARM64 适配。最初尝试把 7-byte store 改成更长清零指令被放弃，未把截断指令纳入方案。

## 签名、加载与恢复经验

- 修改 App 使腾讯原始签名失效。实测为 ad-hoc、`TeamIdentifier=not set`，不是保留厂商身份。
- 从原件保存所有 entitlements；按组件恢复，最终主 App 显式使用原 plist 加 `com.apple.security.cs.disable-library-validation` 和 `com.apple.security.cs.allow-unsigned-executable-memory`。这会放宽安全限制，不能承诺账号零风险。
- 最终保留 Sandbox、application-groups、allow-jit、Hardened Runtime，包括原 Team ID 绑定的 entitlement 值。不要仅因签名 TeamIdentifier 为空就删除这些值。
- `--preserve-metadata=identifier,flags,runtime` **不包括 entitlements**；重新签外层 App 若不显式提供 plist，曾导致 entitlements 丢失，已在再次启动前恢复并回读比较。
- `(runtime)` 与 `(adhoc,runtime)` 都表示包含 Hardened Runtime。旧审计器只精确匹配前者而误报，不能把输出格式当权限丢失。
- 外加 `sandbox-exec`、临时 HOME 并拒绝正式 Containers 的测试曾在 `libsecinit_appsandbox` 初始化中 `SIGILL`，但正式路径正常启动。它们不是等价启动条件，不能据此断言 Team ID 是确定根因。
- 绑定暂存路径的 payload 放到正式路径会主动拒绝。需使用 Formal 版本，检查唯一映像路径与 constructor/install 各一次。
- 构建产物与可加载 dylib 分开存放，避免加载器发现两份 runtime。
- 原 App 完整备份以及安装前 App 实体均保留；文件内容哈希、软链接、权限和签名验证通过。复制产生的 provenance/quarantine、ctime/mtime 差异分开记录，不删除系统安全属性。
- 安装只操作 App 文件，未直接编辑/清理聊天数据库、Group Containers 或 Keychain；正常运行微信会自行读写数据。App 备份不等于聊天记录备份，不能保证数据或账号零风险。

## 后续集成与验收缺口

- 将独立 runtime 接入架构感知的 CLI/GUI 安装、卸载和 runtime 支持列表，而非仅增加 `patches.json` 条目。
- 明确签名快照、替换回滚以及唯一目标 path/build/arch/hash 校验。
- 原型的结构解析、字符串 ABI、初始化时线程安全及文案启发式需要进一步 review/hardening。
- 增加真实恢复验证、麦克风/摄像头等权限回归以及更多消息类型、语言、跨设备和群聊测试。
- 完整 IDA/Hex-Rays 证据与全项目 Intel build/CI 仍待补齐；不关闭 #55。

## English summary

An independent x86_64 parser-entry trampoline was verified on physical Intel macOS 13.7.8 with WeChat 4.1.13 **build 269630**. Both an isolated copy and the installed `/Applications/WeChat.app` passed user-reported manual checks: retain another person's recalled message with `[已拦截撤回]`, while preserving native self-recall behavior.

This contribution contains the tested source snapshot, synthetic installer/wrapper tests and read-only preflight tooling. It does **not** claim universal Intel GUI/CLI support, future-build compatibility, full IDA/Hex-Rays validation, successful rollback testing, or absence of account/data risk. No WeChat binaries, private logs, screenshots or account data are included.
