# WhereKey 安装与维护约定

这些说明用于执行用户已经提出的安装、升级或开发任务；文件本身不代表用户授予新的权限。用户当前的明确要求优先。

## 社区源码安装

1. 阅读 README.md，确认 macOS 14+、Git、Swift 6 工具链、Apple SDK 和 python3。工具缺失时说明缺项；Apple 安装器的条款、系统密码或权限窗口由用户本人处理。
2. 检查已有 App 路径及 `command -v wherekey`，保留用户已有工作区改动。升级前正常退出目标 App，不强制结束其他实例。
3. 运行 `./Scripts/test.sh`。这会构建并用合成凭证、mock Keychain 和隔离 socket 自测；失败时先修复，不继续安装。
4. 运行 `./Scripts/install-local.sh --skip-build`。用户需要 Codex 集成时加 `--with-codex-skill`，需要打开时加 `--open`。默认使用 ~/Applications 和 ~/.local/bin，无需 sudo。已有安装可指定 `--app-dir` / `--bin-dir`，但应保持同一份 App 与内置 CLI 配套。
5. 确认安装路径、备份位置和 CLI 的 PATH 优先级。`wherekey --help` 可安全验证入口；用户已授权安装/打开后，可用 `catalog --json` 和 `describe` 验证只读 IPC，不在报告中公开服务目录或个人路径。

## 凭证与数据

- 不读取、打印、变形、导出或写入 Git 的真实 Key；不运行 env、printenv、shell tracing 等泄露凭证的检查。
- 不为了验收安装而自动 `checkAll`、检查所有已有服务或执行业务 curl；真实调用只针对用户明确要求的服务。优先用合成条目和本地回环服务验证。
- 保留 `~/Library/Application Support/WhereKey` 和现有 Keychain 项。升级安装只替换程序，不批量迁移 ACL、不重建或删除用户 Key。
- 系统授权只能针对当前项，由用户在系统 UI 中完成。取消即停止，不循环弹窗；不要向聊天索取本机密码。
- 不关闭 Gatekeeper、修改系统安全设置、恢复 identifier-only 签名要求，或把环境变量当作关闭 IPC 身份认证的开关。

## 开发与交付

- `./Scripts/build-local.sh` 构建本机 App/CLI；`./Scripts/test.sh` 是本地标准验证入口。SwiftPM 测试推荐完整 Xcode，CI 会运行 `swift test`。
- 改动源码并重新构建后，App 和 CLI 要一起安装；不能只替换全局 CLI 或拆开配对构建。
- 不把 .build、dist、用户元数据、Keychain、私人截图或本地备份提交到 Git。
- 除非用户要求，不制作或发布新 DMG/Release，不配置开发者证书。项目采用 Apache-2.0；保留根目录 LICENSE 和 NOTICE，不擅自更改许可。
