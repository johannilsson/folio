namespace Folio.Core.Preview;

/// <summary>An annotation as the preview shows it: what is marked (shown offsets), where its card points, and the
/// text a suggestion would put in. A point (an insertion, a comment without a target) marks nothing.</summary>
public sealed record Shown(Placed Placed, int? From, int? To, int? At, string? Ghost)
{
    public Annotation Annotation => Placed.Annotation;
    public bool Marked => From is not null;
}

/// <summary>A piece of a span with one look: the marks over it, or the preview of a suggestion (<c>Ghost</c>),
/// which is in the view but not in the text, so it takes up no offsets.</summary>
public sealed record Piece(int Start, string Text, IReadOnlyList<string> Marks, string? Ghost = null)
{
    public int End => Ghost is null ? Start + Text.Length : Start;
}

public static class PreviewMarks
{
    /// <summary>Where each placed annotation is in <paramref name="preview"/>; found in the file but not shown
    /// (inside code that is drawn as a diagram, say) is still found, with no mark.</summary>
    public static List<Shown> Show(PreviewDocument preview, IEnumerable<Placed> placed) =>
        placed.Select(p =>
        {
            if (!p.Found) return new Shown(p, null, null, null, null);
            var range = p.To > p.From ? preview.Map.DisplayRange(p.From!.Value, p.To!.Value) : null;
            var at = range?.To ?? preview.Map.DisplayLocation(p.From!.Value, end: true);
            var ghost = p.Annotation.Kind is "replace" or "insert" && !string.IsNullOrEmpty(p.Annotation.Replacement) ? p.Annotation.Replacement : null;
            return new Shown(p, range?.From, range?.To, range?.From ?? at, ghost);
        }).ToList();

    /// <summary>Where a suggestion's preview goes: after what it replaces, or at the insertion point.</summary>
    public static int? GhostAt(Shown shown) => shown.Ghost is null ? null : shown.To ?? shown.At;

    /// <summary>Cuts <paramref name="span"/> where marks start and end, and puts the previews of suggestions in at their
    /// places. A picture or a line break is not cut. A preview at a span's end belongs to that span, so it follows
    /// the text it is about; one at the very start of the text, to the first span.</summary>
    public static List<Piece> Cut(PreviewSpan span, IReadOnlyList<Shown> shown)
    {
        var marks = shown.Where(s => s.From < span.End && s.To > span.Start).ToList();
        var ghosts = shown.Select(s => (Shown: s, At: GhostAt(s)))
            .Where(g => g.At is int at && (at > span.Start && at <= span.End || at == 0 && span.Start == 0))
            .ToList();
        var cuts = new SortedSet<int> { span.Start, span.End };
        if (span.Kind == SpanKind.Text)
            foreach (var at in marks.SelectMany(m => new[] { m.From!.Value, m.To!.Value }).Concat(ghosts.Select(g => g.At!.Value)))
                if (at > span.Start && at < span.End) cuts.Add(at);

        var pieces = new List<Piece>();
        void Ghosts(int at)
        {
            foreach (var (s, _) in ghosts.Where(g => g.At == at))
                pieces.Add(new Piece(at, s.Ghost!, [], s.Annotation.Id));
        }
        if (span.Start == 0) Ghosts(0);
        var points = cuts.ToList();
        for (var i = 0; i + 1 < points.Count; i++)
        {
            var (a, b) = (points[i], points[i + 1]);
            var over = marks.Where(m => m.From < b && m.To > a)
                .OrderByDescending(m => m.From).Select(m => m.Annotation.Id).ToList();
            pieces.Add(new Piece(a, span.Text[(a - span.Start)..(b - span.Start)], over));
            if (b > 0) Ghosts(b);
        }
        return pieces;
    }
}
