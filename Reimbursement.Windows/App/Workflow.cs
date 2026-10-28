using System.Globalization;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Packaging;
using Reimbursement.Core.Recognition;
using Reimbursement.Core.Storage;

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

    public Workflow()
    {
        DataDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "Reimbursement.Windows");
        SessionsRoot = Path.Combine(DataDir, "sessions");
        SettingsPath = Path.Combine(DataDir, "settings.env");
        Directory.CreateDirectory(SessionsRoot);
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
        store.Save();
    }

    // MARK: 会话

    public List<SessionSummary> ListSessions() => Sessions.List(SessionsRoot);

    public SessionManager CreateSession() => new(SessionsRoot, Sessions.CreateNewSid());

    public SessionManager OpenSession(string sid) => new(SessionsRoot, sid);

    public static List<BillInfo> AllBills(SessionManager session) =>
        session.Manifest.Trips.SelectMany(t => t.Bills).Concat(session.Manifest.Local).ToList();

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

    /// <summary>导入一个文件到会话 originals，返回落盘名（同名自动 -2/-3）。</summary>
    public string ImportFile(SessionManager session, string path) =>
        session.SaveOriginal(File.ReadAllBytes(path), Path.GetFileName(path));

    // MARK: 识别管线

    /// <summary>
    /// 待识别队列逐个处理：PDF 文本层直提 → LLM 两段式识别 → 登记。
    /// 无文本层（疑似扫描件）跳过并在日志注明——OCR 引擎在 spike 分支接入后补齐。
    /// 返回逐条日志。
    /// </summary>
    public async Task<List<string>> RecognizePendingAsync(
        SessionManager session, LlmSettings settings, CancellationToken ct = default)
    {
        var log = new List<string>();
        var recognizer = new LlmRecognizer(new LlmClient(settings.ToConfig()));
        foreach (var name in PendingFiles(session))
        {
            ct.ThrowIfCancellationRequested();
            var path = Path.Combine(session.RootDir, "originals", name);
            var text = TextExtractor.Extract(path);
            if (TextExtractor.LooksScanned(text))
            {
                log.Add($"{name}：无文本层（疑似扫描件），待 OCR 引擎接入，本次跳过");
                continue;
            }
            var receipt = await recognizer.RecognizeAsync(text, name, name, ct);
            var bill = ToBill(receipt, name);
            session.Ingest(bill);
            log.Add(bill.Error.Length > 0
                ? $"{name}：识别失败——{bill.Error}"
                : $"{name}：{bill.BillType.DisplayName()} ¥{bill.Amount:0.00}" +
                  (bill.NeedsReview ? "（需复核）" : ""));
        }
        return log;
    }

    /// <summary>Receipt → BillInfo（金额取 fields["amount"]；低置信标复核——app 层组装，与 mac 版分工一致）。</summary>
    private static BillInfo ToBill(Receipt receipt, string sourceFile)
    {
        double amount = 0;
        if (receipt.Fields.TryGetValue("amount", out var raw) && raw != null)
            double.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out amount);
        var lowConfidence = receipt.Error.Length == 0 && receipt.Confidence < 0.7;
        return new BillInfo(receipt.ReceiptType, amount, sourceFile, receipt.Fields)
        {
            Confidence = receipt.Confidence,
            Error = receipt.Error,
            NeedsReview = lowConfidence,
            ReviewReason = lowConfidence ? $"识别置信度偏低（{receipt.Confidence:0.00}）" : "",
        };
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
        return ZipPackager.Package(session, ExportsDir(session), includeExcel: true,
            homeCities: homeCities,
            excelWriter: p => ExcelBuilder.SaveTo(p, bills, homeCities));
    }
}
