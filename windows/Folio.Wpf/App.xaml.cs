using System.Windows;
using Folio.Core;

namespace Folio.Wpf;

public partial class App : Application
{
    /// <summary><c>Folio.Wpf.exe [file]</c>, <c>Folio.Wpf.exe --set &lt;name&gt;</c>,
    /// <c>Folio.Wpf.exe --self-test &lt;result file&gt;</c> to drive the app and report, or <c>Folio.Wpf.exe --mcp</c>: the
    /// MCP server a tool such as Claude Desktop starts, with no window and nothing on stdout but the protocol. Its tools
    /// answer that access is off until the person allows MCP clients (the MCP… button).</summary>
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args is ["--mcp"])
        {
            Shutdown(Engine.McpServe());
            return;
        }
        var window = new MainWindow();
        window.Show();
        // The MCP server asks this app what the reader has open, once MCP clients are allowed. The self-test turns it on itself.
        if (e.Args is not ["--self-test", _] && Engine.McpAllowed) AppLink.Start();
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

    protected override void OnExit(ExitEventArgs e)
    {
        AppLink.Stop();
        base.OnExit(e);
    }
}
