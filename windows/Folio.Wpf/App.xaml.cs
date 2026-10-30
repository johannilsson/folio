using System.Windows;

namespace Folio.Wpf;

public partial class App : Application
{
    /// <summary><c>Folio.Wpf.exe [file]</c>, <c>Folio.Wpf.exe --set &lt;name&gt;</c>, or
    /// <c>Folio.Wpf.exe --self-test &lt;result file&gt;</c> to drive the app and report.</summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var window = new MainWindow();
        window.Show();
        switch (e.Args)
        {
            case ["--self-test", var result]:
                _ = SelfTest.Run(window, result);
                break;
            case ["--set", var name]:
                window.OpenSet(name);
                break;
            case [var file, ..]:
                window.Open(file);
                break;
        }
    }
}
