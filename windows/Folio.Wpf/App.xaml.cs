using System.Windows;

namespace Folio.Wpf;

public partial class App : Application
{
    /// <summary><c>Folio.exe [file]</c>, or <c>Folio.exe --self-test &lt;result file&gt;</c> to drive the app and report.</summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow();
        window.Show();
        if (e.Args is ["--self-test", var result])
            _ = SelfTest.Run(window, result);
        else if (e.Args.Length > 0)
            window.Open(e.Args[0]);
    }
}
