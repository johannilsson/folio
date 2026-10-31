using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using Folio.Core;

namespace Folio.Wpf;

/// <summary>What the running app tells Folio's MCP server (src/mcp.rs), like the macOS app's <c>AppServer</c>: the windows
/// with the annotation the reader has focused (<c>state</c>), and <c>reveal</c>. The server is a separate process
/// (<c>Folio.Wpf.exe --mcp</c>); it connects to the socket in the config folder (src/live.rs), which the engine serves
/// on a thread of its own and which calls <see cref="Answer"/> once per request. The app answers only while MCP clients
/// are allowed. The process's one link, so a static at the edge, as <c>AppServer</c> is.</summary>
static class AppLink
{
    /// <summary>Whether this app owns the socket, and so has to take it away when it quits.</summary>
    public static bool Serving { get; private set; }

    /// <summary>Starts answering. False when another Folio already does.</summary>
    public static bool Start()
    {
        if (Serving) return true;
        try
        {
            Engine.AppListen(Answer);
            Serving = true;
        }
        catch (EngineException e) { Console.Error.WriteLine($"Folio: MCP clients cannot reach the app: {e.Message}"); }
        return Serving;
    }

    public static void Stop()
    {
        if (!Serving) return;
        Serving = false;
        Engine.AppStop();
    }

    /// <summary>The Allow box of the MCP… window: lets MCP clients in, or shuts them out again. The choice is kept in
    /// the config folder, where the server reads it at every tool call; the app answers it only while it is on.</summary>
    public static void Allow(bool on)
    {
        Engine.SetMcpAllowed(on);
        if (on) Start(); else Stop();
    }

    /// <summary>One request line, answered on the UI thread, which owns the windows.</summary>
    static string Answer(string line)
    {
        if (Application.Current?.Dispatcher is not { } dispatcher) return Reply(error: "the app is quitting");
        return dispatcher.Invoke(() =>
        {
            JsonObject? request = null;
            try { request = JsonNode.Parse(line) as JsonObject; } catch (JsonException) { }
            return request?["op"]?.GetValue<string>() switch
            {
                null => Reply(error: "not a request"),
                "state" => Reply(ok: new JsonObject { ["windows"] = new JsonArray([.. Windows().Select(w => (JsonNode)w.State(w == Front()))]) }),
                "reveal" => request["file"]?.GetValue<string>() is string file ? Reveal(file, request["id"]?.GetValue<string>()) : Reply(error: "`file` is required"),
                var op => Reply(error: $"unknown op {op}"),
            };
        });
    }

    static IEnumerable<MainWindow> Windows() => Application.Current.Windows.OfType<MainWindow>();

    /// <summary>The window the reader is in: the active one, or the first while the app is in the background.</summary>
    static MainWindow? Front() => Windows().FirstOrDefault(w => w.IsActive) ?? Windows().FirstOrDefault();

    /// <summary>Brings the file forward and focuses the annotation: in the window that shows it or whose set has it, else
    /// in a window of its own.</summary>
    static string Reveal(string file, string? id)
    {
        if (!File.Exists(file)) return Reply(error: $"no such file: {file}");
        var window = Windows().FirstOrDefault(w => w.Has(file));
        var opened = window is null;
        if (window is null)
        {
            window = new MainWindow();
            window.Show();
        }
        window.Reveal(file, id);
        return Reply(ok: new JsonObject { ["opened"] = opened });
    }

    static string Reply(JsonNode? ok = null, string? error = null) =>
        (error is null ? new JsonObject { ["ok"] = ok } : new JsonObject { ["error"] = error }).ToJsonString();
}
