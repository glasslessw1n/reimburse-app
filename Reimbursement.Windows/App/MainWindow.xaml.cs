using System.Collections.ObjectModel;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Recognition;
using Reimbursement.Core.Storage;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

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
    private readonly ObservableCollection<BillRow> _rows = new();
    private CancellationTokenSource? _recognizeCts;
    private bool _finalized;
    private RecognitionSummary? _lastSummary;

    private static readonly Brush Green = new SolidColorBrush(Colors.SeaGreen);
    private static readonly Brush Orange = new SolidColorBrush(Colors.DarkOrange);
    private static readonly Brush Red = new SolidColorBrush(Colors.IndianRed);
    private static readonly Brush Gray = new SolidColorBrush(Colors.Gray);

    public MainWindow()
    {
        CrashLog.Write("MainWindow ctor start");
        InitializeComponent();
        CrashLog.Write("MainWindow InitializeComponent done");
        BillList.ItemsSource = _rows;
        RefreshSessions();
        if (_summaries.Count > 0 && SessionList.SelectedIndex < 0)
            SessionList.SelectedIndex = 0; // 默认打开最近会话，省一次点击
        UpdateHomeLabel();
        Log($"数据目录：{_wf.DataDir}");
        CrashLog.Write("MainWindow ctor done");
    }

    // MARK: 工具

    private HashSet<string> HomeCities() => _wf.LoadSettings().HomeCities;

    private void Log(string message)
    {
        LogBox.Text += $"[{DateTime.Now:HH:mm:ss}] {message}\n";
        LogBox.SelectionStart = LogBox.Text.Length;
        LogBox.SelectionLength = 0;
    }

    /// <summary>记日志并展开日志区（整理/检查/导出类结果用，避免用户看不到任何反馈）。</summary>
    private void LogAndShow(string message)
    {
        Log(message);
        LogExpander.IsExpanded = true;
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
                ? " · LLM 未配置，请先打开设置"
                : $" · 模型：{settings.Model} · {(settings.LlmVerified ? "已验证" : "未验证")} · OCR：{ocr}");
    }

    private void SetBusy(bool busy)
    {
        foreach (var b in new[] { ImportBtn, RecognizeBtn, FinalizeBtn, PreflightBtn,
                     ExcelBtn, ComposeBtn, MergeBtn, ZipBtn, NewSessionBtn, SettingsBtn })
            b.IsEnabled = !busy;
        CancelBtn.IsEnabled = busy;
    }

    private bool RequireSession()
    {
        if (_session != null) return true;
        Log("请先在左侧新建或选择一个会话（或直接把票据拖进来，会自动新建）");
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
        SessionList.Items.Clear();
        foreach (var s in _summaries)
            SessionList.Items.Add($"{s.CreatedLabel} · {s.BillCount} 张票 · {s.TripCount} 段行程");
        if (selectSid != null)
        {
            var idx = _summaries.FindIndex(s => s.Sid == selectSid);
            if (idx >= 0) SessionList.SelectedIndex = idx;
        }
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
        _finalized = _session.Manifest.Trips.Count > 0 || _session.Manifest.Local.Count > 0;
        HideSummary();
        RefreshDetail();
    }

    // MARK: 票据列表（富行）

    private void RefreshDetail()
    {
        _rows.Clear();
        if (_session == null) { UpdateSteps(); return; }
        foreach (var name in _wf.PendingFiles(_session))
        {
            _rows.Add(new BillRow
            {
                SourceFile = name,
                Title = name,
                Subtitle = "已导入，尚未识别",
                StatusText = "待识别",
                StatusBrush = Gray,
                CanRetry = true,
            });
        }
        foreach (var b in Workflow.AllBills(_session))
        {
            var failed = b.Error.Length > 0;
            var status = failed ? "失败" : b.NeedsReview ? "需复核" : "已识别";
            var brush = failed ? Red : b.NeedsReview ? Orange : Green;
            var title = failed || b.Amount <= 0
                ? b.SourceFile
                : $"{b.BillType.DisplayName()} · ¥{b.Amount:0.00}";
            var detail = failed ? b.Error
                : b.NeedsReview ? b.ReviewReason
                : string.Join(" ", b.Cities) + (b.DateRange.Start.Length > 0 ? $" · {b.DateRange.Start}" : "");
            _rows.Add(new BillRow
            {
                SourceFile = b.SourceFile,
                Uid = b.Uid,
                Title = title,
                Subtitle = $"{b.SourceFile}" + (detail.Length > 0 ? $"｜{detail}" : ""),
                StatusText = status,
                StatusBrush = brush,
                CanRetry = true,
                CanDelete = true,
            });
        }
        UpdateSteps();
    }

    private async void RowRetryBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        if (sender is Button { Tag: string name } && name.Length > 0)
            await RecognizeFilesAsync(new[] { name });
    }

    private void RowDeleteBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        if (sender is Button { Tag: string uid } && uid.Length > 0)
        {
            var bill = Workflow.AllBills(_session!).FirstOrDefault(b => b.Uid == uid);
            _session!.RemoveBill(uid);
            Log($"已删除识别记录：{bill?.SourceFile}（原文件保留，回到待识别）");
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
            RefreshDetail();
            if (_session != null) RefreshSessions(_session.Sid);
        }
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e) => _recognizeCts?.Cancel();

    // MARK: 完成汇总横幅

    private void ShowSummary(RecognitionSummary summary)
    {
        SummaryText.Text =
            $"识别完成：成功 {summary.Succeeded} · 失败 {summary.Failed} · 需复核 {summary.NeedsReview}（共 {summary.Total} 张）";
        SummaryActionBtn.Content = summary.Failed > 0 ? "重试失败项" : "下一步：整理";
        SummaryBanner.Background = new SolidColorBrush(
            summary.Failed > 0 ? Colors.DarkGoldenrod : Colors.SeaGreen);
        SummaryBanner.Visibility = Visibility.Visible;
    }

    private void HideSummary() => SummaryBanner.Visibility = Visibility.Collapsed;

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
        var issues = Preflight.Check(_session!, HomeCities());
        if (issues.Count == 0)
        {
            LogAndShow("提交前检查：无问题 ✓");
            return;
        }
        LogAndShow($"提交前检查：{issues.Count} 项");
        foreach (var issue in issues)
            Log($"  [{issue.Severity}] {issue.Category}：{issue.Message}");
    }

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

    // MARK: 设置

    private async void SettingsBtn_Click(object sender, RoutedEventArgs e)
    {
        var settings = _wf.LoadSettings();
        var verified = settings.LlmVerified;

        var providerBox = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var providers = LlmProviderInfo.All.ToList();
        foreach (var p in providers) providerBox.Items.Add(p.DisplayName());
        providerBox.SelectedIndex = Math.Max(0, providers.IndexOf(LlmProviderInfo.Match(settings.BaseUrl)));

        var baseUrlBox = new TextBox { Text = settings.BaseUrl, Header = "API 地址（Base URL）" };
        var apiKeyBox = new PasswordBox { Password = settings.ApiKey, Header = "API Key" };

        var modelBox = new ComboBox
        {
            IsEditable = true,
            Text = settings.Model,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var fetchBtn = new Button { Content = "拉取模型" };
        var testBtn = new Button { Content = "测试连接" };
        var llmStatus = new TextBlock
        {
            FontSize = 12,
            Text = verified ? "连接状态：已验证 ✓" : "连接状态：未验证（改动地址/模型/Key 后需重新测试）",
        };
        var modelRow = new Grid { ColumnSpacing = 8 };
        modelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        modelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        modelRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(modelBox, 0);
        Grid.SetColumn(fetchBtn, 1);
        Grid.SetColumn(testBtn, 2);
        modelRow.Children.Add(modelBox);
        modelRow.Children.Add(fetchBtn);
        modelRow.Children.Add(testBtn);

        void MarkUnverified()
        {
            verified = false;
            llmStatus.Text = "连接状态：未验证（已改动，需重新测试）";
        }
        baseUrlBox.TextChanged += (_, _) => MarkUnverified();
        apiKeyBox.PasswordChanged += (_, _) => MarkUnverified();
        modelBox.TextSubmitted += (_, _) => MarkUnverified();

        LlmSettings CurrentFromInputs()
        {
            var s = _wf.LoadSettings();
            s.BaseUrl = baseUrlBox.Text.Trim();
            s.ApiKey = apiKeyBox.Password;
            s.Model = (modelBox.Text ?? "").Trim();
            return s;
        }

        fetchBtn.Click += async (_, _) =>
        {
            fetchBtn.IsEnabled = false;
            llmStatus.Text = "正在拉取模型列表…";
            try
            {
                var models = await _wf.FetchModelsAsync(CurrentFromInputs());
                modelBox.ItemsSource = models;
                if (models.Count > 0 && !models.Contains(modelBox.Text)) modelBox.Text = models[0];
                llmStatus.Text = $"已拉取 {models.Count} 个模型";
            }
            catch (Exception ex)
            {
                llmStatus.Text = $"拉取失败：{ex.Message}";
            }
            finally { fetchBtn.IsEnabled = true; }
        };

        testBtn.Click += async (_, _) =>
        {
            testBtn.IsEnabled = false;
            llmStatus.Text = "正在测试连接…";
            try
            {
                var result = await _wf.TestLlmAsync(CurrentFromInputs());
                verified = result.Ok;
                if (result.Models.Count > 0) modelBox.ItemsSource = result.Models.ToList();
                llmStatus.Text = (result.Ok ? "✓ " : "✗ ") + result.Message;
            }
            catch (Exception ex)
            {
                verified = false;
                llmStatus.Text = $"测试失败：{ex.Message}";
            }
            finally { testBtn.IsEnabled = true; }
        };

        providerBox.SelectionChanged += (_, _) =>
        {
            var p = providers[providerBox.SelectedIndex];
            baseUrlBox.Text = p.DefaultBaseUrl();
            modelBox.Text = p.DefaultModel();
            MarkUnverified();
        };

        // OCR 设置
        var ocrBox = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        ocrBox.Items.Add("内置 PaddleOCR（离线，默认）");
        ocrBox.Items.Add("OXR 云端解析（增强，扫描件优先走云端）");
        ocrBox.Items.Add("不用 OCR（仅 PDF 文本层）");
        ocrBox.SelectedIndex = settings.OcrEngine switch { "oxr" => 1, "none" => 2, _ => 0 };
        var oxrUrlBox = new TextBox { Text = settings.OxrBaseUrl, Header = "OXR 服务地址" };
        var oxrKeyBox = new PasswordBox { Password = settings.OxrApiKey, Header = "OXR API Key（免费接口可留空）" };

        var homeBox = new TextBox
        {
            Text = string.Join(",", settings.ExcludeCities),
            Header = "常驻地城市（逗号分隔，如 重庆）",
        };
        var buyerBox = new TextBox { Text = settings.BuyerName, Header = "购方名称（发票抬头）" };
        var taxBox = new TextBox { Text = settings.BuyerTaxNo, Header = "购方税号" };

        var panel = new StackPanel { Spacing = 10, Width = 460 };
        panel.Children.Add(new TextBlock { Text = "服务商预设" });
        panel.Children.Add(providerBox);
        panel.Children.Add(baseUrlBox);
        panel.Children.Add(apiKeyBox);
        panel.Children.Add(new TextBlock { Text = "模型" });
        panel.Children.Add(modelRow);
        panel.Children.Add(llmStatus);
        panel.Children.Add(new TextBlock { Text = "OCR 引擎", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 0) });
        panel.Children.Add(ocrBox);
        panel.Children.Add(oxrUrlBox);
        panel.Children.Add(oxrKeyBox);
        panel.Children.Add(homeBox);
        panel.Children.Add(buyerBox);
        panel.Children.Add(taxBox);

        var dialog = new ContentDialog
        {
            Title = "设置",
            Content = new ScrollViewer { Content = panel, MaxHeight = 560 },
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            settings.BaseUrl = baseUrlBox.Text.Trim();
            settings.Model = (modelBox.Text ?? "").Trim();
            settings.ApiKey = apiKeyBox.Password;
            settings.LlmVerified = verified;
            settings.OcrEngine = ocrBox.SelectedIndex switch { 1 => "oxr", 2 => "none", _ => "paddle" };
            settings.OxrBaseUrl = oxrUrlBox.Text.Trim();
            settings.OxrApiKey = oxrKeyBox.Password;
            settings.ExcludeCities = homeBox.Text
                .Split(new[] { ',', '，', ' ' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(c => c.Trim()).Where(c => c.Length > 0).ToList();
            settings.BuyerName = buyerBox.Text.Trim();
            settings.BuyerTaxNo = taxBox.Text.Trim();
            _wf.SaveSettings(settings);
            UpdateHomeLabel();
            Log("设置已保存");
        }
    }
}
