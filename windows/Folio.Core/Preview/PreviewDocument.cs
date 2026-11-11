namespace Folio.Core.Preview;

[Flags]
public enum TextStyle { None = 0, Bold = 1, Italic = 2, Code = 4, Strike = 8, Marker = 16 }

public enum SpanKind
{
    Text,
    /// <summary>A line break inside a block (a hard break, a line of code): "\n" in the text.</summary>
    Break,
    /// <summary>A picture, or the diagram of a block: one object replacement character in the text.</summary>
    Picture,
}

/// <summary>A piece of the rendered text: what is shown from <c>Start</c> on, and how. Offsets are into
/// <see cref="PreviewDocument.Text"/>, in UTF-16 units like everything else.</summary>
public sealed record PreviewSpan(int Start, string Text, SpanKind Kind, TextStyle Style, string? Link = null, string? Picture = null)
{
    public int End => Start + Text.Length;
}

public enum BlockKind { Paragraph, Heading, Code, Rule, Diagram, Table, Frontmatter }

public enum Alignment { Left, Center, Right }

/// <summary>A block of the preview. Tables and the frontmatter have rows of cells, everything else spans.</summary>
public sealed class PreviewBlock
{
    public BlockKind Kind { get; init; }
    /// <summary>The heading's level, 1 to 6.</summary>
    public int Level { get; init; }
    /// <summary>How many lists it is in.</summary>
    public int Indent { get; init; }
    /// <summary>How many block quotes it is in.</summary>
    public int Quote { get; init; }
    /// <summary>A picture alone in its paragraph, shown in the middle.</summary>
    public bool Centered { get; init; }
    /// <summary>A code block's language, as its fence says.</summary>
    public string? Language { get; init; }
    /// <summary>A diagram's source (mermaid).</summary>
    public string? Diagram { get; init; }
    /// <summary>The code of a code block, as it is shown.</summary>
    public string? Code { get; init; }
    public List<PreviewSpan> Spans { get; } = [];
    public List<List<List<PreviewSpan>>> Rows { get; } = [];
    /// <summary>Whether a table's first row is its header.</summary>
    public bool Header { get; init; }
    public List<Alignment> Alignments { get; } = [];

    public IEnumerable<PreviewSpan> AllSpans => Spans.Concat(Rows.SelectMany(r => r.SelectMany(c => c)));
}

/// <summary>The rendered markdown: its blocks, the text they show, and the map between that text and the
/// file. What is anchored or selected goes through the map, so the rules of what is rendered text stay in
/// the engine, which works on the markdown itself.</summary>
public sealed class PreviewDocument(string text, List<PreviewBlock> blocks, PreviewMap map)
{
    /// <summary>Everything shown, with a "\n" after each block (and each cell), which no span holds.</summary>
    public string Text { get; } = text;
    public List<PreviewBlock> Blocks { get; } = blocks;
    public PreviewMap Map { get; } = map;

    public IEnumerable<PreviewSpan> Spans => Blocks.SelectMany(b => b.AllSpans);
}

/// <summary>Where the shown characters came from in the file. A linear segment holds the same text in both,
/// so a position inside it is one to one; any other (an entity, a soft break written "\r\n", a picture, a
/// rule) is mapped as a whole. Text only in the rendering (bullets, line breaks between blocks) has none.</summary>
public sealed class PreviewMap(List<PreviewMap.Segment> segments)
{
    public readonly record struct Segment(int Display, int Length, int Source, int SourceLength, bool Linear)
    {
        public int DisplayEnd => Display + Length;
        public int SourceEnd => Source + SourceLength;
    }

    /// <summary>In display order, which is also file order.</summary>
    public IReadOnlyList<Segment> Segments { get; } = segments;

    /// <summary>The shown range of the file's <paramref name="from"/>..<paramref name="to"/>, or null when none of it is shown.</summary>
    public (int From, int To)? DisplayRange(int from, int to)
    {
        if (DisplayLocation(from, end: false) is not int start || DisplayLocation(to, end: true) is not int stop || stop <= start) return null;
        return (start, stop);
    }

    /// <summary>Where the file's offset is shown. A range's start snaps forward to the next shown character,
    /// its end (and a point, such as an insertion) back to the previous one.</summary>
    public int? DisplayLocation(int offset, bool end)
    {
        if (Segments.Count == 0) return null;
        if (end)
        {
            var before = Segments.LastOrDefault(s => s.Source < offset);
            if (before == default) return Segments[0].Display;
            if (offset >= before.SourceEnd) return before.DisplayEnd;
            return before.Linear ? before.Display + offset - before.Source : before.DisplayEnd;
        }
        var after = Segments.FirstOrDefault(s => s.SourceEnd > offset);
        if (after == default) return Segments[^1].DisplayEnd;
        if (offset <= after.Source || !after.Linear) return after.Display;
        return after.Display + offset - after.Source;
    }

    /// <summary>The file's range for a shown one, or null when it holds nothing from the file (a bullet, say).</summary>
    public (int From, int To)? SourceRange(int from, int to)
    {
        var first = Segments.FirstOrDefault(s => s.DisplayEnd > from);
        var last = Segments.LastOrDefault(s => s.Display < to);
        if (first == default || last == default) return null;
        var start = from <= first.Display || !first.Linear ? first.Source : first.Source + from - first.Display;
        var stop = to >= last.DisplayEnd || !last.Linear ? last.SourceEnd : last.Source + to - last.Display;
        return stop > start ? (start, stop) : null;
    }
}
