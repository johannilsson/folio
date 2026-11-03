using System.Text;
using System.Text.Json.Nodes;

namespace Folio.Core;

/// <summary>A markdown file and its sidecar on disk, which is the truth: every action reads what is there,
/// has the engine change it and writes it back, so what an agent wrote in the meantime survives.</summary>
public sealed class ReviewFile
{
    static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);
    static readonly byte[] Bom = [0xEF, 0xBB, 0xBF];

    /// <summary>Who the local reader is in the sidecar, as in the macOS app.</summary>
    const string LocalAuthor = "me", LocalSource = "local";

    public string Path { get; }
    public string SidecarPath { get; }

    public ReviewFile(string path)
    {
        Path = System.IO.Path.GetFullPath(path);
        SidecarPath = Engine.SidecarPath(Path);
    }

    /// <summary>The markdown, without a byte order mark (the engine's offsets do not count one).</summary>
    public string ReadText() => Read(Path);

    /// <summary>The sidecar's text, or the empty review when there is none yet.</summary>
    public string ReadSidecar() => File.Exists(SidecarPath) ? Read(SidecarPath) : Engine.EmptySidecar;

    /// <summary>Changes whenever the file or its sidecar does; polled, as an atomic save swaps the file under a watcher.</summary>
    public string Stamp() => $"{Stamp(Path)}|{Stamp(SidecarPath)}";

    /// <summary>Applies one annotation to the markdown and marks it resolved, as <c>folio accept</c> does: the
    /// patched file and the sidecar are written, in that order. A byte order mark the file had stays.</summary>
    public void Accept(string id)
    {
        var (doc, sidecar) = Engine.Accept(ReadText(), ReadSidecar(), id);
        if (doc is not null)
        {
            var bytes = Utf8.GetBytes(doc);
            WriteAtomic(Path, HasBom(Path) ? [.. Bom, .. bytes] : bytes);
        }
        WriteSidecar(sidecar);
    }

    /// <summary>Rejects a suggestion or dismisses a comment: it stays in the sidecar, resolved.</summary>
    public void Reject(string id) => Edit(new JsonObject { ["op"] = "resolve", ["id"] = id });

    /// <summary>A reply from the local reader on an annotation's thread.</summary>
    public string? Reply(string id, string body) =>
        Edit(new JsonObject { ["op"] = "reply", ["id"] = id, ["body"] = body, ["author"] = LocalAuthor, ["source"] = LocalSource });

    /// <summary>A new comment from the local reader on the markdown's <paramref name="from"/>..<paramref name="to"/>
    /// (UTF-16 offsets), anchored by its rendered words as an agent's is. Null when the range holds no rendered text.</summary>
    public string? AddComment(int from, int to, string comment)
    {
        if (Engine.RenderedSelection(ReadText(), from, to) is not var (target, context)) return null;
        return Edit(new JsonObject
        {
            ["op"] = "add_comment", ["context_before"] = context, ["target"] = target, ["comment"] = comment,
            ["author"] = LocalAuthor, ["source"] = LocalSource,
        });
    }

    string? Edit(JsonObject edit)
    {
        var (sidecar, id) = Engine.Edit(ReadSidecar(), edit);
        WriteSidecar(sidecar);
        return id;
    }

    void WriteSidecar(string body)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SidecarPath)!);
        WriteAtomic(SidecarPath, Utf8.GetBytes(body));
    }

    /// <summary>A temp file of its own, then a rename, so nobody reads half a file. The CLI's temp file is
    /// <c>&lt;file&gt;.tmp</c>; this one never has that name, so the two cannot write into each other's.</summary>
    static void WriteAtomic(string path, byte[] bytes)
    {
        var temp = $"{path}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllBytes(temp, bytes);
            File.Move(temp, path, overwrite: true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    /// <summary>Opened so that it never stands in the way of a writer: an agent renaming its new sidecar over
    /// this one while it is read would otherwise fail with "Access is denied" on Windows.</summary>
    static string Read(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Utf8, detectEncodingFromByteOrderMarks: true);
        return reader.ReadToEnd();
    }

    static bool HasBom(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        Span<byte> head = stackalloc byte[3];
        return stream.Read(head) == 3 && head.SequenceEqual(Bom);
    }

    static string Stamp(string path) =>
        File.Exists(path) ? $"{File.GetLastWriteTimeUtc(path).Ticks}:{new FileInfo(path).Length}" : "-";
}
