using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Reimbursement.Core.Llm;
using Reimbursement.Core.Models;
using Reimbursement.Core.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace Reimbursement.App;

/// <summary>
/// 主窗口：左侧会话列表，右侧票据列表 + 操作按钮 + 日志。
/// v1 为功能壳：导入 → 识别（文本层+LLM）→ 整理 → 检查 → 四种导出，全部走 Core。
/// </summary>
public sealed partial class MainWindow : Window
{
    private readonly Workflow _wf = new();
    private List<SessionSummary> _summaries = new();
    private SessionManager? _session;

    public MainWindow()
    {
        InitializeComponent();
        RefreshSessions();
        UpdateHomeLabel();
        Log($"数据目录：{_wf.DataDir}");
    }

    // MARK: 工具

    private HashSet<string> HomeCities() => _wf.LoadSettings().HomeCities;

    private void Log(string message)
    {
        LogBox.Text += $"[{DateTime.Now:HH:mm:ss}] {message}\n";
        LogBox.SelectionStart = LogBox.Text.Length;
        LogBox.SelectionLength = 0;
    }

    private void UpdateHomeLabel()
    {
        var settings = _wf.LoadSettings();
        var cities = settings.ExcludeCities.Count > 0
            ? string.Join("、", settings.ExcludeCities) : "（未设置）";
        HomeLabel.Text = $"常驻地：{cities}" +
            (settings.ApiKey.Length == 0 ? " · LLM 未配置，请先打开设置" : $" · 模型：{settings.Model}");
    }

    private void SetBusy(bool busy)
    {
        foreach (var b in new[] { ImportBtn, RecognizeBtn, FinalizeBtn, PreflightBtn,
                     ExcelBtn, ComposeBtn, MergeBtn, ZipBtn, NewSessionBtn })
            b.IsEnabled = !busy;
    }

    private bool RequireSession()
    {
        if (_session != null) return true;
        Log("请先在左侧新建或选择一个会话");
        return false;
    }

    // MARK: 会话列表

    private void RefreshSessions(string? selectSid = null)
    {
        _summaries = _wf.ListSessions();
        SessionList.Items.Clear();
        foreach (var s in _summaries)
        {
            var date = s.CreatedAt.Length >= 10 ? s.CreatedAt[..10] : s.CreatedAt;
            SessionList.Items.Add($"{date} · {s.BillCount} 张票 · {s.TripCount} 段行程");
        }
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
        RefreshDetail();
    }

    private void RefreshDetail()
    {
        BillList.Items.Clear();
        if (_session == null) return;
        foreach (var name in _wf.PendingFiles(_session))
            BillList.Items.Add($"（待识别）{name}");
        foreach (var b in Workflow.AllBills(_session))
        {
            var status = b.Error.Length > 0 ? $"失败：{b.Error}"
                : b.NeedsReview ? "需复核"
                : "已识别";
            BillList.Items.Add($"{b.SourceFile} ｜ {b.BillType.DisplayName()} ｜ ¥{b.Amount:0.00} ｜ {status}");
        }
    }

    // MARK: 操作

    private async void ImportBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        var picker = new FileOpenPicker();
        foreach (var ext in new[] { ".pdf", ".jpg", ".jpeg", ".png", ".bmp" })
            picker.FileTypeFilter.Add(ext);
        InitializeWithWindow.Initialize(picker, WindowNative.GetWindowHandle(this));
        var files = await picker.PickMultipleFilesAsync();
        if (files == null || files.Count == 0) return;
        SetBusy(true);
        try
        {
            foreach (var file in files)
            {
                var saved = _wf.ImportFile(_session!, file.Path);
                Log($"已导入：{file.Name}" + (saved != file.Name ? $"（落盘为 {saved}）" : ""));
            }
            RefreshDetail();
            RefreshSessions(_session!.Sid);
        }
        catch (Exception ex)
        {
            Log($"导入失败：{ex.Message}");
        }
        finally { SetBusy(false); }
    }

    private async void RecognizeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        var settings = _wf.LoadSettings();
        if (settings.ApiKey.Length == 0)
        {
            Log("未配置 LLM API Key：请先在「设置」里填写，识别已取消");
            return;
        }
        SetBusy(true);
        try
        {
            var lines = await _wf.RecognizePendingAsync(_session!, settings);
            if (lines.Count == 0) Log("没有待识别的文件");
            foreach (var line in lines) Log(line);
            RefreshDetail();
            RefreshSessions(_session!.Sid);
        }
        catch (Exception ex)
        {
            Log($"识别中断：{ex.Message}");
        }
        finally { SetBusy(false); }
    }

    private void FinalizeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try
        {
            _session!.Finalize(HomeCities());
            Log($"整理完成：{_session.Manifest.Trips.Count} 段行程，本地 {_session.Manifest.Local.Count} 张");
            foreach (var trip in _session.Manifest.Trips)
                Log($"  {trip.Dirname}（{trip.Bills.Count} 张）");
            RefreshDetail();
            RefreshSessions(_session.Sid);
        }
        catch (Exception ex)
        {
            Log($"整理失败：{ex.Message}");
        }
    }

    private void PreflightBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        var issues = Preflight.Check(_session!, HomeCities());
        if (issues.Count == 0)
        {
            Log("提交前检查：无问题 ✓");
            return;
        }
        Log($"提交前检查：{issues.Count} 项");
        foreach (var issue in issues)
            Log($"  [{issue.Severity}] {issue.Category}：{issue.Message}");
    }

    private void ExcelBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try { Log($"明细 Excel 已导出：{_wf.ExportExcel(_session!, HomeCities())}"); }
        catch (Exception ex) { Log($"导出失败：{ex.Message}"); }
    }

    private void ComposeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try
        {
            var result = _wf.ExportComposed(_session!);
            Log($"整合 PDF 已生成：{result.OutputPath}（{result.PageCount} 页）");
            foreach (var s in result.Skipped) Log($"  跳过：{s}");
        }
        catch (Exception ex) { Log($"整合失败：{ex.Message}"); }
    }

    private void MergeBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try
        {
            var result = _wf.ExportMerged(_session!);
            Log($"简单合并已生成：{result.OutputPath}（{result.PageCount} 页）");
            foreach (var s in result.Skipped) Log($"  跳过：{s}");
        }
        catch (Exception ex) { Log($"合并失败：{ex.Message}"); }
    }

    private void ZipBtn_Click(object sender, RoutedEventArgs e)
    {
        if (!RequireSession()) return;
        try { Log($"完整打包已生成：{_wf.ExportZip(_session!, HomeCities())}"); }
        catch (Exception ex) { Log($"打包失败：{ex.Message}"); }
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

        var providerBox = new ComboBox { HorizontalAlignment = HorizontalAlignment.Stretch };
        var providers = LlmProviderInfo.All.ToList();
        foreach (var p in providers) providerBox.Items.Add(p.DisplayName());
        providerBox.SelectedIndex = Math.Max(0, providers.IndexOf(LlmProviderInfo.Match(settings.BaseUrl)));

        var baseUrlBox = new TextBox { Text = settings.BaseUrl, Header = "API 地址（Base URL）" };
        var modelBox = new TextBox { Text = settings.Model, Header = "模型" };
        var apiKeyBox = new PasswordBox { Password = settings.ApiKey, Header = "API Key" };
        var homeBox = new TextBox
        {
            Text = string.Join(",", settings.ExcludeCities),
            Header = "常驻地城市（逗号分隔，如 重庆）",
        };
        var buyerBox = new TextBox { Text = settings.BuyerName, Header = "购方名称（发票抬头）" };
        var taxBox = new TextBox { Text = settings.BuyerTaxNo, Header = "购方税号" };

        providerBox.SelectionChanged += (_, _) =>
        {
            var p = providers[providerBox.SelectedIndex];
            baseUrlBox.Text = p.DefaultBaseUrl();
            modelBox.Text = p.DefaultModel();
        };

        var panel = new StackPanel { Spacing = 10, Width = 420 };
        panel.Children.Add(new TextBlock { Text = "服务商预设" });
        panel.Children.Add(providerBox);
        panel.Children.Add(baseUrlBox);
        panel.Children.Add(modelBox);
        panel.Children.Add(apiKeyBox);
        panel.Children.Add(homeBox);
        panel.Children.Add(buyerBox);
        panel.Children.Add(taxBox);

        var dialog = new ContentDialog
        {
            Title = "设置",
            Content = panel,
            PrimaryButtonText = "保存",
            CloseButtonText = "取消",
            XamlRoot = Content.XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            settings.BaseUrl = baseUrlBox.Text.Trim();
            settings.Model = modelBox.Text.Trim();
            settings.ApiKey = apiKeyBox.Password;
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
