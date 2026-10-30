using System.Collections.ObjectModel;
using System.Text;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Recognition;
using Reimbursement.Core.Storage;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;
using Color = Windows.UI.Color;

namespace Reimbursement.App;

/// <summary>票据列表的一行（富状态模型，供 DataTemplate 绑定）。</summary>
public sealed class BillRow
{
    public string SourceFile { get; init; } = "";
    public string Uid { get; init; } = "";
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public string StatusText { get; init; } = "";
    public Brush StatusBrush { get; init; } = new SolidColorBrush(Colors.Gray);
    public bool CanRetry { get; init; }
    public bool CanDelete { get; init; }
    /// <summary>分组视图（整理后）用：走分组模板，带类别色。</summary>
    public bool IsGrouped { get; init; }
    public string TypeName { get; init; } = "";
    public string AmountText { get; init; } = "";
    public string DateCityText { get; init; } = "";
    public Brush TypeBrush { get; init; } = new SolidColorBrush(Colors.Gray);
}

/// <summary>分组视图的行程标题行（点击展开/收起）。</summary>
public sealed class GroupHeaderRow
{
    public string GroupKey { get; init; } = "";
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public bool IsExpanded { get; init; } = true;
    /// <summary>Segoe Fluent Icons 字形（展开=ChevronDown E70D / 收起=ChevronRight E76C），模板里用 FontIcon 呈现。</summary>
    public string ToggleGlyph => IsExpanded ? "\uE70D" : "\uE76C";
}

/// <summary>会话列表的一张卡（可展开：行程概要 + 金额 + 删除）。</summary>
public sealed class SessionRow
{
    public string Sid { get; init; } = "";
    public string Title { get; init; } = "";
    public string Subtitle { get; init; } = "";
    public string TotalText { get; init; } = "";
    public IReadOnlyList<string> Briefs { get; init; } = Array.Empty<string>();
}

/// <summary>票据列表模板选择：标题行 / 分组票据行 / 平铺票据行。</summary>
public sealed class BillTemplateSelector : DataTemplateSelector
{
    public DataTemplate? FlatTemplate { get; set; }
    public DataTemplate? GroupTemplate { get; set; }
    public DataTemplate? HeaderTemplate { get; set; }

    protected override DataTemplate? SelectTemplateCore(object item) => item switch
    {
        GroupHeaderRow => HeaderTemplate,
        BillRow { IsGrouped: true } => GroupTemplate,
        _ => FlatTemplate,
    };

    protected override DataTemplate? SelectTemplateCore(object item, DependencyObject container) =>
        SelectTemplateCore(item);
}

/// <summary>
/// 主窗口 v2：常驻拖放区（拖入/选择即自动识别）、进度条 + 完成汇总、
/// 富状态票据行（单张重试/删除）、设置页带模型拉取与连接测试。
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly Workflow _wf = new();
    private List<SessionSummary> _summaries = new();
    private SessionManager? _session;
    /// <summary>票据区条目（平铺 BillRow；整理后混入 GroupHeaderRow + 分组 BillRow）。</summary>
    private readonly ObservableCollection<object> _items = new();
    private readonly ObservableCollection<SessionRow> _sessionRows = new();
    /// <summary>被用户收起的行程分组键（trip uid / local / ungrouped / pending）。</summary>
    private readonly HashSet<string> _collapsedGroups = new();
    private CancellationTokenSource? _recognizeCts;
    private bool _finalized;
    private RecognitionSummary? _lastSummary;

    private static readonly Brush Green = new SolidColorBrush(Colors.SeaGreen);
    private static readonly Brush Orange = new SolidColorBrush(Colors.DarkOrange);
    private static readonly Brush Red = new SolidColorBrush(Colors.IndianRed);
    private static readonly Brush Gray = new SolidColorBrush(Colors.Gray);

    // 类别配色（整理后分组视图按票据类别分色：交通蓝紫、酒店琥珀、滴滴橙、餐饮绿……）
    private static Brush BrushFrom(byte r, byte g, byte b) =>
        new SolidColorBrush(Color.FromArgb(0xFF, r, g, b));

    private static readonly Dictionary<BillType, Brush> TypeBrushes = new()
    {
        [BillType.TrainTicket] = BrushFrom(0x25, 0x63, 0xEB),
        [BillType.FlightItinerary] = BrushFrom(0x7C, 0x3A, 0xED),
        [BillType.BoardingPass] = BrushFrom(0x4F, 0x46, 0xE5),
        [BillType.HotelFolio] = BrushFrom(0xB4, 0x53, 0x09),
        [BillType.HotelInvoice] = BrushFrom(0xD9, 0x77, 0x06),
        [BillType.DidiTrip] = BrushFrom(0xEA, 0x58, 0x0C),
        [BillType.DidiInvoice] = BrushFrom(0xF9, 0x73, 0x16),
        [BillType.Dining] = BrushFrom(0x16, 0xA3, 0x4A),
        [BillType.GasInvoice] = BrushFrom(0xA1, 0x62, 0x07),
        [BillType.TollInvoice] = BrushFrom(0xCA, 0x8A, 0x04),
        [BillType.TaxiTransport] = BrushFrom(0x0D, 0x94, 0x88),
        [BillType.Telecom] = BrushFrom(0x08, 0x91, 0xB2),
        [BillType.SelfDriveSheet] = BrushFrom(0x57, 0x53, 0x4E),
    };

    private static Brush TypeBrushOf(BillType t) =>
        TypeBrushes.TryGetValue(t, out var br) ? br : Gray;

    /// <summary>票据的"日期 · 城市"一行（分组视图用）。</summary>
    private static string DateCityLine(BillInfo b)
    {
        var parts = new List<string>();
        var start = b.DateRange.Start ?? "";
        var end = b.DateRange.End ?? "";
        if (start.Length > 0)
            parts.Add(end.Length > 0 && end != start ? $"{start} ~ {end}" : start);
        else if (b.DateMMDDs.Count > 0)
            parts.Add(string.Join("、", b.DateMMDDs.Where(d => d.Length > 0).Take(3)));
        var from = b.FromCity ?? "";
        var to = b.ToCity ?? "";
        if (from.Length > 0 || to.Length > 0)
            parts.Add($"{from} → {to}".Trim(' ', '→'));
        else if (b.Cities.Count > 0)
            parts.Add(string.Join("、", b.Cities.Where(c => c.Length > 0).Distinct().Take(3)));
        return string.Join(" · ", parts);
    }

    /// <summary>由识别记录构造一行（平铺/分组共用字段，分组时 IsGrouped=true）。</summary>
    private BillRow MakeBillRow(BillInfo b, bool grouped)
    {
        var failed = (b.Error ?? "").Length > 0;
        var status = failed ? "失败" : b.NeedsReview ? "需复核" : "已识别";
        var brush = failed ? Red : b.NeedsReview ? Orange : Green;
        var title = failed || b.Amount <= 0
            ? b.SourceFile
            : $"{b.BillType.DisplayName()} · ¥{b.Amount:0.00}";
        var detail = failed ? b.Error
            : b.NeedsReview ? b.ReviewReason
            : string.Join(" ", b.Cities) + ((b.DateRange.Start ?? "").Length > 0 ? $" · {b.DateRange.Start}" : "");
        return new BillRow
        {
            SourceFile = b.SourceFile,
            Uid = b.Uid,
            Title = title,
            Subtitle = $"{b.SourceFile}" + (detail.Length > 0 ? $"｜{detail}" : ""),
            StatusText = status,
            StatusBrush = brush,
            CanRetry = true,
            CanDelete = true,
            IsGrouped = grouped,
            TypeName = b.BillType.DisplayName(),
            AmountText = b.Amount > 0 ? $"¥{b.Amount:0.00}" : "¥—",
            DateCityText = DateCityLine(b),
            TypeBrush = TypeBrushOf(b.BillType),
        };
    }

    public MainWindow()
    {
        CrashLog.Write("MainWindow ctor start");
        InitializeComponent();
        CrashLog.Write("MainWindow InitializeComponent done");
        // Fluent 基线：Mica 材质 + 内容延伸进标题栏 + 初始/最小尺寸（评估 P4）
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarGrid);
        AppWindow.Resize(new SizeInt32(1240, 800));
        // PreferredMinimumWidth/Height 是 AppSDK 1.7+ 才有的 API，1.6 不存在（CI #17 实证 CS1061）；
        // 初始尺寸给足即可，最小尺寸强制等 .NET 10 升级到新版 AppSDK 后补回。
        var version = typeof(MainWindow).Assembly.GetName().Version;
        VersionLabel.Text = version != null ? $"v{version.Major}.{version.Minor}.{version.Build}" : "";
        BillList.ItemsSource = _items;
        SessionList.ItemsSource = _sessionRows;
        RefreshSessions();
        if (_summaries.Count > 0 && SessionList.SelectedIndex < 0)
            SessionList.SelectedIndex = 0; // 默认打开最近会话，省一次点击
        UpdateHomeLabel();
        Log($"数据目录：{_wf.DataDir}");
        CrashLog.Write("MainWindow ctor done");
    }

    // MARK: 工具

    private HashSet<string> HomeCities() => _wf.LoadSettings().HomeCities;

    /// <summary>
    /// Velopack 自动更新：仅当本程序是经 Setup 安装的才查更新（便携 zip 运行自动跳过）。
    /// 发现新版 → 后台下载 → InfoBar 告知"重启后生效"；VelopackApp.Run() 会在下次启动时完成替换。
    /// 全程静默失败（无网络/限流都不打扰用户），细节进 AppLog。
    /// </summary>
    public async Task CheckForAppUpdateAsync()
    {
        try
        {
            var mgr = new Velopack.UpdateManager(
                new Velopack.Sources.GithubSource("https://github.com/glasslessw1n/reimburse-app", null, false));
            if (!mgr.IsInstalled) return;
            var update = await mgr.CheckForUpdatesAsync();
            if (update == null) return;
            await mgr.DownloadUpdatesAsync(update);
            ShowResult($"发现新版本 {update.TargetFullRelease.Version}，已下载，下次启动自动更新。",
                InfoBarSeverity.Success, log: true);
        }
        catch (Exception ex)
        {
            Core.Diagnostics.AppLog.Warn("update", $"检查更新失败（忽略）：{ex.Message}");
        }
    }

    /// <summary>诊断日志只存内存缓冲（上限约 200KB），从主界面移除常驻日志区，改走标题栏的诊断窗口。</summary>
    private readonly StringBuilder _logBuffer = new();

    private void Log(string message)
    {
        _logBuffer.Append($"[{DateTime.Now:HH:mm:ss}] {message}\n");
        if (_logBuffer.Length > 200_000) _logBuffer.Remove(0, 50_000);
    }

    /// <summary>结果反馈：进日志的同时在 InfoBar 带露脸（取代旧的"展开日志才看得见"）。</summary>
    private void LogAndShow(string message) => ShowResult(message, InfoBarSeverity.Informational, log: true);

    private void ShowResult(string message, InfoBarSeverity severity, bool log = false)
    {
        if (log) Log(message);
        ResultInfo.Title = "";
        ResultInfo.Severity = severity;
        ResultInfo.Message = message;
        ResultInfo.IsOpen = true;
    }

    private async void DiagBtn_Click(object sender, RoutedEventArgs e)
    {
        var box = new TextBox
        {
            Text = _logBuffer.Length > 0 ? _logBuffer.ToString() : "（暂无日志）",
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            FontFamily = new FontFamily("Consolas"),
            FontSize = 12,
            Height = 320,
            Width = 640,
        };
        var dialog = new ContentDialog
        {
            Title = "诊断日志",
            Content = box,
            CloseButtonText = "关闭",
            XamlRoot = Content.XamlRoot,
        };
        await dialog.ShowAsync();
    }

    private void UpdateHomeLabel()
    {
        var settings = _wf.LoadSettings();
        var cities = settings.ExcludeCities.Count > 0
            ? string.Join("、", settings.ExcludeCities) : "（未设置）";
        var ocr = settings.OcrEngine switch
        {
            "oxr" => "OXR 云端解析",
            "none" => "OCR 关",
            _ => "PaddleOCR 内置",
        };
        HomeLabel.Text = $"常驻地：{cities}" +
            (settings.ApiKey.Length == 0
                ? " · LLM 未配置"
                : $" · 模型：{settings.Model} · {(settings.LlmVerified ? "已验证" : "未验证")} · OCR：{ocr}");
        LlmWarnInfo.IsOpen = settings.ApiKey.Length == 0;
    }

    private void SetBusy(bool busy)
    {
        foreach (var b in new Button[] { ImportBtn, PrimaryBtn, PreflightBtn,
                     NewSessionBtn, SettingsBtn, ClearSessionsBtn, OpenExportsBtn })
            b.IsEnabled = !busy;
        ExportSplit.IsEnabled = !busy;
        CancelBtn.IsEnabled = busy;
        _busy = busy;
        UpdatePrimary();
    }

    private bool _busy;

    /// <summary>
    /// 流程状态机 → 唯一主按钮（评估蓝图 3.1）：每个状态只有一个该做的下一步，
    /// 消灭"8 个等权重按钮靠用户自己拼流程"。状态由（会话/待识别数/已识别数/是否已整理）决定。
    /// </summary>
    private enum FlowAction { Import, Recognize, Finalize, Package }

    private FlowAction CurrentFlowAction()
    {
        if (_session == null) return FlowAction.Import;
        if (_wf.PendingFiles(_session).Count > 0) return FlowAction.Recognize;
        if (Workflow.AllBills(_session).Count == 0) return FlowAction.Import;
        return _finalized ? FlowAction.Package : FlowAction.Finalize;
    }

    private void UpdatePrimary()
    {
        if (_busy) { PrimaryBtn.IsEnabled = false; return; }
        PrimaryBtn.IsEnabled = true;
        var pending = _session != null ? _wf.PendingFiles(_session).Count : 0;
        PrimaryBtn.Content = CurrentFlowAction() switch
        {
            FlowAction.Recognize => $"识别全部（{pending} 张待处理）",
            FlowAction.Finalize => "整理（生成行程与规范文件名）",
            FlowAction.Package => "完整打包 ZIP",
            _ => "导入票据",
        };
    }

    private async void PrimaryBtn_Click(object sender, RoutedEventArgs e)
    {
        switch (CurrentFlowAction())
        {
            case FlowAction.Recognize: RecognizeBtn_Click(sender, e); break;
            case FlowAction.Finalize: FinalizeBtn_Click(sender, e); break;
            case FlowAction.Package: ZipBtn_Click(sender, e); break;
            default: ImportBtn_Click(sender, e); break;
        }
    }

    /// <summary>导出 SplitButton 主体点击 = 默认项（完整打包）；箭头展开其余三种导出。</summary>
    private void ExportSplit_Click(SplitButton sender, SplitButtonClickEventArgs args) =>
        ZipBtn_Click(sender, new RoutedEventArgs());

    private void AccelImport_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (!_busy) ImportBtn_Click(sender, new RoutedEventArgs());
    }

    private void AccelPrimary_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        if (!_busy) PrimaryBtn_Click(sender, new RoutedEventArgs());
    }

    private bool RequireSession()
    {
        if (_session != null) return true;
        LogAndShow("请先在左侧新建或选择一个会话（或直接把票据拖进来，会自动新建）");
        return false;
    }

    private void UpdateSteps()
    {
        var step = 1;
        if (_session != null)
        {
            var pending = _wf.PendingFiles(_session).Count;
            var bills = Workflow.AllBills(_session).Count;
            if (_finalized) step = 4;
            else if (bills > 0 && pending == 0) step = 3;
            else if (bills > 0 || pending > 0) step = 2;
        }
        foreach (var (tb, n) in new[] { (Step1Text, 1), (Step2Text, 2), (Step3Text, 3), (Step4Text, 4) })
        {
            tb.FontWeight = n == step
                ? Microsoft.UI.Text.FontWeights.SemiBold
                : Microsoft.UI.Text.FontWeights.Normal;
            tb.Opacity = n == step ? 1.0 : 0.55;
        }
    }

    // MARK: 会话列表

    private void RefreshSessions(string? selectSid = null)
    {
        _summaries = _wf.ListSessions();
        _sessionRows.Clear();
        foreach (var s in _summaries)
        {
            var briefs = new List<string>();
            if (s.TripBriefs.Count == 0 && s.LocalCount == 0)
            {
                briefs.Add(s.BillCount == 0 ? "（空会话）" : "尚未整理");
            }
            else
            {
                foreach (var t in s.TripBriefs)
                    briefs.Add($"{t.Dirname} · {t.BillCount} 张 · ¥{t.Amount:0.00}");
                if (s.LocalCount > 0)
                    briefs.Add($"本地 · {s.LocalCount} 张 · ¥{s.LocalAmount:0.00}");
            }
            _sessionRows.Add(new SessionRow
            {
                Sid = s.Sid,
                Title = s.CreatedLabel,
                Subtitle = $"{s.BillCount} 张票 · {s.TripCount} 段行程",
                TotalText = s.TotalAmount > 0 ? $"¥{s.TotalAmount:0.00}" : "",
                Briefs = briefs,
            });
        }
        if (selectSid != null)
        {
            var idx = _summaries.FindIndex(s => s.Sid == selectSid);
            if (idx >= 0) SessionList.SelectedIndex = idx;
        }
    }

    private async void SessionDeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string sid } || sid.Length == 0) return;
        var summary = _summaries.FirstOrDefault(s => s.Sid == sid);
        var dialog = new ContentDialog
        {
            Title = "删除此会话？",
            Content = $"将删除 {summary?.CreatedLabel} 的会话（含 {summary?.BillCount ?? 0} 张票据的原件与识别记录），不可恢复。",
            PrimaryButtonText = "删除",
            CloseButtonText = "取消",
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        var wasCurrent = _session != null && _session.Sid == sid;
        _wf.DeleteSession(sid);
        Log($"已删除会话 {sid[..8]}…");
        if (wasCurrent)
        {
            _session = null;
            _finalized = false;
            HideSummary();
            HidePreflight();
            RefreshDetail();
        }
        RefreshSessions(_session?.Sid);
        if (_session == null && _summaries.Count > 0)
            SessionList.SelectedIndex = 0;
    }

    private async void ClearSessionsBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_summaries.Count == 0)
        {
            LogAndShow("没有可清除的会话");
            return;
        }
        var dialog = new ContentDialog
        {
            Title = "清除全部会话？",
            Content = $"将删除全部 {_summaries.Count} 个会话（含所有票据原件与识别记录），不可恢复。",
            PrimaryButtonText = "全部删除",
            CloseButtonText = "取消",
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;

        _wf.ClearAllSessions();
        _session = null;
        _finalized = false;
        HideSummary();
        HidePreflight();
        RefreshSessions();
        RefreshDetail();
        Log("已清除全部会话");
    }

    private void NewSessionBtn_Click(object sender, RoutedEventArgs e)
    {
        var session = _wf.CreateSession();
        Log($"已新建会话 {session.Sid[..8]}…");
        RefreshSessions(session.Sid);
    }

    private void SessionList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var idx = SessionList.SelectedIndex;
        if (idx < 0 || idx >= _summaries.Count) return;
        _session = _wf.OpenSession(_summaries[idx].Sid);
        _finalized = _session.Manifest.Finalized;
        if (_session.RecoveredFromCorruption)
            ShowResult("这个会话的清单文件曾损坏，已从备份重建为空会话（原件文件未动）。备份在会话目录的 manifest.corrupt-*.json。",
                InfoBarSeverity.Warning);
        HideSummary();
        HidePreflight();
        RefreshDetail();
    }

    // MARK: 票据列表（未整理=平铺；整理后=按行程分组）

    private BillRow PendingRow(string name) => new()
    {
        SourceFile = name,
        Title = name,
        Subtitle = "已导入，尚未识别",
        StatusText = "待识别",
        StatusBrush = Gray,
        CanRetry = true,
    };

    private void AddGroup(string key, string title, string subtitle, IEnumerable<object> rows)
    {
        var expanded = !_collapsedGroups.Contains(key);
        _items.Add(new GroupHeaderRow
        {
            GroupKey = key, Title = title, Subtitle = subtitle, IsExpanded = expanded,
        });
        if (expanded)
            foreach (var r in rows) _items.Add(r);
    }

    private void GroupToggleBtn_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string key } || key.Length == 0) return;
        if (!_collapsedGroups.Remove(key)) _collapsedGroups.Add(key);
        RefreshDetail();
    }

    private void RefreshDetail()
    {
        _items.Clear();
        if (_session == null)
        {
            EmptyState.Visibility = Visibility.Visible;
            UpdateSteps();
            UpdatePrimary();
            return;
        }

        var pending = _wf.PendingFiles(_session);
        EmptyState.Visibility = pending.Count == 0 && Workflow.AllBills(_session).Count == 0
            ? Visibility.Visible : Visibility.Collapsed;
        var grouped = _finalized
            && (_session.Manifest.Trips.Count > 0 || _session.Manifest.Local.Count > 0);
        if (!grouped)
        {
            foreach (var name in pending) _items.Add(PendingRow(name));
            foreach (var b in Workflow.AllBills(_session)) _items.Add(MakeBillRow(b, grouped: false));
            UpdateSteps();
            UpdatePrimary();
            return;
        }

        // 整理后：按行程分组详细显示（日期/城市/金额），类别分色，行程可展开/收起
        if (pending.Count > 0)
            AddGroup("pending", "待识别文件", $"{pending.Count} 个文件",
                pending.Select(n => (object)PendingRow(n)));

        var groupedUids = new HashSet<string>();
        foreach (var trip in _session.Manifest.Trips)
        {
            foreach (var b in trip.Bills) groupedUids.Add(b.Uid);
            var total = trip.Bills.Sum(b => b.Amount);
            AddGroup(trip.Uid, trip.Dirname, $"{trip.Bills.Count} 张 · ¥{total:0.00}",
                trip.Bills.Select(b => (object)MakeBillRow(b, grouped: true)));
        }
        if (_session.Manifest.Local.Count > 0)
        {
            foreach (var b in _session.Manifest.Local) groupedUids.Add(b.Uid);
            var total = _session.Manifest.Local.Sum(b => b.Amount);
            AddGroup("local", "本地票据", $"{_session.Manifest.Local.Count} 张 · ¥{total:0.00}",
                _session.Manifest.Local.Select(b => (object)MakeBillRow(b, grouped: true)));
        }
        // 安全网：整理后新增/异常导致未进任何分组的票据也要露出来，不能悄悄消失
        var ungrouped = Workflow.AllBills(_session).Where(b => !groupedUids.Contains(b.Uid)).ToList();
        if (ungrouped.Count > 0)
        {
            var total = ungrouped.Sum(b => b.Amount);
            AddGroup("ungrouped", "未分组", $"{ungrouped.Count} 张 · ¥{total:0.00}",
                ungrouped.Select(b => (object)MakeBillRow(b, grouped: true)));
        }
        UpdateSteps();
        UpdatePrimary();
    }

    private async void RowRetryBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        if (sender is Button { Tag: string name } && name.Length > 0)
            await RecognizeFilesAsync(new[] { name });
    }

    /// <summary>已整理状态下票据集变化（删除/重识别）时重跑整理，让行程分组与票据集保持一致。</summary>
    private void ResyncFinalized()
    {
        if (!_finalized || _session == null) return;
        try { _session.Finalize(HomeCities()); }
        catch (Exception ex) { Log($"重新整理失败：{ex.Message}"); }
    }

    private void RowDeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        if (sender is Button { Tag: string uid } && uid.Length > 0)
        {
            var bill = Workflow.AllBills(_session!).FirstOrDefault(b => b.Uid == uid);
            _session!.RemoveBill(uid);
            Log($"已删除识别记录：{bill?.SourceFile}（原文件保留，回到待识别）");
            ResyncFinalized();
            RefreshDetail();
            RefreshSessions(_session.Sid);
        }
    }

    // MARK: 导入（拖放 / 选择 → 自动识别）

    private void DropZone_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "松开导入并自动识别";
        }
    }

    private async void DropZone_Drop(object sender, DragEventArgs e)
    {
        e.Handled = true; // 阻止冒泡到根 Grid 造成重复导入
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var paths = items.OfType<StorageFile>().Select(f => f.Path).Where(p => p.Length > 0).ToList();
        if (paths.Count > 0) await ImportAndRecognizeAsync(paths);
    }

    /// <summary>整窗拖放（评估 P6：不再只有橙色框能接文件）。</summary>
    private void Root_DragOver(object sender, DragEventArgs e)
    {
        if (e.DataView.Contains(StandardDataFormats.StorageItems))
        {
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.DragUIOverride.Caption = "松开导入并自动识别";
        }
    }

    private async void Root_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        var paths = items.OfType<StorageFile>().Select(f => f.Path).Where(p => p.Length > 0).ToList();
        if (paths.Count > 0) await ImportAndRecognizeAsync(paths);
    }

    private async void ImportBtn_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        foreach (var ext in new[] { ".pdf", ".jpg", ".jpeg", ".png", ".bmp" })
            picker.FileTypeFilter.Add(ext);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files == null || files.Count == 0) return;
        await ImportAndRecognizeAsync(files.Select(f => f.Path).ToList());
    }

    /// <summary>导入一批文件（无会话时自动新建），随后立即自动识别这批文件。</summary>
    private async Task ImportAndRecognizeAsync(IReadOnlyList<string> paths)
    {
        if (_session == null)
        {
            _session = _wf.CreateSession();
            Log($"已自动新建会话 {_session.Sid[..8]}…");
            RefreshSessions(_session.Sid);
        }
        var savedNames = new List<string>();
        try
        {
            foreach (var path in paths)
            {
                var saved = _wf.ImportFile(_session, path);
                savedNames.Add(saved);
                Log($"已导入：{Path.GetFileName(path)}" + (saved != Path.GetFileName(path) ? $"（落盘为 {saved}）" : ""));
            }
        }
        catch (Exception ex)
        {
            Log($"导入失败：{ex.Message}");
            return;
        }
        _finalized = false;
        RefreshDetail();
        RefreshSessions(_session.Sid);
        await RecognizeFilesAsync(savedNames);
    }

    // MARK: 识别（进度 + 汇总）

    private async void RecognizeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        var pending = _wf.PendingFiles(_session!);
        if (pending.Count == 0)
        {
            Log("没有待识别的文件");
            return;
        }
        await RecognizeFilesAsync(pending);
    }

    private async Task RecognizeFilesAsync(IReadOnlyList<string> names)
    {
        if (_session == null || names.Count == 0) return;
        var settings = _wf.LoadSettings();
        if (settings.ApiKey.Length == 0)
        {
            Log("未配置 LLM API Key：请先在「设置」里填写并测试连接，识别已取消");
            return;
        }

        HideSummary();
        ProgressArea.Visibility = Visibility.Visible;
        ProgressBar.Maximum = names.Count;
        ProgressBar.Value = 0;
        ProgressText.Text = $"准备识别 {names.Count} 张…";
        SetBusy(true);
        _recognizeCts = new CancellationTokenSource();

        var progress = new Progress<RecognitionProgress>(p =>
        {
            ProgressBar.Maximum = Math.Max(1, p.Total);
            ProgressBar.Value = p.Completed;
            ProgressText.Text = $"{p.Completed}/{p.Total} · {p.FileName} · {p.Message}";
            if (p.Stage is RecognitionStage.Completed or RecognitionStage.Failed)
                RefreshDetail();
        });

        try
        {
            var summary = await _wf.RunRecognitionAsync(_session, settings, names, progress, _recognizeCts.Token);
            _lastSummary = summary;
            foreach (var item in summary.Items) Log($"{item.FileName}：{item.Message}");
            ShowSummary(summary);
        }
        catch (OperationCanceledException)
        {
            Log("识别已取消");
        }
        catch (Exception ex)
        {
            Log($"识别中断：{ex.Message}");
        }
        finally
        {
            ProgressArea.Visibility = Visibility.Collapsed;
            SetBusy(false);
            _recognizeCts.Dispose();
            _recognizeCts = null;
            ResyncFinalized();
            RefreshDetail();
            if (_session != null) RefreshSessions(_session.Sid);
        }
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e) => _recognizeCts?.Cancel();

    // MARK: 完成汇总横幅

    private void ShowSummary(RecognitionSummary summary)
    {
        SummaryInfo.Message =
            $"成功 {summary.Succeeded} · 失败 {summary.Failed} · 需复核 {summary.NeedsReview}（共 {summary.Total} 张）";
        SummaryInfo.Severity = summary.Failed > 0 ? InfoBarSeverity.Warning : InfoBarSeverity.Success;
        SummaryActionBtn.Content = summary.Failed > 0 ? "重试失败项" : "下一步：整理";
        SummaryInfo.IsOpen = true;
    }

    private void HideSummary() => SummaryInfo.IsOpen = false;

    private async void SummaryActionBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_lastSummary != null && _lastSummary.Failed > 0)
        {
            var failedNames = _lastSummary.Items.Where(i => !i.Success).Select(i => i.FileName).ToList();
            HideSummary();
            await RecognizeFilesAsync(failedNames);
        }
        else
        {
            HideSummary();
            FinalizeBtn_Click(sender, e);
        }
    }

    private void SummaryCloseBtn_Click(object sender, RoutedEventArgs e) => HideSummary();

    // MARK: 整理 / 检查 / 导出

    private void FinalizeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try
        {
            _session!.Finalize(HomeCities());
            _finalized = true;
            LogAndShow($"整理完成：{_session.Manifest.Trips.Count} 段行程，本地 {_session.Manifest.Local.Count} 张");
            foreach (var trip in _session.Manifest.Trips)
                Log($"  {trip.Dirname}（{trip.Bills.Count} 张）");
            RefreshDetail();
            RefreshSessions(_session.Sid);
        }
        catch (Exception ex)
        {
            LogAndShow($"整理失败：{ex.Message}");
        }
    }

    private void PreflightBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        // 本处理函数曾是全窗唯一没套异常保护的：Check 一旦抛错就被全局处理器
        // 静默吞进崩溃日志，界面上表现为"点了没反应"。现在：异常必露脸，结果走横幅。
        try
        {
            var issues = Preflight.Check(_session!, HomeCities());
            var errors = issues.Count(i => i.Severity == PreflightSeverity.Error);
            var warnings = issues.Count(i => i.Severity == PreflightSeverity.Warning);
            var infos = issues.Count - errors - warnings;
            if (issues.Count == 0)
            {
                ShowPreflightBanner("提交前检查通过：无问题 ✓", PreflightSeverity.Info);
                LogAndShow("提交前检查：无问题 ✓");
                return;
            }
            var worst = errors > 0 ? PreflightSeverity.Error
                : warnings > 0 ? PreflightSeverity.Warning : PreflightSeverity.Info;
            // 检查明细直接进 InfoBar 正文（可换行），不再只丢进日志（评估 P1）
            var detail = string.Join("\n", issues.Select(i => $"[{i.Severity}] {i.Category}：{i.Message}"));
            ShowPreflightBanner(
                $"提交前检查：{errors} 个错误 · {warnings} 个警告 · {infos} 条提示\n{detail}", worst);
            Log($"提交前检查：共 {issues.Count} 项（错误 {errors} · 警告 {warnings} · 提示 {infos}）");
            foreach (var issue in issues)
                Log($"  [{issue.Severity}] {issue.Category}：{issue.Message}");
        }
        catch (Exception ex)
        {
            CrashLog.WriteException("PreflightBtn_Click", ex);
            ShowPreflightBanner($"提交前检查出错：{ex.Message}", PreflightSeverity.Error);
            LogAndShow($"提交前检查出错：{ex.Message}");
        }
    }

    private void ShowPreflightBanner(string text, PreflightSeverity worst)
    {
        ResultInfo.Title = "提交前检查";
        ResultInfo.Severity = worst switch
        {
            PreflightSeverity.Error => InfoBarSeverity.Error,
            PreflightSeverity.Warning => InfoBarSeverity.Warning,
            _ => InfoBarSeverity.Success,
        };
        ResultInfo.Message = text;
        ResultInfo.IsOpen = true;
    }

    private void HidePreflight() => ResultInfo.IsOpen = false;

    private void ExcelBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try { LogAndShow($"明细 Excel 已导出：{_wf.ExportExcel(_session!, HomeCities())}"); }
        catch (Exception ex) { LogAndShow($"导出失败：{ex.Message}"); }
    }

    private void ComposeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try
        {
            var result = _wf.ExportComposed(_session!);
            LogAndShow($"整合 PDF 已生成：{result.OutputPath}（{result.PageCount} 页）");
            foreach (var s in result.Skipped) Log($"  跳过：{s}");
        }
        catch (Exception ex) { LogAndShow($"整合失败：{ex.Message}"); }
    }

    private void MergeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try
        {
            var result = _wf.ExportMerged(_session!);
            LogAndShow($"简单合并已生成：{result.OutputPath}（{result.PageCount} 页）");
            foreach (var s in result.Skipped) Log($"  跳过：{s}");
        }
        catch (Exception ex) { LogAndShow($"合并失败：{ex.Message}"); }
    }

    private void ZipBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try { LogAndShow($"完整打包已生成：{_wf.ExportZip(_session!, HomeCities())}"); }
        catch (Exception ex) { LogAndShow($"打包失败：{ex.Message}"); }
    }

    private async void OpenExportsBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        var dir = _wf.ExportsDir(_session!);
        await Windows.System.Launcher.LaunchFolderPathAsync(dir);
    }

    // MARK: 设置（独立 XAML 窗口，取代旧的 168 行代码拼对话框）

    private SettingsWindow? _settingsWindow;

    private void SettingsBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_settingsWindow != null)
        {
            _settingsWindow.Activate();
            return;
        }
        _settingsWindow = new SettingsWindow(_wf);
        _settingsWindow.Closed += (_, _) =>
        {
            _settingsWindow = null;
            UpdateHomeLabel();
            UpdatePrimary();
            Log("设置已保存（或关闭）");
        };
        _settingsWindow.Activate();
    }

}
