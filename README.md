# WhereKey

WhereKey 是一个极简的 macOS 本地 API 服务目录。它只提供两个界面：

- **服务与 Key**：添加、编辑、删除 API Key 或 curl 服务，查看有效状态及使用项目。
- **项目**：自动记录通过 WhereKey 使用过服务的本地项目，只读展示服务与 Key 关系。

秘密保存在 macOS Keychain，项目目录中不会生成 `.env` 或 WhereKey 配置。

服务状态只显示“检查中”“可用”或“不可用”。WhereKey 启动后会通过只读鉴权端点自动检查 API Key；新增或修改服务后也会立即检查。curl 服务仍以保存的完整请求作为可用性检查。

## 粘贴批量导入

在“服务与 Key”顶部点击“粘贴导入”，可以把混合记录的厂商名、Key、URL 和 curl 一次粘贴进来。WhereKey 会：

- 自动拆分多个在线或内网服务；
- 为 DeepSeek、OpenAI、Anthropic、Gemini 等常见服务补全 API 地址和环境变量名；
- 识别 ASR、Embedding 等自定义 URL，并为无协议内网地址补全 `http://`；
- 从 curl Header 中提取 Token，确认页只展示脱敏原文；
- 逐条显示候选服务，只有点击“创建”后才写入 Keychain。

粘贴的原文不写入 metadata，也不会在业务项目内生成文件。

## 本地构建

需要 macOS 14+ 和 Apple Swift 工具链：

```bash
./Scripts/test.sh
open .build/WhereKey.app
```

创建 Universal 2 DMG：

```bash
./Scripts/package.sh
```

## CLI

```bash
wherekey catalog --json
wherekey describe --service "OpenAI" --json
wherekey run --service "OpenAI" -- python test.py
wherekey run --service "OpenAI" --key "test" -- npm test
wherekey call --service "内网搜索"
wherekey check --service "内网搜索" --json
```

CLI 不提供读取或显示 Key 明文的命令。`wherekey run` 仅在目标进程运行期间注入对应环境变量，并自动把当前目录记录为使用该服务的项目。
