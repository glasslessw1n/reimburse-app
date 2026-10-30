using Microsoft.UI.Xaml;
using Velopack;

namespace Reimbursement.App;

/// <summary>WinUI 3 壳入口（非打包部署）。业务逻辑全部在 Core，本层只做界面与编排。</summary>
public partial class App : Application
{
    public App()
    {
        // Velopack 必须在任何窗口创建之前接管安装/更新生命周期事件
        // （从安装包启动的首次运行、更新后重启都走这里；便携 zip 运行时它自动无操作）。
        VelopackApp.Build().Run();
        CrashLog.Write("App ctor start");
        UnhandledException += (_, e) =>
        {
            CrashLog.WriteException("App.UnhandledException", e.Exception);
        };
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            if (e.ExceptionObject is Exception ex)
                CrashLog.WriteException("AppDomain.UnhandledException", ex);
        };
        InitializeComponent();
        CrashLog.Write("App ctor done");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        CrashLog.Write("OnLaunched start");
        try
        {
            var window = new MainWindow();
            CrashLog.Write("MainWindow created");
            window.Activate();
            CrashLog.Write("MainWindow activated");
            _ = window.CheckForAppUpdateAsync(); // 后台静默查更新，不阻塞启动
        }
        catch (Exception ex)
        {
            CrashLog.WriteException("OnLaunched", ex);
            throw;
        }
    }
}
