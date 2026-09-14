# 报销整理 · Native

> macOS 原生 SwiftUI 应用。把发票 PDF / 图片拖进来，OCR + LLM 自动识别票据类型、抽取关键字段、按行程归档，一键打包 ZIP 提交财务。

| | |
|---|---|
| **当前版本** | v0.1.0 |
| **平台** | macOS 14 Sonoma+（Apple Silicon / Intel） |
| **技术栈** | Swift 5.9 + SwiftUI + Apple Vision + PDFKit + URLSession |
| **依赖** | Xcode 14+（含 xcodebuild） / [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

---

## ✨ 主要功能

- **多 Provider LLM**：DeepSeek / OpenAI / 月之暗面 / 智谱 / Ollama / vLLM / 自定义
- **零依赖 OCR**：Apple Vision（中文 + 英文，on-device，识别准确率高）
- **PDF 处理**：PDFKit 优先取文字层，无文字层自动渲染图片 + OCR
- **16 种票据类型**：火车票、机票行程单、登机牌、酒店水单/发票、VAT 普票/专票、滴滴行程/发票、餐饮、通信、加油、通行费等
- **智能归类**：按日期 + 城市连通性自动合并差旅行程
- **酒店水单/发票自动配对**：金额完全匹配时合并为一条住宿发票
- **ZIP 打包**：保存到 `~/Downloads/`，自动跳过空目录
- **Excel 明细生成**：手写 xlsx（zip + OOXML，无第三方依赖），按行程分组，5 列结构（票据类别 / 日期/区间 / 金额 / 明细 / 备注），含小计和总计

---

## 📦 项目结构

```
报销整理Native/
├── README.md
├── project.yml                       # XcodeGen 配置
│
├── BuildScripts/
│   └── build_native.sh                # 一键 Release + 签名 + dmg
│
├── BuildAssets/                       # 图标源
│   ├── AppIcon.icns
│   ├── AppIcon.iconset/               # 多尺寸源
│   ├── icon.png
│   ├── icon.svg
│   ├── icon_128.png
│   └── icon_64.png
│
├── ReimbursementNative.xcodeproj/     # XcodeGen 生成的工程
│
└── Sources/
    ├── App/                          # @main + 全局状态
    │   ├── ReimbursementNativeApp.swift
    │   ├── ContentView.swift
    │   └── AppState.swift
    │
    ├── Models/                       # 数据模型（Codable）
    │   ├── BillType.swift             # 16 种票据类型枚举
    │   ├── BillTypeFields.swift       # 每种票据的字段清单（required/optional/sortable/fileNamePart）
    │   ├── Receipt.swift              # LLM 输出的标准结构
    │   └── AnyJSONValue.swift         # LLM JSON 字段值归一化
    │
    ├── Services/                      # 业务逻辑
    │   ├── OCR/
    │   │   ├── OCRService.swift       # Vision VNRecognizeTextRequest
    │   │   ├── PDFRenderer.swift      # PDFKit 文字层 + 渲染
    │   │   └── TextExtractor.swift    # bytes → text 主入口
    │   ├── LLM/
    │   │   ├── LLMClient.swift        # URLSession OpenAI 兼容协议
    │   │   ├── LLMPrompts.swift       # 自动生成字段说明
    │   │   └── LLMRecognizer.swift    # OCR + LLM → Receipt
    │   ├── Storage/
    │   │   ├── SessionManager.swift   # session 生命周期 + 文件落地
    │   │   ├── SessionManifest.swift  # Codable 模型
    │   │   └── TripResolver.swift     # 行程分组算法
    │   ├── Packaging/
    │   │   └── ZipPackager.swift      # ditto 打包（自动跳空目录）
    │   └── Settings/
    │       ├── LLMSettingsStore.swift # .env 读写
    │       └── LLMProvider.swift      # Provider 预设（DeepSeek/OpenAI/...）
    │
    └── Views/                         # SwiftUI 视图
        ├── Home/
        │   └── HomeView.swift          # 首页：左标题 + 右操作指引
        ├── Workspace/
        │   ├── WorkspaceView.swift     # 容器 + 步骤指示
        │   ├── UploadStep.swift        # 上传 + 识别（拖放区 + 实时结果列表）
        │   ├── FinalizeStep.swift      # 行程卡片列表
        │   └── PackageStep.swift       # 打包 + 路径显示
        ├── Settings/
        │   └── SettingsView.swift      # LLM 设置面板
        └── Components/
            ├── DropZone.swift          # 拖拽区
            ├── ProgressBar.swift       # 进度条
            ├── BillRow.swift           # 单条票据行（可展开）
            ├── StatusBadges.swift      # OCR / LLM 状态徽章
            └── PopUpButton.swift       # macOS 原生 NSPopUpButton 包装
```

---

## 🚀 构建

### 前置

```bash
# Xcode 14+（含 xcodebuild）
xcodebuild -version

# XcodeGen（生成 .xcodeproj）
brew install xcodegen    # 或: aqua:yonaskolb/XcodeGen
```

### 一次性生成工程

```bash
cd /Users/lihaidi/Downloads/Dev/报销整理Native
xcodegen generate           # 生成 ReimbursementNative.xcodeproj
```

### 在 Xcode 中开发

```bash
open ReimbursementNative.xcodeproj
# ⌘R 跑起来
```

### 命令行构建

```bash
# Debug（开发用）
xcodebuild -project ReimbursementNative.xcodeproj \
           -scheme ReimbursementNative \
           -configuration Debug \
           -destination 'platform=macOS' \
           build

# Release + dmg（打包用）
bash BuildScripts/build_native.sh
# 产物：
#   BuildAssets/temp_build/Build/Products/Release/报销整理.app
#   报销整理.dmg
```

---

## ⚙️ 配置 LLM

首次启动 → 顶部 `LLM —` 灰色徽章 → 点它打开设置面板。

| Provider | Base URL | 默认 Model |
|---|---|---|
| **DeepSeek**（推荐） | `https://api.deepseek.com/v1` | `deepseek-chat` |
| **OpenAI** | `https://api.openai.com/v1` | `gpt-4o-mini` |
| **月之暗面** | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| **智谱** | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` |
| **Ollama**（本地） | `http://localhost:11434/v1` | `qwen2.5:14b` |
| **vLLM**（自部署） | `http://localhost:8000/v1` | `meta-llama/...` |
| **自定义** | (留空让你填) | (留空) |

点 `测试连接` 验证 → 点 `保存` 写入 `~/Library/Application Support/Reimbursement/.env`。

---

## 📋 使用流程

1. **首页** → 点 `开始整理 →`
2. **拖文件** 到上传框（支持 PDF / JPG / PNG / WEBP，多文件并行处理）
3. **识别结果** 在拖放区下方实时显示，点行展开看 OCR 原文 + LLM 抽取字段
4. 点 `下一步：整理 →`，系统按日期 + 城市连通性合并差旅行程
5. 检查每张卡的金额、行程归属；如有异常回 `补传`
6. 点 `保存到下载目录 →`，ZIP 落到 `~/Downloads/`，可一键 Finder 中打开

ZIP 结构：

```
报销单据_<sid>_<时间>.zip
├── <MMDD-MMDD 城市>/
│   ├── <MMDD-MMDD 城市住宿水单.pdf>
│   ├── <MMDD-MMDD 城市住宿发票.pdf>
│   ├── <MMDD 航班号 起点-终点 金额.pdf>
│   └── ...
└── manifest.json
```

---

## 🔄 与原 Python 项目的对应

| Python（`/Users/lihaidi/Downloads/Dev/报销整合工具LLM/`） | Swift（`Sources/`） |
|---|---|
| `core/receipt_schema.py:BillType` | `Models/BillType.swift` |
| `core/receipt_schema.py:RECEIPT_TYPE_FIELDS` | `Models/BillTypeFields.swift` |
| `core/ocr.py:extract_text_from_bytes` | `Services/OCR/TextExtractor.swift` |
| `core/llm_client.py:call_llm_json` | `Services/LLM/LLMClient.swift` |
| `core/llm_prompts.py:_build_field_spec` | `Services/LLM/LLMPrompts.swift`（自动生成） |
| `core/llm_recognizer.py:recognize` | `Services/LLM/LLMRecognizer.swift` |
| `core/trip_resolver.py:assign_trip` | `Services/Storage/TripResolver.swift` |
| `core/collector.py:finalize_session` | `Services/Storage/SessionManager.swift:finalize()` |
| `core/collector.py:_build_filename` | `Services/Storage/SessionManager.swift:buildFilename(for:)` |
| `core/settings.py`（.env 解析） | `Services/Settings/LLMSettingsStore.swift` |
| `core/packager.py:package_to_file` | `Services/Packaging/ZipPackager.swift` |
| `app.py`（FastAPI） | **删除**（函数式调用替代 HTTP） |
| `web/index.html` | `Views/`（SwiftUI 重新实现，保留视觉风格） |

---

## ✅ v0.1.0 已完成

- [x] **M1** 项目骨架（XcodeGen + SwiftUI App）
- [x] **M2** 数据模型（BillType + BillTypeFields + Receipt + AnyJSONValue）
- [x] **M3** OCR 服务（Vision + PDFKit）
- [x] **M4** LLM 客户端（OpenAI 兼容协议 + 自动 prompt 生成 + 重试）
- [x] **M5** 存储 + 行程归类 + 酒店水单/发票金额匹配
- [x] **M6** UI 骨架 + 设置面板（Provider 预设 + 模型下拉）
- [x] **M7** 上传 + 实时识别列表（自适应滚动条 + 进度面板）
- [x] **M8** 行程卡片 + 打包（ditto 自动跳空目录）
- [x] **M9** Release 打包 + ad-hoc 签名 + dmg

---

## 🚧 已知限制 / 后续计划

- **报销系统填报**（Playwright 那部分）—— Swift 没有原生等价物，**v0.2.0 规划**，可选 WKWebView + JS 注入 或外接脚本桥
- **后处理兜底**（Python 几个启发式如 boarding_pass 检测、hotel 日期偏移等）—— **v0.3.0 规划**，按用户实测 case 增量加
- **macOS Gatekeeper**：dmg 是 ad-hoc 签名，首次启动需右键 → 打开 → 信任
- **OCR Sendable warning**：3 个 Vision framework 非 Sendable warning，不影响功能

---

## 📂 数据落地

```
~/Library/Application Support/Reimbursement/
├── .env                          # LLM 配置
└── sessions/
    └── {sid}/
        ├── manifest.json
        ├── originals/             # 原文件
        └── trips/                # finalize 后分组
```

下载目录：`~/Downloads/报销单据_<sid>_<时间>.zip`

---

## 📝 License

MIT
