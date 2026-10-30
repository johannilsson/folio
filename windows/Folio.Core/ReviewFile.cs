using System.Text;
using System.Text.Json.Nodes;

namespace Folio.Core;

/// <summary>A markdown file and its sidecar on disk, which is the truth: every action reads what is there,
/// has the engine change it and writes it back, so what an agent wrote in the meantime survives.</summary>
public sealed class ReviewFile
{
    static readonly UTF8Encoding Utf8 = new(encoderShouldEmitUTF8Identifier: false);

    public string Path { get; }
    public string SidecarPath { get; }

    public ReviewFile(string path)
    {
        Path = System.IO.Path.GetFullPath(path);
        SidecarPath = Engine.SidecarPath(Path);
    }

    public string ReadText() => File.ReadAllText(Path, Utf8);

    /// <summary>The sidecar's text, or the empty review when there is none yet.</summary>
    public string ReadSidecar() => File.Exists(SidecarPath) ? File.ReadAllText(SidecarPath, Utf8) : Engine.EmptySidecar;

    /// <summary>Changes whenever the file or its sidecar does; polled, as an atomic save swaps the file under a watcher.</summary>
    public string Stamp() => $"{Stamp(Path)}|{Stamp(SidecarPath)}";

    /// <summary>Applies one annotation to the markdown and marks it resolved, as <c>folio accept</c> does: the
    /// patched file and the sidecar are written, in that order.</summary>
    public void Accept(string id)
    {
        var (doc, sidecar) = Engine.Accept(ReadText(), ReadSidecar(), id);
        if (doc is not null) File.WriteAllText(Path, doc, Utf8);
        WriteSidecar(sidecar);
    }

    /// <summary>Rejects a suggestion or dismisses a comment: it stays in the sidecar, resolved.</summary>
    public void Reject(string id) =>
        WriteSidecar(Engine.Edit(ReadSidecar(), new JsonObject { ["op"] = "resolve", ["id"] = id }).Sidecar);

    /// <summary>Atomic (temp file, then rename), like <c>Sidecar::save</c>, so nobody reads half a sidecar.</summary>
    void WriteSidecar(string body)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(SidecarPath)!);
        var temp = SidecarPath + ".tmp";
        File.WriteAllText(temp, body, Utf8);
        File.Move(temp, SidecarPath, overwrite: true);
    }

    static string Stamp(string path) =>
        File.Exists(path) ? $"{File.GetLastWriteTimeUtc(path).Ticks}:{new FileInfo(path).Length}" : "-";
}
