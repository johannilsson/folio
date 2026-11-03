using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Folio.Core;

public sealed class EngineException(string message) : Exception(message);

/// <summary>What to run or paste to register this program's MCP server in a tool; <c>Client</c> and <c>Config</c> are
/// set when Folio can write it into the tool's config itself (Add for Me).</summary>
public sealed record McpSnippet(string Name, string Hint, string Text, string? Client, string? Config);

/// <summary>The engine as .NET calls: anchoring, accept and the editor's actions. Strings in, strings out,
/// like <c>Rust.swift</c>; nothing here touches a file.</summary>
public static class Engine
{
    /// <summary>The sidecar of an empty review, what a file without one has.</summary>
    public const string EmptySidecar = "{\"version\":1,\"annotations\":[]}";

    /// <summary>Where <paramref name="file"/>'s sidecar lives: the same rule as the CLI and the macOS app.</summary>
    public static string SidecarPath(string file) => Take(Native.folio_sidecar_path(file));

    /// <summary>Where each item sits in the markdown <paramref name="doc"/>, as UTF-16 offsets (what a .NET
    /// string indexes by). An item that cannot be found is left out.</summary>
    public static List<(string Id, int From, int To)> Anchor(string doc, IEnumerable<(string Id, string ContextBefore, string? Target)> items)
    {
        var request = new JsonArray(items.Select(i => (JsonNode)new JsonObject
        {
            ["id"] = i.Id,
            ["context_before"] = i.ContextBefore,
            ["target"] = i.Target,
        }).ToArray());
        var results = JsonNode.Parse(Take(Native.folio_anchor(doc, request.ToJsonString(), raw: true)))!.AsArray();
        return results.Where(r => r!["char_from"] is not null && r["char_to"] is not null)
            .Select(r => (r!["id"]!.GetValue<string>(), r["char_from"]!.GetValue<int>(), r["char_to"]!.GetValue<int>())).ToList();
    }

    /// <summary>Applies one annotation to the markdown: the patched markdown (null when accepting changes
    /// nothing in it) and the new sidecar.</summary>
    public static (string? Doc, string Sidecar) Accept(string doc, string sidecar, string id)
    {
        var result = JsonNode.Parse(Take(Native.folio_accept(doc, sidecar, id)))!;
        return (result["doc"]?.GetValue<string>(), result["sidecar"]!.GetValue<string>());
    }

    /// <summary>Applies one editor action (src/edit.rs) to the sidecar: the new sidecar and the id of what
    /// the action created.</summary>
    public static (string Sidecar, string? Id) Edit(string sidecar, JsonObject edit)
    {
        var result = JsonNode.Parse(Take(Native.folio_edit(sidecar, edit.ToJsonString())))!;
        return (result["sidecar"]!.GetValue<string>(), result["id"]?.GetValue<string>());
    }

    /// <summary>The words a selection of the markdown (UTF-16 offsets) is anchored by, as rendered text, which is
    /// what a new comment stores; null when none of it is rendered text (only markup, or code in a fence).</summary>
    public static (string Target, string ContextBefore)? RenderedSelection(string doc, int from, int to)
    {
        var result = JsonNode.Parse(Take(Native.folio_rendered_selection(doc, (nuint)from, (nuint)to)))!;
        return result["target"] is JsonValue target
            ? (target.GetValue<string>(), result["context_before"]!.GetValue<string>())
            : null;
    }

    /// <summary>The names of the sets (<c>folio set</c>), sorted.</summary>
    public static List<string> SetNames() =>
        JsonNode.Parse(Take(Native.folio_set_names()))!["names"]!.AsArray().Select(n => n!.GetValue<string>()).ToList();

    /// <summary>A set's files, as the CLI and the macOS app see them.</summary>
    public static FolioSet SetLoad(string name)
    {
        var result = JsonNode.Parse(Take(Native.folio_set_load(name)))!;
        var files = result["files"]!.AsArray().Select(f => new SetFile(
            f!["id"]!.GetValue<string>(), f["name"]!.GetValue<string>(), f["group"]!.GetValue<string>(),
            f["path"]!.GetValue<string>(), f["folio_path"]!.GetValue<string>())).ToList();
        return new FolioSet(result["name"]!.GetValue<string>(), result["manifest"]!.GetValue<string>(), files);
    }

    /// <summary>Runs the MCP server on stdin and stdout until the client closes them (<c>Folio.Wpf.exe --mcp</c>). The exit code.</summary>
    public static int McpServe() => Native.folio_mcp_serve();

    /// <summary>Whether the person lets MCP clients in: off until they turn on Allow MCP Clients. While it is off every
    /// tool of the server answers that access is off.</summary>
    public static bool McpAllowed => Native.folio_mcp_allowed();

    /// <summary>Lets MCP clients in, or shuts them out again.</summary>
    public static void SetMcpAllowed(bool on) => Take(Native.folio_mcp_set_allowed(on));

    /// <summary>What to run or paste to register <c>exe --mcp</c> in each tool.</summary>
    public static List<McpSnippet> McpSnippets(string exe) =>
        JsonNode.Parse(Take(Native.folio_mcp_snippets(exe)))!["snippets"]!.AsArray().Select(s => new McpSnippet(
            s!["name"]!.GetValue<string>(), s["hint"]!.GetValue<string>(), s["text"]!.GetValue<string>(),
            s["client"]?.GetValue<string>(), s["config"]?.GetValue<string>())).ToList();

    /// <summary>Add for Me: registers <c>exe --mcp</c> as the "folio" server in a tool's config (<c>client</c> from its
    /// snippet). The file it wrote, and "added", "updated" or "unchanged".</summary>
    public static (string Config, string Change) McpConnect(string client, string exe)
    {
        var result = JsonNode.Parse(Take(Native.folio_mcp_connect(client, exe)))!;
        return (result["config"]!.GetValue<string>(), result["change"]!.GetValue<string>());
    }

    /// <summary>Kept alive while the library may call it.</summary>
    static Native.AppHandler? listening;

    /// <summary>Starts answering the MCP server's questions about the running app on the socket in the config folder
    /// (src/live.rs): <paramref name="answer"/> gets each request line and returns the answer line, on a thread of the
    /// library's. Fails when another Folio already answers.</summary>
    public static unsafe void AppListen(Func<string, string> answer)
    {
        Native.AppHandler handler = request =>
        {
            var bytes = Encoding.UTF8.GetBytes(answer(Marshal.PtrToStringUTF8(request) ?? ""));
            // NativeMemory.Alloc is the C runtime's malloc, which the library's free matches.
            var copy = (byte*)NativeMemory.Alloc((nuint)bytes.Length + 1);
            bytes.CopyTo(new Span<byte>(copy, bytes.Length));
            copy[bytes.Length] = 0;
            return (IntPtr)copy;
        };
        Take(Native.folio_app_listen(handler));
        listening = handler;
    }

    /// <summary>Takes the socket away: access was turned off, or the app is quitting.</summary>
    public static void AppStop()
    {
        Native.folio_app_stop();
        listening = null;
    }

    /// <summary>Copies the result out, frees it, and turns <c>{"error": ...}</c> into an exception.</summary>
    static string Take(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero) throw new EngineException("the engine returned null");
        try
        {
            var text = Marshal.PtrToStringUTF8(ptr) ?? "";
            if (text.StartsWith("{\"error\"", StringComparison.Ordinal)
                && JsonNode.Parse(text) is JsonObject { Count: 1 } obj && obj["error"] is JsonValue message)
                throw new EngineException(message.GetValue<string>());
            return text;
        }
        finally { Native.folio_free(ptr); }
    }
}
