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
