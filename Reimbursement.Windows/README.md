# Reimbursement.Windows

`reimburse-app` 的 Windows 版：医科达售后差旅报销助手（票据识别 → 行程整理 → 检查 → 导出）。
当前版本 **v1.3.2**（.NET 10 + WinUI 3，自包含发布，目标机零前置）。
选型与设计分析见 `docs/windows-port-analysis` 分支的 `docs/windows-port-analysis.md`。

## 结构

```
Reimbursement.Windows.sln
├── Core/          平台无关业务库（net10.0）——macOS Swift 版逻辑的复刻 + toolkit 能力并入
│   ├── Models/    BillType/字段规格/Receipt/BillInfo/TripGroup/manifest（JSON 与 Swift 版兼容）
│   ├── Llm/       OpenAI 兼容客户端、两段式识别管线、Prompt、Provider 预设、DPAPI 加密的设置存储
│   ├── Trips/     TripResolver 行程切分状态机
│   ├── Storage/   SessionManager（ingest/finalize/配对/文件名生成，manifest 为单一事实源）
│   ├── Packaging/ ExcelBuilder、ZipPackager、PdfComposer（整合 PDF）、PdfMerger、Preflight
│   └── Recognition/ 识别管线（提取 → LLM 并发 3 → 回填串行）与文档文本抽象
├── Ocr/           OCR 适配（net10.0，win-x64）：内置 PaddleOCR（PP-OCRv5 mobile，离线）
│                  + PDFtoImage（PDFium）逐页渲染；可选 OXR 云端解析；回退链 文本层→OXR→本地 OCR
├── App/           WinUI 3 桌面壳（net10.0-windows）：Mica 界面、整窗拖放自动识别、设置窗口、
│                  Velopack 自动更新（GitHub Releases）
└── Core.Tests/    xUnit 回归测试（82 个，多由 Swift 测试翻译 + 管线/打包端到端）
```

## 本地开发

前置（缺一不可，都是实测过的硬约束）：

- **Visual Studio 2026**（Community 即可），工作负载勾选「.NET 桌面开发」+「Windows 应用程序开发」。
  不能用 VS2022（.NET 10 SDK 要求 MSBuild ≥ 18），也不能只装独立 .NET SDK 用 `dotnet build`
  （WinUI 的 PRI 打包任务只随 VS 的 MSBuild 提供）。
- VS 的 NuGet 程序包源里要有 **nuget.org**（`https://api.nuget.org/v3/index.json`）并勾选，
  否则还原只查离线包源、所有包报"找不到"。
- .NET 10 SDK ≥ 10.0.100（VS2026 自带；`global.json` 以 rollForward 方式钉住）。

日常流程：

```powershell
git clone https://github.com/glasslessw1n/reimburse-app.git
git checkout feature/windows-app
# 打开 Reimbursement.Windows\Reimbursement.Windows.sln，配置选 Debug | x64，F5 运行
dotnet test Reimbursement.Windows\Core.Tests\Reimbursement.Core.Tests.csproj   # 只跑逻辑测试
```

常见坑：

- 打开解决方案报"找不到指定的 SDK Microsoft.NET.Sdk"：多半是装完 SDK 后 VS 没重启（解析缓存），完全退出 VS 再开。
- `git pull` 拉到 XAML 大改后出现一半旧一半新的假错（如旧事件处理器缺失、ListBox/ListView 互转失败）：
  是 `obj` 里残留的旧 XAML 生成代码，删掉各工程的 `obj`、`bin` 重开 VS 即可。
- 还原报 NU1004（锁文件不一致）：删掉对应工程的 `packages.lock.json` 再还原。

## 发布

- **版本号唯一出处**：`App/Reimbursement.App.csproj` 的 `<Version>` + `App/app.manifest` 的
  assemblyIdentity（两者同步改）；Core/Ocr 的 `<Version>` 跟随。标题栏版本读程序集版本。
- **本地发布版**：VS 切 Release | x64 生成 App 工程，产物在
  `App\bin\x64\Release\net10.0-windows10.0.19041.0\win-x64\`，整文件夹即发布版（可压 zip 分发）。
  命令行等价：`msbuild Reimbursement.Windows\App\Reimbursement.App.csproj -restore -p:Configuration=Release -p:Platform=x64`。
- ⚠️ **不要用** VS「发布」向导或 `msbuild -t:Publish`：会漏掉 `Reimbursement.App.pri` 导致启动闪退（实测）。
- **正式发版（带 Setup 安装包 + 自动更新）**：在 `feature/windows-app` 打标签 `windows-v<版本>` 并推送，
  CI 自动出 GitHub Release（zip + Velopack Setup.exe 与增量更新源）。已安装的旧版启动时静默检查更新。
- 构建后会自动清理输出目录里多余的语种 MUI 文件夹（只留 zh-CN/en-US，见 App 工程的
  `TrimUnusedMuiLanguages` 目标）。

## 数据落点

`%APPDATA%\Reimbursement.Windows\`：`sessions\`（每会话 manifest.json + 原件/行程）、
`settings.env`（API Key 经 DPAPI 加密）、`logs\`（按天诊断日志）、`ui-state.json`（窗口位置/使用说明已读）。

## 分支图

| 分支 | 状态 | 说明 |
|---|---|---|
| `main` | 保留 | macOS Swift 原版，Windows 工作不动它 |
| `feature/windows-app` | **主线（开发在这里）** | 当前 v1.3.2；本地开发与发版都从这条走 |
| `feature/windows-ux-v2` | 与主线内容一致 | UX v2 时期的载体，已并入主线，保留作对照 |
| `feature/windows-net10` | 与主线内容一致 | .NET 10 升级验证分支，已转正并入主线，保留作对照 |
| `feature/windows-core` | 历史，可删 | 一期 Core 移植，内容已全部并入主线 |
| `feature/windows-toolkit-merge` | 历史，可删 | toolkit 并入，内容已全部并入主线 |
| `docs/windows-port-analysis` | 历史，可删 | 移植分析文档分支 |

CI（`.github/workflows/windows.yml`）在上述 feature 分支推送时触发：Core 测试（dotnet test）
+ WinUI 构建（windows-latest / VS2026 的 MSBuild）两个 job。仓库内
`Reimbursement.Windows/ci/windows.yml` 是该工作流的暂存副本，与线上保持一致
（历史原因：自动化推送无 `.github/workflows` 写权限时由此中转；本地 Git 推送不受此限）。

## 沿革与关键决策（细节备查）

- **toolkit 并入**：PdfComposer（整合 PDF，矢量贴页）修复了 Python 版三处缺陷——多页文档只取
  第 0 页、未上行程证明页的登机牌整张消失、其他类票据被丢弃；另有 PdfMerger（合并 PDF）与
  Preflight（提交前检查：缺发票/水单配对、金额缺失、未见返程等）。
- **滴滴发票裁版**：滴滴发票本体只占 A4 上半页，按整页贴图会被空白拖小；`PageContentBox`
  （PdfPig 算内容边框，注意 MediaBox/CropBox 坐标换算）先裁内容再排版。
- **OCR**：内置 PaddleOCR CPU/MKLDNN 为默认（用户机为 Intel 核显，无 CUDA 路线，GPU 方案搁置）；
  OXR 仅作可选云端增强（会上传原件，设置里有明示）。
- **与 Swift 版的有意差异**：JSON 提取用字符串感知的括号匹配；文件名清洗额外处理 Windows
  非法字符；ZIP/XLSX 进程内生成。其余业务规则按 Swift 版复刻并由翻译测试锁定。
- **MCP 工具层**：二期设想，未立项。
