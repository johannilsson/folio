namespace Folio.Core;

/// <summary>An unresolved annotation and where it is in the markdown; no range when it cannot be found.</summary>
public sealed record Placed(Annotation Annotation, int? From, int? To)
{
    public bool Found => From is not null;
}

/// <summary>The rules of what a review shows, as functions of the markdown and the annotations.</summary>
public static class Review
{
    /// <summary>The unresolved annotations in document order; those not found in it come last, in sidecar order.</summary>
    public static List<Placed> Place(string doc, IEnumerable<Annotation> annotations)
    {
        var pending = annotations.Where(a => !a.Resolved).ToList();
        var found = Engine.Anchor(doc, pending.Select(a => (a.Id, a.ContextBefore, a.Target))).ToDictionary(r => r.Id);
        var placed = pending.Select(a => found.TryGetValue(a.Id, out var r) ? new Placed(a, r.From, r.To) : new Placed(a, null, null));
        return placed.Where(p => p.Found).OrderBy(p => p.From).ThenBy(p => p.To)
            .Concat(placed.Where(p => !p.Found)).ToList();
    }
}

/// <summary>Where the lines of a text are, for a view that shows one block per line. Offsets are UTF-16, as
/// the engine's are; the line break ("\n" or "\r\n") belongs to no line's text.</summary>
public static class Lines
{
    public readonly record struct Line(int Start, int Length);

    public static List<Line> Split(string text)
    {
        var lines = new List<Line>();
        var start = 0;
        while (true)
        {
            var end = text.IndexOf('\n', start);
            if (end < 0) { lines.Add(new Line(start, text.Length - start)); return lines; }
            lines.Add(new Line(start, end > start && text[end - 1] == '\r' ? end - 1 - start : end - start));
            start = end + 1;
        }
    }

    /// <summary>The line holding <paramref name="offset"/> and the column in it. An offset inside a line break is
    /// the end of its line.</summary>
    public static (int Line, int Column) Locate(IReadOnlyList<Line> lines, int offset)
    {
        var index = 0;
        for (var i = 0; i < lines.Count && lines[i].Start <= offset; i++) index = i;
        return (index, Math.Min(offset - lines[index].Start, lines[index].Length));
    }
}
