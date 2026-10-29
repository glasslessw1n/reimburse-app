using Microsoft.UI.Xaml;

namespace Reimbursement.App;

/// <summary>WinUI 3 壳入口（非打包部署）。业务逻辑全部在 Core，本层只做界面与编排。</summary>
public partial class App : Application
{
    public App()
    {
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
        }
        catch (Exception ex)
        {
            CrashLog.WriteException("OnLaunched", ex);
            throw;
        }
    }
}
