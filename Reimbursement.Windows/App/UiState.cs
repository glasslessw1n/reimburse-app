using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Windowing;

namespace Reimbursement.App;

/// <summary>
/// DPI 缩放换算：AppWindow 的尺寸 API 收的是物理像素，而设计尺寸是 DIP，
/// 高分屏（150%/200%）下不折算窗口会显得只有一半大（用户 1.3.0 反馈的"窗口小"根因）。
/// </summary>
public static class DpiHelper
{
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    public static double Scale(IntPtr hwnd)
    {
        try
        {
            var dpi = GetDpiForWindow(hwnd);
            return dpi == 0 ? 1.0 : dpi / 96.0;
        }
        catch
        {
            return 1.0;
        }
    }

    /// <summary>设计尺寸（DIP）→ 物理像素。</summary>
    public static int Px(IntPtr hwnd, double dip) => (int)Math.Round(dip * Scale(hwnd));
}

/// <summary>
/// 界面状态持久化（ui-state.json，与 settings.env 同目录）：
/// 主窗口上次的位置/大小/最大化，以及"使用说明已展示过"标记。
/// 读写失败一律静默——状态丢了最多回到默认布局，绝不打扰用户。
/// </summary>
public sealed class UiState
{
    public int? X { get; set; }
    public int? Y { get; set; }
    public int? W { get; set; }
    public int? H { get; set; }
    public bool Maximized { get; set; }
    public bool HelpSeen { get; set; }

    private static string PathOf(string dataDir) => Path.Combine(dataDir, "ui-state.json");

    public static UiState Load(string dataDir)
    {
        try
        {
            var p = PathOf(dataDir);
            if (File.Exists(p))
                return JsonSerializer.Deserialize<UiState>(File.ReadAllText(p)) ?? new UiState();
        }
        catch
        {
            // 文件损坏就当新装
        }
        return new UiState();
    }

    public void Save(string dataDir)
    {
        try
        {
            File.WriteAllText(PathOf(dataDir), JsonSerializer.Serialize(this));
        }
        catch
        {
            // 存不下就算了，下次再记
        }
    }

    public bool HasBounds => X is not null && Y is not null && W is >= 400 && H is >= 300;

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int nIndex);

    /// <summary>保存的矩形是否与当前虚拟屏幕有足够交集（换显示器/改分辨率后防窗口飞出屏幕外）。</summary>
    public bool FitsOnScreen()
    {
        if (!HasBounds) return false;
        var vx = GetSystemMetrics(76); // SM_XVIRTUALSCREEN
        var vy = GetSystemMetrics(77); // SM_YVIRTUALSCREEN
        var vw = GetSystemMetrics(78); // SM_CXVIRTUALSCREEN
        var vh = GetSystemMetrics(79); // SM_CYVIRTUALSCREEN
        var overlapW = Math.Min(X!.Value + W!.Value, vx + vw) - Math.Max(X.Value, vx);
        var overlapH = Math.Min(Y!.Value + H!.Value, vy + vh) - Math.Max(Y.Value, vy);
        return overlapW >= 120 && overlapH >= 80;
    }
}
