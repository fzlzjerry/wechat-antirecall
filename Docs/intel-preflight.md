# Intel 只读预检工具

这个脚本用于在本地对微信 App 做只读检查，不会修改、安装、重签名或联网。

## 用途

1. 读取指定 `WeChat.app` 的 `Info.plist`。
2. 解析 `Contents/Resources/wechat.dylib`，识别 thin / fat Mach-O。
3. 计算整个文件的 SHA-256；如果存在 x86_64 切片，也单独计算该切片的 SHA-256。
4. 读取 `patches.json`，只按 catalog 判断 build / arch / feature 覆盖情况，不把 arm64 目标误报成 Intel 支持。
5. 输出 JSON，或输出适合粘贴到 issue 的简短中文摘要。

## 用法

默认读取：

- App：`/Applications/WeChat.app`
- 配置：仓库根目录下的 `patches.json`

示例：

```sh
python3 -B Scripts/intel-preflight.py
python3 -B Scripts/intel-preflight.py --summary
python3 -B Scripts/intel-preflight.py --app /Applications/WeChat.app --config patches.json --summary
```

## 输出说明

JSON 输出包含：

- `app`：bundle 标识、版本、构建号、二进制名
- `binary`：Mach-O 类型、whole hash、x86_64 slice hash、各 slice 基本信息
- `catalog`：当前 build 是否命中、目标数量、是否存在 Intel 覆盖
- `host`：本机 Python/平台信息，以及 `swift` / `xcrun` 探针结果
- `limitations`：明确标记这是只读目录预检，不代表补丁已安装或真实 Intel 实机验证通过

摘要输出会明确提示：

- 这是只读预检，不代表补丁已安装；
- 这是目录内静态检查，不代表真实 Intel 实机验证通过；
- 如果 catalog 只覆盖 arm64，摘要不会冒充 Intel 支持；
- 探针命令失败不会中断主流程，只会回到 `status/detail` 字段。

## 限制

- 不执行写入、安装、签名、下载或网络请求。
- 不读取聊天数据库、账号数据或其他敏感运行时信息。
- 不把 bundle 外部的 symlink 目标当成合法的 `wechat.dylib`。
- 不把重复架构、重叠 slice 或 CPU type 不一致的 fat Mach-O 当成正常样本。

## 结果使用建议

这个工具适合在 issue 里提供只读证据：

- 当前安装版本与 build
- x86_64 slice 的 SHA-256
- catalog 命中的 build 和 feature 覆盖
- 本机工具链版本信息

## 测试命令

在仓库根目录执行：

```sh
python3 -B -m unittest Scripts.tests.test_intel_preflight
```

它不能替代：

- 真实 Intel 机器上的运行测试
- 微信内真实 hook 或补丁生效验证
- 生产安装前的人工审查
