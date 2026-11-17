# WhereKey

**让 Codex 等本机工具使用 API Key，减少手动输入和在聊天里传递明文。**

WhereKey 是一个 macOS 本地 API 服务与凭证管理工具。你在桌面应用中保存 Key，让工具通过服务名和 CLI 调用需要的服务。支持大模型 API、自建服务、图萃 Tucui 和保存的 curl 请求。

Key 与请求秘密保存在 macOS Keychain。WhereKey 不会在你的业务项目中生成 `.env` 或写入凭证配置。

[源码安装](#安装) · [更新记录](CHANGELOG.md) · [参与贡献](CONTRIBUTING.md) · [安全说明](SECURITY.md) · [Apache-2.0 许可证](LICENSE)

## 为什么需要 WhereKey

使用 Codex 或能执行本机命令的 AI 办公工具时，经常会遇到“这个服务需要 API Key”。把 Key 明文贴进聊天会增加暴露风险；每次自己在终端、配置文件和不同工具之间重复输入，又容易出错，也不方便管理。

WhereKey 把这件事变成一个本机流程：

1. **你保存 Key**：在 WhereKey 中添加服务和 Key，秘密保存在 Mac 的系统钥匙串（macOS Keychain）中；不需要把真实 Key 发到聊天里。
2. **工具使用服务名**：配合仓库自带的 Codex Skill，Codex 可以查看服务名、Key 别名和调用方式。查看目录和详情不会读取真实 Key。
3. **本机程序使用凭证**：WhereKey 按服务配置向指定子进程注入环境变量，或执行保存的请求。正常使用时，无需手动复制 Key、把它写入命令参数或在每个业务项目中保存一份。

例如，服务配置好后，Codex 可以用下面的命令运行你的程序，命令里只有服务名，没有 Key 明文：

```bash
wherekey run --service "My API" -- python3 app.py
```

**安全保障来自具体机制**：系统钥匙串保管秘密、App 与 CLI 双向校验身份、目录查询不解锁 Key、需要系统许可时由你处理当前凭证。它们减少日常传递和存储凭证的风险；获准运行的目标程序仍能读取注入的 Key，真实 API 调用也需要向目标服务发送鉴权信息。请只运行信任的程序，详细边界见 [安全说明](SECURITY.md)。

## 安装

主要使用方式是：把这个仓库交给自己的 Codex，让它在本机检查环境、从源码构建并安装。**不需要下载 DMG，也不需要配置 Developer ID 证书。** 本地构建会使用 macOS 自带的 ad-hoc 签名，保持 App 与内置 CLI 的身份校验。

需要 **macOS 14+、Git、Swift 6 工具链、Apple SDK（Xcode 或适用的 Command Line Tools）和 `python3`**。源码使用 Swift 5 语言模式。

### 交给 Codex

在自己的 Codex 中打开仓库，或把下面这段话和 [仓库地址](https://github.com/tangge226/whereismykey) 一起交给它：

> 请阅读 README.md 和 AGENTS.md，在我的 Mac 上从源码安装 WhereKey。先检查环境和已有安装，使用 Scripts/test.sh 做合成凭证自测；通过后运行 Scripts/install-local.sh --skip-build --with-codex-skill --open。已有安装请先正常退出并保留配置，App 和 CLI 必须整套更新。请确认 command -v wherekey 指向本次安装；不要读取我的真实 Key、自动检查已有服务、关闭系统安全防护或发布安装包。系统权限窗口由我本人处理。

仓库公开提供源码。在目标 Mac 上使用能够执行本机终端命令的 Codex，按以下流程构建和安装，无需申请仓库访问权限。

### 手动执行同一流程

```bash
git clone https://github.com/tangge226/whereismykey.git
cd whereismykey
./Scripts/test.sh
```

自测通过后再安装：

```bash
./Scripts/install-local.sh --skip-build --with-codex-skill --open
```

默认安装位置：

- App：`~/Applications/WhereKey.app`
- CLI 链接：`~/.local/bin/wherekey`，指向同一 App 内的 CLI。
- 可选 Codex Skill：`$CODEX_HOME/skills/wherekey`，未设置 `CODEX_HOME` 时为 `~/.codex/skills/wherekey`。仅使用桌面应用或普通 CLI 时，可省略 `--with-codex-skill`。

安装器不使用 `sudo`，不读取或改写 Keychain、元数据和已有 Key。它会验证构建产物，备份已有 App、CLI 与选择安装的 Skill，再整套替换；失败时尝试恢复原文件。目标 App 正在运行时会停止安装，请先正常退出。

若 shell 尚未把 `~/.local/bin` 放在 PATH 前面，可在当前终端执行：

```bash
export PATH="$HOME/.local/bin:$PATH"
rehash
command -v wherekey
wherekey --help
```

需要长期生效时，可把 `export PATH=…` 加到自己的 shell 配置。若 `command -v wherekey` 仍指向 `/usr/local/bin` 等旧位置，先处理 PATH 优先级，避免新 App 配旧 CLI。安装器不会擅自覆盖这些其他位置的文件。

### 升级已有安装

先确认 App 和 `command -v wherekey` 的实际位置，再正常退出该 App。拉取源码、通过自测，然后在原位置整套更新。例如当前用户对这两个目录有写权限时：

```bash
./Scripts/install-local.sh --skip-build --app-dir /Applications --bin-dir /usr/local/bin
```

目标文件不属于 WhereKey 时，安装器会拒绝覆盖。原 App、CLI 和可选 Skill 的备份保存在所选应用目录下的 `.WhereKey-backup.*` 私有目录中；需要回退时应同时恢复同一份 App 与 CLI。应用数据仍留在原来的本机位置，Keychain 不会被导出或迁移。

完整选项见 `./Scripts/install-local.sh --help`。默认只安装，`--open` 才会尝试打开应用；如果其他位置的 WhereKey 仍在运行，会提示先退出该实例。

[历史 Releases](https://github.com/tangge226/whereismykey/releases) 中的 DMG 仅是另一种分发记录，不是源码安装的前提。当前尚未完成 Developer ID 签名或 Apple 公证；请勿为运行应用关闭系统安全防护。

## 开始使用

### 让 Codex 使用已保存的服务

安装时选择 `--with-codex-skill`，并在 WhereKey 中配置好服务后，可以把任务和服务名告诉 Codex，例如：

> 请使用 WhereKey 中的“My API”服务运行当前项目，按 wherekey Skill 查看调用方式。通过 WhereKey 使用已保存的凭证，不要让我把 Key 贴到聊天里，也不要输出 Key 或把它写入项目文件。如果配置缺失，请告诉我到 WhereKey 中补充。

Key 只需由你在 WhereKey 中填写。后续换 Key 时在应用中更新；按服务名调用的命令无需包含新的 Key。其他 AI 工具需能够执行本机 CLI，并遵守同样的凭证使用约定；仓库目前提供的是 Codex Skill。

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

App 与 CLI 必须来自同一构建并配套更新。IPC 在传输请求前双向验证运行中程序的代码身份；身份不匹配会直接拒绝连接。旧 Keychain 项的访问规则不会随签名自动升级，相关限制见 [安全说明](SECURITY.md)。

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

本项目采用 [Apache License 2.0](LICENSE)（SPDX：`Apache-2.0`）。版权与归属说明见 [NOTICE](NOTICE)。
