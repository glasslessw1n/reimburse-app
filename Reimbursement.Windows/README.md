# Reimbursement.Windows

`reimburse-app` 的 Windows 版（.NET 8）。设计与选型见仓库根目录上层的分析文档
`docs/windows-port-analysis.md`（在 `docs/windows-port-analysis` 分支）。

## 结构

```
Reimbursement.Windows.sln
├── Core/          平台无关逻辑库（net8.0）——macOS Swift 版逻辑的 1:1 复刻
│   ├── Models/    BillType/字段规格/Receipt/BillInfo/TripGroup/manifest（JSON 与 Swift 版逐字兼容）
│   ├── Llm/       OpenAI 兼容客户端、两段式识别、Prompt 生成、Provider 预设、.env 设置
│   ├── Trips/     TripResolver 行程切分状态机
│   ├── Storage/   SessionManager（ingest/finalize/配对/字母序号/文件名生成）与会话目录
│   └── Packaging/ ExcelBuilder（手写 OOXML）、ZipPackager（进程内打包）
└── Core.Tests/    xUnit 回归测试——大多由 Swift 测试逐条翻译（TripResolver 决策矩阵等），外加 LLM 编排与端到端冒烟
```

后续（各自独立分支）：WinUI 3 桌面壳（`feature/windows-app`）、OCR 引擎选型 spike
（`feature/windows-ocr-spike`）、toolkit 排版融入（`feature/windows-toolkit-merge`）、MCP 服务（二期）。

## 构建与测试

```powershell
dotnet build Reimbursement.Windows.sln
dotnet test  Reimbursement.Windows.sln
```

Core 与 Core.Tests 均为纯 net8.0，可在 Windows / macOS / Linux 上构建运行；
只有将来的 WinUI 壳需要 Windows。

## 数据落盘（与 mac 版同构）

- 配置：`%APPDATA%\Reimbursement\.env`（键名与 mac 版一致，互通）
- 会话：`%APPDATA%\Reimbursement\sessions\{sid}\{manifest.json, originals\, trips\}`
- 打包输出：用户 Downloads 目录（经 Known Folder API 获取，不写死路径）

## 与 Swift 版的行为差异（有意为之，详见分析报告 §7）

- JSON 提取改用字符串感知的括号匹配状态机（Swift 版括号计数不感知字符串内容，字符串里的 `}` 会截错）。
- 原文件名清洗在 mac 版只防 `/` 的基础上，额外处理 Windows 非法字符 `\ < > : " | ? *`、控制字符与尾随点/空格。
- ZIP/XLSX 全部进程内生成（替代 mac 的 ditto / /usr/bin/zip 外部进程）。
- 其余业务规则（TripResolver、酒店配对、滴滴链接、buildFilename、Excel 防双计等）按 Swift 版逐条复刻，并由翻译过来的测试锁定。
