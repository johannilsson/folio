using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Folio.Core;

public sealed class EngineException(string message) : Exception(message);

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
