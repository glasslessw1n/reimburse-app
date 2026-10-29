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

## toolkit 融入（feature/windows-toolkit-merge 分支新增）

reimburse-toolkit（Python）的核心能力已以 Core 服务形态并入，数据源从"文件名/目录解析"
换成 app 的会话识别记录（manifest），并修复 toolkit 的已知缺陷：

- **PdfComposer**（compose.py 的现代化形态）：「整合 PDF」导出。排版规则与 toolkit
  一致（A4、边距 20pt、间距 8pt；行程证明页 P1 去+回上下排、交通 3×2、酒店水单整页、
  酒店发票同页两份、滴滴/餐饮/自驾票据左旋 90° 网格）。实现改为 **矢量贴页**
  （PDFsharp XPdfForm，文字保持清晰；图片原件按同样 fit 规则贴图）。返回贴页清单
  （每页放了哪份票据的哪一页、什么规则、什么框）供 UI 预览。修复：①多页文档逐页纳入
  （toolkit 只渲染第 0 页）②未上 P1 的登机牌进 3×2（toolkit 会整张消失）
  ③其他类票据走 1×2 兜底排版（toolkit 直接丢弃）。
- **PdfMerger**（merge.py）：「简单合并 PDF」——按行程顺序逐页矢量合并原件，
  并补上 merge.py 漏掉的自驾行程单/加油/通行费。非 PDF 原件记入 Skipped。
- **Preflight**（诊断套件的现代化形态）：「提交前检查」——识别失败/需复核、金额缺失、
  水单缺发票、发票缺水单、滴滴单票缺边、行程未见返程、原文件缺失；以金额+类型交叉
  校验，比 toolkit 只比文件名字母的配对检查更强。
- 依赖新增 PDFsharp 6.2（MIT，进程内处理，无外部进程）。

MCP 工具层（reimburse_mcp.py 的对应物）按规划放到二期。

## 与 Swift 版的行为差异（有意为之，详见分析报告 §7）

- JSON 提取改用字符串感知的括号匹配状态机（Swift 版括号计数不感知字符串内容，字符串里的 `}` 会截错）。
- 原文件名清洗在 mac 版只防 `/` 的基础上，额外处理 Windows 非法字符 `\ < > : " | ? *`、控制字符与尾随点/空格。
- ZIP/XLSX 全部进程内生成（替代 mac 的 ditto / /usr/bin/zip 外部进程）。
- 其余业务规则（TripResolver、酒店配对、滴滴链接、buildFilename、Excel 防双计等）按 Swift 版逐条复刻，并由翻译过来的测试锁定。

## UX v2（feature/windows-ux-v2 分支）

针对 v1 实测反馈的六个问题重做：

- **OCR 接入**：新增 `Ocr/` 适配器工程（net8.0，win-x64）。默认内置
  **PaddleOCR**（Sdcb.PaddleOCR 3.3.1 + PP-OCRv5 中文 mobile 模型，随应用离线分发）；
  PDF 文本层不足时用 PDFtoImage（PDFium）以 300 DPI 逐页渲染后 OCR，图片票据直接 OCR；
  OCR 文本块经 `OcrTextFormatter` 按阅读顺序拼装后送 LLM。设置里可切换为
  **OXR 云端解析**（SoMark，优先云端、失败回退本地 OCR）或关闭 OCR（仅文本层）。
  Core 侧抽象为 `IDocumentTextProvider / IImageOcrEngine / IPdfPageRenderer`，可单测、可替换。
- **拖放自动识别**：拖放区常驻；拖入或选择文件后自动导入并立即识别；
  没有选中会话时自动新建。原「识别待处理」降为补处理/重试入口。
- **设置页**：模型改为可编辑下拉，支持「拉取模型」与「测试连接」
  （先拉列表验证地址/Key，再用当前模型发最小对话验证可用性），验证状态持久化，
  改动地址/模型/Key 后自动回到未验证。
- **进度与汇总**：识别管线（Core `RecognitionPipeline`）逐张汇报进度事件
  （总数/完成数/当前文件/阶段），UI 显示进度条与取消按钮；结束后弹出汇总横幅
  （成功/失败/需复核计数），失败时横幅可一键重试失败项，否则一键进入整理。
- **界面**：步骤指示（导入→识别→整理检查→导出）、富状态票据行
  （类型+金额+状态标签+失败/复核原因，单张重试/删除）、品牌橙拖放区、
  诊断日志折叠收纳。票据行数据以 `manifest.bills` 为权威列表
  （修复 v1 finalize 前列表为空的问题）。
- 数据落点以 App `Workflow.cs` 为准：`%APPDATA%\Reimbursement.Windows\`
  （`sessions/` + `settings.env`），README 旧版路径描述已过时。
