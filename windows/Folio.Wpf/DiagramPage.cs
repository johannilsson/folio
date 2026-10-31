using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Folio.Wpf;

/// <summary>A drawn diagram: its picture, and its size on screen (the picture has twice the pixels).</summary>
sealed record Diagram(BitmapSource Picture, double Width, double Height);

/// <summary>Where the preview gets its mermaid diagrams and the colours of its code, like the macOS app's
/// <c>DiagramPage</c>: a hidden web view loads the diagram page (<c>frontend/src/diagram.ts</c>, built into
/// <c>frontend/</c> next to the app), draws a diagram, and a picture of it is the result; it also answers which parts of
/// a block of code are keywords, strings and so on. It lives in a window off every screen, which must never show. It
/// does one thing at a time; a page that does not load (no WebView2 runtime, no built frontend) draws no diagrams and
/// colours no code, and the preview keeps showing the diagrams' source and plain code.</summary>
sealed class DiagramPage(Window owner, string folder)
{
    readonly SemaphoreSlim one = new(1, 1);
    Window? host;
    WebView2? view;
    bool? loaded;

    /// <summary>The built page next to the app, or null when the frontend was not built.</summary>
    public static string? Find()
    {
        var folder = Path.Combine(AppContext.BaseDirectory, "frontend");
        return File.Exists(Path.Combine(folder, "diagram.html")) ? folder : null;
    }

    /// <summary>The diagram as a picture, or null when it does not draw.</summary>
    public async Task<Diagram?> Draw(string code)
    {
        await one.WaitAsync();
        try { return await Load() ? await DrawOne(code) : null; }
        catch (Exception e) when (e is COMException or InvalidOperationException or JsonException or FormatException or NotSupportedException)
        {
            Console.Error.WriteLine($"mermaid: {e.Message}");
            return null;
        }
        finally { one.Release(); }
    }

    /// <summary>The coloured pieces of <paramref name="code"/> in <paramref name="language"/>: offsets into the code and
    /// their highlight.js scope. Empty when the language is not known or the page does not answer.</summary>
    public async Task<List<(int From, int To, string Scope)>> Highlight(string code, string language)
    {
        await one.WaitAsync();
        try
        {
            if (!await Load()) return [];
            var script = "(async () => { for (let i = 0; i < 100 && !window.__folioHighlight; i++) await new Promise(r => setTimeout(r, 100));"
                         + $" return window.__folioHighlight({JsonSerializer.Serialize(code)}, {JsonSerializer.Serialize(language)}); }})()";
            var answer = JsonNode.Parse(await view!.CoreWebView2.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
                new JsonObject { ["expression"] = script, ["awaitPromise"] = true, ["returnByValue"] = true }.ToJsonString()))!;
            return answer["result"]?["value"] is JsonArray spans
                ? spans.OfType<JsonArray>().Where(s => s.Count == 3)
                    .Select(s => (s[0]!.GetValue<int>(), s[1]!.GetValue<int>(), s[2]!.GetValue<string>())).ToList()
                : [];
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or JsonException or FormatException)
        {
            Console.Error.WriteLine($"highlight: {e.Message}");
            return [];
        }
        finally { one.Release(); }
    }

    async Task<Diagram?> DrawOne(string code)
    {
        var core = view!.CoreWebView2;
        var script = "(async () => { for (let i = 0; i < 100 && !window.__folioMermaid; i++) await new Promise(r => setTimeout(r, 100));"
                     + $" return await window.__folioMermaid({JsonSerializer.Serialize(code)}, false); }})()";
        var answer = JsonNode.Parse(await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
            new JsonObject { ["expression"] = script, ["awaitPromise"] = true, ["returnByValue"] = true }.ToJsonString()))!;
        if (answer["exceptionDetails"] is not null || answer["result"]?["value"] is not JsonArray { Count: 2 } size)
        {
            Console.Error.WriteLine($"mermaid: no size for the diagram: {answer.ToJsonString()}");
            return null;
        }
        var (width, height) = (size[0]!.GetValue<double>(), size[1]!.GetValue<double>());
        if (width <= 0 || height <= 0) return null;
        // Twice the pixels for the same size on screen, so it stays sharp on a high-resolution display.
        var shot = JsonNode.Parse(await core.CallDevToolsProtocolMethodAsync("Page.captureScreenshot", new JsonObject
        {
            ["format"] = "png",
            ["captureBeyondViewport"] = true,
            ["clip"] = new JsonObject { ["x"] = 0, ["y"] = 0, ["width"] = width, ["height"] = height, ["scale"] = 2 },
        }.ToJsonString()))!;
        var picture = new BitmapImage();
        picture.BeginInit();
        picture.StreamSource = new MemoryStream(Convert.FromBase64String(shot["data"]!.GetValue<string>()));
        picture.CacheOption = BitmapCacheOption.OnLoad;
        picture.EndInit();
        picture.Freeze();
        return new Diagram(picture, width, height);
    }

    async Task<bool> Load()
    {
        if (loaded is bool done) return done;
        try
        {
            view = new WebView2();
            // Off every screen, never activated, not in the taskbar; owned by the window, so it closes with it.
            host = new Window
            {
                Owner = owner, Content = view, Width = 1400, Height = 1000, Left = -32000, Top = -32000,
                WindowStyle = WindowStyle.None, ResizeMode = ResizeMode.NoResize, ShowInTaskbar = false,
                ShowActivated = false, IsHitTestVisible = false, Focusable = false,
            };
            host.Show();
            var data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Folio", "WebView2");
            await view.EnsureCoreWebView2Async(await CoreWebView2Environment.CreateAsync(userDataFolder: data));
            view.CoreWebView2.SetVirtualHostNameToFolderMapping("folio.app", folder, CoreWebView2HostResourceAccessKind.DenyCors);
            var navigated = new TaskCompletionSource<bool>();
            view.CoreWebView2.NavigationCompleted += (_, e) => navigated.TrySetResult(e.IsSuccess);
            view.CoreWebView2.Navigate("https://folio.app/diagram.html");
            loaded = await navigated.Task;
        }
        catch (Exception e) when (e is WebView2RuntimeNotFoundException or COMException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            Console.Error.WriteLine($"mermaid: the diagram page did not load: {e.Message}");
            loaded = false;
        }
        if (loaded == false) host?.Close();
        return loaded!.Value;
    }
}
