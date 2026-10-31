using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Reimbursement.Core.Llm;
using Windows.Graphics;
using WinRT.Interop;

namespace Reimbursement.App;

/// <summary>
/// 设置窗口（XAML 声明式，取代旧版 168 行代码拼 ContentDialog——评估 P5）。
/// 字段与验证联动与旧版等价：改动地址/模型/Key 即清验证状态；拉取模型、测试连接为异步命令；
/// 保存仍走 Workflow/LlmSettingsStore（API Key 落盘由 Core 的 DPAPI 保护）。
/// </summary>
public sealed partial class SettingsWindow : Window
{
    private readonly Workflow _wf;
    private readonly List<LlmProvider> _providers = LlmProviderInfo.All.ToList();
    private bool _verified;
    private bool _initializing = true;

    public SettingsWindow(Workflow wf, PointInt32? ownerPos = null, SizeInt32? ownerSize = null)
    {
        _wf = wf;
        InitializeComponent();
        SystemBackdrop = new MicaBackdrop();
        // 尺寸按 DPI 折算（1.3.0）：旧版写死 580×760 物理像素，高分屏下只有约一半大、内容挤成一团。
        var hwnd = WindowNative.GetWindowHandle(this);
        var w = DpiHelper.Px(hwnd, 600);
        var h = DpiHelper.Px(hwnd, 780);
        AppWindow.Resize(new SizeInt32(w, h));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = DpiHelper.Px(hwnd, 520);
            presenter.PreferredMinimumHeight = DpiHelper.Px(hwnd, 560);
        }
        try
        {
            AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        }
        catch
        {
            // 图标缺失不拦窗口
        }
        // 居中于主窗口（无主窗口信息时居中于主屏工作区），并夹进工作区防溢出
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int x, y;
        if (ownerPos is { } p && ownerSize is { } s)
        {
            x = p.X + (s.Width - w) / 2;
            y = p.Y + (s.Height - h) / 2;
        }
        else
        {
            x = work.X + (work.Width - w) / 2;
            y = work.Y + (work.Height - h) / 2;
        }
        x = Math.Clamp(x, work.X, Math.Max(work.X, work.X + work.Width - w));
        y = Math.Clamp(y, work.Y, Math.Max(work.Y, work.Y + work.Height - h));
        AppWindow.Move(new PointInt32(x, y));

        var settings = _wf.LoadSettings();
        _verified = settings.LlmVerified;

        foreach (var p in _providers) ProviderBox.Items.Add(p.DisplayName());
        ProviderBox.SelectedIndex = Math.Max(0, _providers.IndexOf(LlmProviderInfo.Match(settings.BaseUrl)));

        BaseUrlBox.Text = settings.BaseUrl;
        ApiKeyBox.Password = settings.ApiKey;
        ModelBox.Text = settings.Model;
        LlmStatus.Text = _verified
            ? "连接状态：已验证 ✓"
            : "连接状态：未验证（改动地址/模型/Key 后需重新测试）";

        OcrBox.SelectedIndex = settings.OcrEngine switch { "oxr" => 1, "none" => 2, _ => 0 };
        OxrUrlBox.Text = settings.OxrBaseUrl;
        OxrKeyBox.Password = settings.OxrApiKey;
        HomeBox.Text = string.Join(",", settings.ExcludeCities);
        BuyerBox.Text = settings.BuyerName;
        TaxBox.Text = settings.BuyerTaxNo;

        BaseUrlBox.TextChanged += (_, _) => MarkUnverified();
        ApiKeyBox.PasswordChanged += (_, _) => MarkUnverified();
        ModelBox.TextSubmitted += (_, _) => MarkUnverified();
        _initializing = false;
    }

    private void MarkUnverified()
    {
        if (!_verified) return;
        _verified = false;
        LlmStatus.Text = "连接状态：未验证（已改动，需重新测试）";
    }

    private LlmSettings CurrentFromInputs()
    {
        var s = _wf.LoadSettings();
        s.BaseUrl = BaseUrlBox.Text.Trim();
        s.ApiKey = ApiKeyBox.Password;
        s.Model = (ModelBox.Text ?? "").Trim();
        return s;
    }

    private void ProviderBox_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_initializing) return; // 初始化赋值不联动，避免冲掉已保存值与验证状态
        if (ProviderBox.SelectedIndex < 0 || ProviderBox.SelectedIndex >= _providers.Count) return;
        var p = _providers[ProviderBox.SelectedIndex];
        // 初始化赋值也会触发本事件：仅当与当前值不同才覆盖，避免冲掉用户已保存的自定义值
        if (BaseUrlBox.Text != p.DefaultBaseUrl()) BaseUrlBox.Text = p.DefaultBaseUrl();
        if (ModelBox.Text != p.DefaultModel()) ModelBox.Text = p.DefaultModel();
        MarkUnverified();
    }

    private async void FetchBtn_Click(object sender, RoutedEventArgs e)
    {
        FetchBtn.IsEnabled = false;
        LlmStatus.Text = "正在拉取模型列表…";
        try
        {
            var models = await _wf.FetchModelsAsync(CurrentFromInputs());
            ModelBox.ItemsSource = models;
            if (models.Count > 0 && !models.Contains(ModelBox.Text)) ModelBox.Text = models[0];
            LlmStatus.Text = $"已拉取 {models.Count} 个模型";
        }
        catch (Exception ex)
        {
            LlmStatus.Text = $"拉取失败：{ex.Message}";
        }
        finally { FetchBtn.IsEnabled = true; }
    }

    private async void TestBtn_Click(object sender, RoutedEventArgs e)
    {
        TestBtn.IsEnabled = false;
        LlmStatus.Text = "正在测试连接…";
        try
        {
            var result = await _wf.TestLlmAsync(CurrentFromInputs());
            _verified = result.Ok;
            if (result.Models.Count > 0) ModelBox.ItemsSource = result.Models.ToList();
            LlmStatus.Text = (result.Ok ? "✓ " : "✗ ") + result.Message;
        }
        catch (Exception ex)
        {
            _verified = false;
            LlmStatus.Text = $"测试失败：{ex.Message}";
        }
        finally { TestBtn.IsEnabled = true; }
    }

    private void SaveBtn_Click(object sender, RoutedEventArgs e)
    {
        var settings = _wf.LoadSettings();
        settings.BaseUrl = BaseUrlBox.Text.Trim();
        settings.Model = (ModelBox.Text ?? "").Trim();
        settings.ApiKey = ApiKeyBox.Password;
        settings.LlmVerified = _verified;
        settings.OcrEngine = OcrBox.SelectedIndex switch { 1 => "oxr", 2 => "none", _ => "paddle" };
        settings.OxrBaseUrl = OxrUrlBox.Text.Trim();
        settings.OxrApiKey = OxrKeyBox.Password;
        settings.ExcludeCities = HomeBox.Text
            .Split(new[] { ',', '，', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(c => c.Trim()).Where(c => c.Length > 0).ToList();
        settings.BuyerName = BuyerBox.Text.Trim();
        settings.BuyerTaxNo = TaxBox.Text.Trim();
        _wf.SaveSettings(settings);
        Close();
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e) => Close();
}
