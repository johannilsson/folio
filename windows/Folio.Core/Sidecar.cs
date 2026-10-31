using System.Text.Json;
using System.Text.Json.Serialization;

namespace Folio.Core;

public sealed record ThreadReply(string Id, string Author, string Source, string Body, string Created);

/// <summary>One annotation as the sidecar has it (folio-sidecar-spec.md, src/sidecar.rs). <c>Kind</c> and
/// <c>Source</c> stay strings, so a value this client does not know still loads.</summary>
public sealed record Annotation(
    string Id,
    string Kind,
    string Source,
    string Author,
    string ContextBefore,
    string? Target,
    string? Replacement,
    string? Comment,
    string Created,
    bool Resolved,
    string? ResolvedAs,
    string? ResolvedAt,
    List<ThreadReply>? Replies)
{
    public bool IsComment => Kind == "comment";

    /// <summary>The line a card shows: what changes to what.</summary>
    public string Summary => Kind switch
    {
        "replace" => $"\"{Shorten(Target)}\" → \"{Shorten(Replacement)}\"",
        "insert" => $"\"{Shorten(Replacement)}\"",
        "comment" => Shorten(Comment, 80),
        _ => $"\"{Shorten(Target)}\"",
    };

    static string Shorten(string? text, int limit = 60)
    {
        var flat = (text ?? "").Replace("\r", "").Replace("\n", " ");
        return flat.Length > limit ? flat[..limit] + "…" : flat;
    }
}

public static class Sidecar
{
    static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    /// <summary>The annotations of a sidecar's text, resolved ones included.</summary>
    public static List<Annotation> Parse(string json) =>
        JsonSerializer.Deserialize<Wire>(json, Options)?.Annotations ?? [];

    sealed record Wire([property: JsonPropertyName("annotations")] List<Annotation>? Annotations);
}
