# WhereKey

一个 macOS 本地 API 服务与凭证目录：在桌面应用中管理 Key，通过 CLI 交给需要它的程序使用。支持大模型 API、自建服务、图萃 Tucui 和保存的 curl 请求。

Key 与请求秘密保存在 macOS Keychain。WhereKey 不会在你的业务项目中生成 `.env` 或写入凭证配置。

[下载版本](https://github.com/tangge226/whereismykey/releases/latest) · [更新记录](CHANGELOG.md) · [参与贡献](CONTRIBUTING.md) · [安全说明](SECURITY.md)

## 安装

需要 **macOS 14 或更新版本**。发布的 Universal 2 DMG 同时包含 Apple Silicon 与 Intel 架构。

1. 从 [Releases](https://github.com/tangge226/whereismykey/releases) 下载 DMG，将 `WhereKey.app` 拖到“应用程序”，打开应用。
2. 如需 CLI 和 Codex Skill，在 DMG 中运行 `Install CLI & Codex Skill.command`。此安装器会通过 `sudo` 安装应用并创建 `/usr/local/bin/wherekey` 链接，同时把 Skill 安装到 `~/.codex/skills/wherekey`；已有同名 Skill 会先备份。
3. 仅使用桌面管理功能时，可以跳过 CLI 和 Skill 安装。

当前发布产物使用 **ad-hoc 签名**，尚未取得 Developer ID 签名和 Apple 公证。macOS 可能阻止下载后的应用运行；如果系统不允许打开，请使用下方源码构建方式。请勿为了运行本应用关闭系统安全防护。

仓库目前按维护者的公开计划逐步完善；私有仓库的 Release 仅对有访问权限的账号可见。

## 开始使用

### 粘贴添加

点击左侧底部的 **“粘贴添加”**，粘贴网址、接入说明、OpenAPI JSON、Key 笔记或 curl，然后选择 **“识别 → 添加服务”**。批量内容会逐项确认，确认前不会保存候选服务。

- 网址模式读取不带 Cookie 或凭证的公开页面，查找同站开发者说明；不会执行网页脚本、安装命令或示例业务请求。
- 含 Key 的笔记在本机解析。带可识别凭证参数、账号密码或签名的网址不用于公开页面抓取。
- 无法读取动态或登录页面时，可以改为粘贴接入说明正文；也可从粘贴窗口左下角进入 **“手动添加”**。
- 没拿到 Key 或服务地址也可先保存，之后在服务详情中点击 **“补充连接信息”**。需要的配置补齐前，不会验证或注入到目标程序。

例如粘贴 `www.evidoc.cn` 的图萃接入说明，可自动配置 `X-API-Key`、`TUCUI_API_KEY`、`TUCUI_BASE_URL` 及资源验证路径。官网仅是文档来源，实际 API 地址和 Key 仍需由服务提供方提供。

### 服务与项目

应用只有 **“服务”** 和 **“项目”** 两个主页面：左侧选择，右侧查看详情。

- 服务支持多个 Key 别名、默认 Key、用途、标签、文档和可选验证配置；低频设置收在“高级设置”和更多菜单中。
- 项目使用记录由 CLI 自动登记，只读显示调用时的服务与 Key 别名。删除服务后，已有历史记录仍保留。
- 拖动左右区域之间的分隔线调整侧栏宽度；两个页面共用并记住宽度，双击分隔线恢复默认。
- 悬停名称可看完整服务名；项目提示还会显示完整路径。

### 本机访问许可

打开应用、搜索、查看目录和详情只读取元数据，不会批量解锁 Key 或自动检查全部服务。`catalog` 和 `describe` 不读取 Keychain。

需要使用的 Key 无法静默读取时，服务详情显示 **“访问受限”** 和 **“允许访问 Key”**。由用户主动点击后，macOS 才处理当前凭证的系统许可；取消后停止，不自动循环弹窗。“访问受限”与服务端 Key 失效是不同状态。

## CLI

先在应用中添加一个名为 `My API` 的服务，并配置目标程序需要的环境变量名。以下名称和路径均为示例：

```bash
wherekey catalog --json
wherekey describe --service "My API" --json
wherekey run --service "My API" -- python3 app.py
wherekey run --service "My API" --key "test" -- npm test
wherekey check --service "My API" --json
wherekey call --service "Saved request" --json
```

`run` 只向目标进程注入所选 Key 对应的环境变量，并把当前工作目录记录为使用该服务的项目。目标程序能够读取该变量，因此只应向你信任的程序授予 Key。WhereKey 没有显示 Key 明文的 CLI 命令；不要通过 `env`、调试输出或日志导出注入值。

`call` 执行保存的业务 curl，可能产生服务端操作或计费。`check` 返回验证结果；`unchecked` 表示未验证，不表示 Key 失效。鉴权失败、权限不足、限流、网络或断言失败返回非零退出码。

### 连接验证与旧数据

新服务可选择不检查、手动检查或保存后自动检查；验证地址可留空。自动检查仅使用独立 GET / HEAD 请求，不重放业务 curl；“检查全部服务”等批量检查也不会回退执行旧业务 curl。桌面界面的“验证连接”只开放独立验证入口。

**旧 curl 服务的 CLI 兼容行为：** 如果没有独立验证请求，显式执行 `wherekey check` 仍可能执行原业务 curl，包括产生副作用的请求。请先检查和补充独立验证配置；自动和批量检查不会采用此兼容回退。

首次加载旧 v1 元数据时，会先保存 `metadata.v1.backup.json` 再迁移到 v2；服务 ID、Keychain 账户和原 CLI 参数保持兼容。迁移或加载失败时暂停编辑，避免用空数据覆盖原配置。

## 数据与安全边界

- **秘密**：Key、保存的 curl 与独立验证模板放在 macOS Keychain。
- **元数据**：默认保存在 `~/Library/Application Support/WhereKey/metadata.json`，包含服务名称、地址、Key 脱敏信息、项目路径和使用历史。它仍属于可能敏感的本地资料，请勿上传到公开 Issue 或仓库。
- **本机许可**：CLI 和自动读取禁止唤起系统认证窗口；许可由桌面应用中明确的当前项操作触发。
- **网络**：读取公开文档、验证连接或执行调用时会访问相应目标服务；Keychain 存储不等于所有操作都离线。

当前实现尚未接受独立安全审计。安全问题请通过 [SECURITY.md](SECURITY.md) 中的私密报告方式联系维护者。

## 从源码构建

需要 macOS 14+、**Swift 6 工具链**、Apple SDK（Xcode 或适用的 Command Line Tools）及 `python3`。源码以 Swift 5 语言模式编译；`Package.swift` 使用 Swift tools 6.0。

```bash
git clone https://github.com/tangge226/whereismykey.git
cd whereismykey
./Scripts/build-local.sh
open .build/WhereKey.app
```

构建与本地测试：

```bash
./Scripts/test.sh
```

脚本构建与 `./Scripts/test.sh` 可使用适用的 Command Line Tools。测试使用合成凭证、隔离数据和回环地址服务，不需要真实 API Key。

SwiftPM 测试推荐使用完整 Xcode 工具链：

```bash
swift test
```

部分仅安装 Command Line Tools 的环境可能在 SwiftPM manifest 链接阶段失败；脚本测试通过不代表该环境下的 `swift test` 已通过。CI 配置在 GitHub `macos-latest` 上运行 SwiftPM 测试。

创建包含应用、CLI 和安装器的 Universal 2 DMG：

```bash
./Scripts/package.sh
```

产物位于 `dist/WhereKey-<版本>-universal.dmg`，同时生成 `dist/SHA256SUMS`。Release 附有这两个文件；下载到同一目录后可用 `shasum -a 256 -c SHA256SUMS` 检查文件是否一致。构建目录和 DMG 不纳入 Git。

## 贡献与许可证

欢迎提交问题和小范围 PR，提交前请阅读 [贡献指南](CONTRIBUTING.md)。截图、复现步骤和测试数据必须脱敏。

开源许可证正在确认，当前尚未提供 `LICENSE` 文件；公开前需要补齐。最终使用与分发条款以仓库根目录的许可证文件为准。
