using System.Globalization;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Packaging;
using Reimbursement.Core.Recognition;
using Reimbursement.Core.Storage;
using Reimbursement.Ocr;

namespace Reimbursement.App;

/// <summary>
/// 壳与 Core 之间的编排层（无 UI 依赖）：数据目录、设置、会话操作、识别管线、导出。
/// 数据落点 %APPDATA%\Reimbursement.Windows（sessions/ + settings.env），与 Core 的约定一致。
/// </summary>
public sealed class Workflow
{
    public string DataDir { get; }
    public string SessionsRoot { get; }
    public string SettingsPath { get; }

    // OCR 引擎单例（懒加载，首次遇到扫描件/图片才初始化模型）
    private readonly PaddleOcrEngine _paddle = new();
    private readonly PdfToImageRenderer _pdfRenderer = new();

    public Workflow()
    {
        DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Reimbursement.Windows");
        SessionsRoot = Path.Combine(DataDir, "sessions");
        SettingsPath = Path.Combine(DataDir, "settings.env");
        Directory.CreateDirectory(SessionsRoot);
        Core.Diagnostics.AppLog.Configure(Path.Combine(DataDir, "logs"));
    }

    // MARK: 设置

    public LlmSettings LoadSettings() => LlmSettingsStore.Load(SettingsPath);

    public void SaveSettings(LlmSettings settings)
    {
        var store = new LlmSettingsStore(SettingsPath);
        store.Settings.ApiKey = settings.ApiKey;
        store.Settings.BaseUrl = settings.BaseUrl;
        store.Settings.Model = settings.Model;
        store.Settings.TimeoutSeconds = settings.TimeoutSeconds;
        store.Settings.BuyerName = settings.BuyerName;
        store.Settings.BuyerTaxNo = settings.BuyerTaxNo;
        store.Settings.ExcludeCities = settings.ExcludeCities;
        store.Settings.OcrEngine = settings.OcrEngine;
        store.Settings.OxrBaseUrl = settings.OxrBaseUrl;
        store.Settings.OxrApiKey = settings.OxrApiKey;
        store.Settings.LlmVerified = settings.LlmVerified;
        store.Save();
    }

    // MARK: 会话

    public List<SessionSummary> ListSessions() => Sessions.List(SessionsRoot);

    public SessionManager CreateSession() => new(SessionsRoot, Sessions.CreateNewSid());

    public SessionManager OpenSession(string sid)
    {
        var session = new SessionManager(SessionsRoot, sid);
        // 旧版清单迁移：无 finalized 标记但已有行程分组的，视为已整理——
        // 用当前设置的常驻地播种 HomeCities 并落盘，之后单张删除/替换会整体重新派生，
        // 不再信任盘上的三份副本（评估 S2 的迁移路径，只跑一次）。
        var m = session.Manifest;
        if (!m.Finalized && (m.Trips.Count > 0 || m.Local.Count > 0))
        {
            m.Finalized = true;
            if (m.HomeCities.Count == 0)
                m.HomeCities = LoadSettings().ExcludeCities;
            session.Save();
        }
        return session;
    }

    /// <summary>删除一个会话（整目录删除，不可恢复；调用方负责确认与当前会话切换）。</summary>
    public void DeleteSession(string sid)
    {
        if (sid.Length == 0 || sid.Contains('/') || sid.Contains('\\') || sid.Contains("..")) return;
        var dir = Path.Combine(SessionsRoot, sid);
        if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true);
    }

    /// <summary>清空全部会话。</summary>
    public void ClearAllSessions() => Sessions.ClearAll(SessionsRoot);

    /// <summary>会话内全部票据（manifest.bills 是权威列表：finalize 前是识别登记，finalize 后与 trips+local 同步）。</summary>
    public static List<BillInfo> AllBills(SessionManager session) =>
        session.Manifest.Bills.ToList();

    /// <summary>已导入 originals 但还没有识别记录的文件（待识别队列）。</summary>
    public List<string> PendingFiles(SessionManager session)
    {
        var known = AllBills(session).Select(b => b.SourceFile)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var originals = Path.Combine(session.RootDir, "originals");
        if (!Directory.Exists(originals)) return new List<string>();
        return Directory.EnumerateFiles(originals)
            .Select(p => Path.GetFileName(p))
            .Where(n => !string.IsNullOrEmpty(n) && !known.Contains(n!))
            .Select(n => n!)
            .OrderBy(n => n, StringComparer.Ordinal)
            .ToList();
    }

    /// <summary>导入一个文件到会话 originals，返回落盘文件名（同名自动 -2/-3）。</summary>
    public string ImportFile(SessionManager session, string path) =>
        Path.GetFileName(session.SaveOriginal(File.ReadAllBytes(path), Path.GetFileName(path)));

    /// <summary>删除某个源文件的全部旧识别记录（单张重试前调用，避免新旧结果并存）。</summary>
    public void RemoveBillsForSource(SessionManager session, string sourceFile)
    {
        foreach (var bill in AllBills(session)
                     .Where(b => string.Equals(b.SourceFile, sourceFile, StringComparison.OrdinalIgnoreCase))
                     .ToList())
            session.RemoveBill(bill.Uid);
    }

    // MARK: 识别管线

    /// <summary>按设置组装文档文本管线：paddle=内置离线 OCR；oxr=外部解析优先、本地 OCR 兜底；none=仅文本层。</summary>
    public DocumentTextExtractor BuildTextProvider(LlmSettings settings)
    {
        var oxr = new OxrDocumentParser(new OxrOptions(settings.OxrBaseUrl, settings.OxrApiKey));
        return settings.OcrEngine switch
        {
            "oxr" => new DocumentTextExtractor(_paddle, _pdfRenderer, oxr, preferExternal: true),
            "none" => new DocumentTextExtractor(),
            _ => new DocumentTextExtractor(_paddle, _pdfRenderer),
        };
    }

    /// <summary>
    /// 对指定文件跑识别管线（带进度与汇总）。重跑已识别文件时先清掉旧记录，避免新旧并存。
    /// </summary>
    public async Task<RecognitionSummary> RunRecognitionAsync(
        SessionManager session, LlmSettings settings, IReadOnlyList<string> fileNames,
        IProgress<RecognitionProgress>? progress = null, CancellationToken ct = default)
    {
        foreach (var name in fileNames) RemoveBillsForSource(session, name);
        var pipeline = new RecognitionPipeline(
            BuildTextProvider(settings),
            new LlmRecognizer(new LlmClient(settings.ToConfig())));
        return await pipeline.RunAsync(
            fileNames,
            name => Path.Combine(session.RootDir, "originals", name),
            bill => session.Ingest(bill),
            progress, ct);
    }

    /// <summary>识别全部待处理文件。</summary>
    public Task<RecognitionSummary> RecognizePendingAsync(
        SessionManager session, LlmSettings settings,
        IProgress<RecognitionProgress>? progress = null, CancellationToken ct = default) =>
        RunRecognitionAsync(session, settings, PendingFiles(session), progress, ct);

    // MARK: LLM 验证

    /// <summary>拉取模型列表（设置页下拉用）。</summary>
    public async Task<List<string>> FetchModelsAsync(LlmSettings settings, CancellationToken ct = default) =>
        await new LlmClient(settings.ToConfig()).ListModelsAsync(ct);

    public sealed record LlmTestResult(bool Ok, string Message, IReadOnlyList<string> Models);

    /// <summary>
    /// 测试连接：先拉模型列表（验证地址与 Key），再用当前模型发一条最小对话（验证模型可用）。
    /// </summary>
    public async Task<LlmTestResult> TestLlmAsync(LlmSettings settings, CancellationToken ct = default)
    {
        if (settings.ApiKey.Length == 0)
            return new LlmTestResult(false, "未填写 API Key", Array.Empty<string>());
        var client = new LlmClient(settings.ToConfig());
        List<string> models;
        try
        {
            models = await client.ListModelsAsync(ct);
        }
        catch (Exception ex)
        {
            return new LlmTestResult(false, $"拉取模型列表失败：{ex.Message}", Array.Empty<string>());
        }
        try
        {
            await client.ChatAsync("你是连接测试助手。", "请只回复 OK", useJSONFormat: false, ct: ct);
        }
        catch (Exception ex)
        {
            return new LlmTestResult(false,
                $"模型列表可达（{models.Count} 个），但模型「{settings.Model}」调用失败：{ex.Message}", models);
        }
        var inList = models.Count == 0 || models.Contains(settings.Model);
        return new LlmTestResult(true,
            inList ? $"连接成功：共 {models.Count} 个模型，当前模型可用"
                   : $"连接成功，但模型列表里没有「{settings.Model}」，请确认模型名",
            models);
    }

    // MARK: 导出

    public string ExportsDir(SessionManager session)
    {
        var dir = Path.Combine(session.RootDir, "exports");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public string ExportExcel(SessionManager session, IReadOnlySet<string> homeCities)
    {
        var path = Path.Combine(ExportsDir(session), "报销明细.xlsx");
        ExcelBuilder.SaveTo(path, AllBills(session), homeCities);
        return path;
    }

    public ComposeResult ExportComposed(SessionManager session) =>
        PdfComposer.Compose(session, Path.Combine(ExportsDir(session), PdfComposer.SuggestFileName(session)));

    public MergeResult ExportMerged(SessionManager session) =>
        PdfMerger.Merge(session, Path.Combine(ExportsDir(session), "报销单合并.pdf"));

    public string ExportZip(SessionManager session, IReadOnlySet<string> homeCities)
    {
        var bills = AllBills(session);
        if (session.Manifest.Trips.Count == 0 && session.Manifest.Local.Count == 0)
            throw new InvalidOperationException("尚未整理：请先点「整理」生成行程分组，再完整打包");
        // 兜底：旧版本整理的会话没有 trips/（ArrangeFiles 曾漏接），打包前先补一遍（幂等）
        var missing = ZipPackager.ArrangeFiles(session);
        if (missing.Count > 0)
            throw new InvalidOperationException(
                $"以下 {missing.Count} 张票据的原文件缺失，无法完整打包：{string.Join("、", missing)}");
        return ZipPackager.Package(session, ExportsDir(session), includeExcel: true,
            homeCities: homeCities,
            excelWriter: p => ExcelBuilder.SaveTo(p, bills, homeCities));
    }
}
