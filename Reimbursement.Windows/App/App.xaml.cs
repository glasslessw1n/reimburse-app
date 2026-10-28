using Microsoft.UI.Xaml;

namespace Reimbursement.App;

/// <summary>WinUI 3 壳入口（非打包部署）。业务逻辑全部在 Core，本层只做界面与编排。</summary>
public partial class App : Application
{
    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var window = new MainWindow();
        window.Activate();
    }
}
