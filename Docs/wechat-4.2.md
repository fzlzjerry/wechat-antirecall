# 微信 4.2 适配记录

2026-11-13 核对两个 Apple Silicon 构建：本机的 **4.2.0.16（270352）**，以及当日从 [微信官网](https://mac.weixin.qq.com/) 下载的 **4.2.0.54（270390）**。官网下载地址为 `https://dldir1v6.qq.com/weixin/Universal/Mac/WeChatMac_4.2.0.dmg`；该 URL 的内容会更新，不能把版本号或校验和视为永久固定。

支持静默防撤回、原生提示、自定义提示、内容预览、撤回记录、关键词提醒、自动红包及屏蔽更新。多开和窗口隐私沿用现有机制。真实账号的撤回、红包领取、关键词通知和更新行为仍需业务实测。

## 样本身份

| 构建 | 完整 universal `wechat.dylib` SHA-256 | arm64 切片 SHA-256 |
| --- | --- | --- |
| 270352 | `5d4a97f58b3b18d9ad47f11aa8029b93f7650d266e801f90a19e52cda1824a19` | `c6426028f92794b50ef5edab8e8a94d79e30c68979ec004474fc634f07702a2f` |
| 270390 | `685914bfd55f9e102f3769d2f25e37a0735cd0ce41485b36d5df83de6eecd2b8` | `9beeba8587f6b342a459e7e583d662859da2a701268787967f849f17dfc00596` |

全部地址为切片虚拟地址，运行时需要加 ASLR slide。分析采用 Mach-O 段表、`LC_FUNCTION_STARTS`、Capstone 反汇编与 IDA Professional 9.4 / Hex-Rays 定向分析；部分反编译存在 SP 警告，ABI 以调用点寄存器流和反汇编为准。REA 服务的函数分析与关闭请求超时，因此本轮没有把它的结果当作成功分析证据。

## 撤回与接收路径

| 项目 | 270352 | 270390 |
| --- | ---: | ---: |
| 撤回解析器起止（结束地址不含） | `0x4E7D4DC`–`0x4E7E5F8` | `0x4613EC4`–`0x4615028` |
| 唯一直接调用点 | `0x4E7D458` | `0x4613E44` |
| 静默分支 | `0x4E7D74C` | `0x461413C` |
| `newmsgid` 写入 | `0x4E7DEEC` | `0x4614904` |
| Message 终结器起止 | `0x4E1A094`–`0x4E1A1A8` | `0x45C0B2C`–`0x45C0C44` |
| 网络 Message 构造函数 | `0x4E18D2C` | `0x45BF724` |
| 构造函数中的终结器调用点 | `0x4E191E0` | `0x45BFBA4` |
| 撤回 / Message hook 槽 | `0xA68BFF0` / `0xA68BFF8` | `0x9E2FFF0` / `0x9E2FFF8` |
| `__common` 结束 / `__DATA` 结束 | `0xA68A828` / `0xA68C000` | `0x9E2D100` / `0x9E30000` |

270352 的解析器保留旧几何特征，在全切片中唯一命中。270390 的解析器被重编译，由 `0x111C` 增长到 `0x1164` 字节，静默分支从入口 `+0x270` 移到 `+0x278`，字段写入从 `+0xA10` 移到 `+0xA40`。不能整体平移旧地址。以已验证的 270135 函数做地址立即数归一化比较，270390 最佳候选为 `0x4613EC4`（0.8288），同前缀及近似尺寸候选中的次佳为 0.1995；再通过 XML 字段、调用方和输出写入确认。

两版的静默分支均为 `40100034` → `82000014`，跳转目标不变；提示补丁均为 `60E600F9` → `7FE600F9`。撤回对象字段仍为 `newMsgId +0x1C8`、`replaceMsg +0x1D0`。调用方仍使用 x0 输出对象、x1 XML 字符串、x2 标志指针。

网络 Message 的 `serverId +0xF8`、`msgType +0x0C`、`content +0x130`、`created +0x114`、`from +0x18`、`to +0x30` 保持不变；终结器前缀仍为 `086049391F0500712008407A`。270390 的终结器增长 4 字节，其原始条件分支仍位于入口 `+12`，trampoline 的三个重放指令不变。

两组槽均位于可写 `__DATA` 中、所有 section 之后的零填充区域。入口编码由新地址重新计算，测试同时核对编码字节及解码所得槽地址。

## 自动红包与关键词提醒

| 项目 | 270352 | 270390 |
| --- | ---: | ---: |
| Message → display | `0x4E1D918` | `0x45C46AC` |
| display 析构 | `0x39B888` | `0x378E0C` |
| AppContext getter | `0x47993F4` | `0x4032264` |
| GetService | `0x469DE6C` | `0x3F72A2C` |
| ReceiveRedEnvelope | `0x454BDAC` | `0x3E456C8` |
| OpenRedEnvelope | `0x454BDB4` | `0x3E456D0` |
| 任务订阅 | `0x4F96C0` | `0x53B61C` |
| 服务描述符 | `0x9D5AA18` | `0x9516938` |
| 普通 / 接收 / 拆包 RTTI | `0x9D5F800` / `0x9FCCCA8` / `0x9FCCD28` | `0x951B7D0` / `0x976CA78` / `0x976CAF8` |
| Message vtable | `0xA000348` | `0x9799028` |
| 公共 / 接收字段解析 | `0x45448C8` / `0x45450C8` | `0x3E3E660` / `0x3E3EE90` |
| 普通红包封面条件 | `0x1385440` | `0x12A57C8` |
| `__text` 范围 | `0x18000`–`0x72AD918` | `0x15000`–`0x6ABA284` |

服务地址来自实际调用方的 BL 及数据 ADRP，不采用统一位移。270390 的 `0x53AD04` 和 `0x12A5A00` 分别调用接收和拆包 thunk，两个 thunk 分别尾调用 `0x3E28E00` / `0x3E291F8`；两个业务调用方交叉确认订阅入口 `0x53B61C`。同类订阅模板有多个近似相同的实例，不能仅凭函数指纹选最高匹配。

Message / display 仍为 632 / 848 字节；task / subscription / source location 仍为 56 / 40 / 32 字节。display、shared_ptr、任务和订阅使用 x8 传递隐藏返回地址，订阅使用 x0–x4。AppContext → account context → service center 的虚表槽继续为 `+0x68` / `+0x30`。RTTI 名仍为 `_45ffb1f3` / `_fcb06a8b` / `_98bba57a`。回包中的 `retcode`、`sendId`、`isSender`、`receiveStatus`、`hbStatus`、`hbType`、`timingIdentifier` 偏移继续为 `8`、`40`、`88`、`120`、`124`、`152`、`304`。

九处运行时指纹按构建单独记录。270390 的 display 转换和接收字段解析的栈帧发生变化，服务 thunk 的尾跳转也改变。自动红包组件标记升为 `WeChatAntiRecallRedPacket:10`；关键词提醒与撤回记录分别升为 `WeChatAntiRecallKeywordAlert:2` 和 `WeChatAntiRecallRecallLog:2`，让旧组件正确提示需要更新。日志格式和设置格式未改变。窗口隐私不依赖新地址，其组件标记保持不变。

## 屏蔽更新

从各自 `XAppUpdateManager` 的相对方法表按 selector 重新解析：

| selector | 270352 | 270390 |
| --- | ---: | ---: |
| `startUpdater` | `0x292DE4` | `0x2827C8` |
| `checkForUpdates:` | `0x294F1C` | `0x2849EC` |
| `startBackgroundUpdatesCheck:` | `0x2951E0` | `0x284CBC` |
| `enableAutoUpdate:` | `0x2955C0` | `0x2850DC` |
| `automaticallyDownloadsUpdates` | `0x29F92C` | `0x28F91C` |
| `setAutomaticallyDownloadsUpdates:` | `0x29F934` | `0x28F924` |
| `canCheckForUpdate` | `0x29F93C` | `0x28F92C` |
| `setCanCheckForUpdate:` | `0x29F944` | `0x28F934` |

两个 getter/setter 的字段仍为 `+0x18` / `+0x19`。仅安装 `--runtime-tip` 不会选择或改写这些更新补丁。

## 验证边界

已完成 Release 编译、246 项测试、两个真实二进制的静默 / 提示 / runtime / runtime+屏蔽更新 / 仅更新共 10 种 dry-run，以及故意破坏 expected 字节后的拒绝检查。用独立 bundle ID 的副本验证了 runtime 安装、重复安装幂等、严格递归签名校验和备份的逐字节还原；打包后的 CLI 能识别两个版本及四个运行组件，App 签名有效。

两个副本均在 LLDB 的 `WeChatMain` 入口暂停，此时两个槽已分别指向 `hookedParseRevokeXML` / `hookedFinalizeMessage`，红包模块已通过九处原生指纹校验并初始化。将一条合成文本消息送入实际被改写的 Message 入口，确认原生 trampoline 正常返回，内容缓存读出 `wechat42-probe`。将合成撤回 XML 送入实际被改写的解析器入口，确认返回“已拦截一条撤回消息”，`newMsgId` 为零。

上述启动检查使用独立沙盒标识，未使用原微信的 App Group 或网络权限；检查后终止了测试进程。隔离副本验证期间，本机原 `/Applications/WeChat.app` 核心二进制 SHA-256 与适配前一致。没有发出真实聊天、领取或更新请求，合成输入不能替代业务实测。

随后按用户要求，通过 CLI 在本机 270352 上完成带备份的 runtime 安装，签名校验通过，重启后微信进程正常运行。自动红包、撤回记录和已有提示短语的设置保留，CLI 确认新组件可用；这不代表已经完成真实聊天或红包领取实测。

本轮可复查的本地分析和验证输出存放在 `work/20261113-wechat-42-support/evidence/`；样本、下载包、反汇编和调试副本在被 Git 忽略的 `work/` 中。业务实测需要使用者在实际登录的微信中完成，不能用静态地址匹配或合成输入替代。
