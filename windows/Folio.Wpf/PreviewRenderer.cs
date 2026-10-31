using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Folio.Core.Preview;
using WpfTable = System.Windows.Documents.Table;

namespace Folio.Wpf;

/// <summary>The looks of the preview and of the marks: Folio's purple is for content (annotations, selection).</summary>
static class Look
{
    public static readonly Brush Purple = Frozen(Color.FromArgb(0x55, 0xA7, 0x8B, 0xFA));
    public static readonly Brush PurpleStrong = Frozen(Color.FromArgb(0x99, 0xA7, 0x8B, 0xFA));
    public static readonly Brush Red = Frozen(Color.FromArgb(0x40, 0xEF, 0x44, 0x44));
    public static readonly Brush RedStrong = Frozen(Color.FromArgb(0x80, 0xEF, 0x44, 0x44));
    public static readonly Brush Green = Frozen(Color.FromRgb(0x16, 0xA3, 0x4A));
    public static readonly Brush GreenBack = Frozen(Color.FromArgb(0x26, 0x16, 0xA3, 0x4A));
    public static readonly Brush CodeBack = Frozen(Color.FromArgb(0x10, 0, 0, 0));
    public static readonly Brush Box = Frozen(Color.FromArgb(0x0C, 0, 0, 0));
    public static readonly Brush Line = Frozen(Color.FromArgb(0x30, 0, 0, 0));
    public static readonly Brush Secondary = Frozen(Color.FromRgb(0x6B, 0x6B, 0x70));
    public static readonly FontFamily Mono = new("Cascadia Mono, Consolas, Courier New");
    public const double BodySize = 15;
    static readonly double[] HeadingSizes = [28, 23, 19, 17, 15, 14];

    public static double HeadingSize(int level) => HeadingSizes[Math.Clamp(level, 1, 6) - 1];

    static Brush Frozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}

/// <summary>A FlowDocument drawn from a preview, and where each shown offset is in it. The document is built once
/// with the marks in it (each mark is a run of its own), and never changed after, so the elements stay where they
/// were put.</summary>
sealed class RenderedPreview
{
    /// <summary>A piece of the shown text and the element that draws it: a run for text, the element itself for a
    /// line break or a picture.</summary>
    public readonly record struct Entry(Piece Piece, TextElement Element, bool IsRun);

    public FlowDocument Document { get; }
    public IReadOnlyList<Entry> Entries => entries;
    /// <summary>The previews of suggestions, by annotation id: in the view, not in the text.</summary>
    public Dictionary<string, Run> Ghosts { get; } = [];

    readonly List<Entry> entries = [];
    readonly IReadOnlyList<Shown> shown;
    readonly string? focused;
    /// <summary>The diagrams drawn so far, by their source.</summary>
    readonly IReadOnlyDictionary<string, Diagram?> diagrams;
    /// <summary>Set while the lines of a code block are drawn.</summary>
    bool codeBlock;

    public RenderedPreview(PreviewDocument preview, IReadOnlyList<Shown> shown, string? focused, IReadOnlyDictionary<string, Diagram?> diagrams)
    {
        this.shown = shown;
        this.focused = focused;
        this.diagrams = diagrams;
        Document = new FlowDocument
        {
            PagePadding = new Thickness(32, 24, 32, 48),
            FontSize = Look.BodySize,
            FontFamily = new FontFamily("Segoe UI"),
            LineHeight = Look.BodySize * 1.5,
        };
        foreach (var block in preview.Blocks) Document.Blocks.Add(BlockOf(block));
    }

    // ---- offsets and pointers

    /// <summary>Where shown offset <paramref name="offset"/> is in the document. At the end of one piece and the start of
    /// the next, <paramref name="forward"/> picks the next.</summary>
    public TextPointer? Pointer(int offset, bool forward)
    {
        Entry? previous = null;
        foreach (var entry in entries)
        {
            // Between blocks: the start of the next piece, or the end of the one before.
            if (entry.Piece.Start > offset)
                return forward || previous is null ? At(entry, entry.Piece.Start) : At(previous.Value, previous.Value.Piece.End);
            if (forward ? offset < entry.Piece.End : offset <= entry.Piece.End) return At(entry, offset);
            previous = entry;
        }
        return previous is Entry last ? At(last, last.Piece.End) : null;
    }

    static TextPointer At(Entry entry, int offset)
    {
        if (entry.IsRun) return ((Run)entry.Element).ContentStart.GetPositionAtOffset(Math.Clamp(offset - entry.Piece.Start, 0, entry.Piece.Text.Length))!;
        return offset <= entry.Piece.Start ? entry.Element.ElementStart : entry.Element.ElementEnd;
    }

    /// <summary>The shown offset of a position in the document: inside a run, counted; anywhere else, the start of
    /// the next piece (the end of the text after the last).</summary>
    public int Offset(TextPointer pointer)
    {
        foreach (var entry in entries)
        {
            var element = entry.Element;
            if (pointer.CompareTo(element.ElementEnd) > 0) continue;
            if (entry.IsRun && pointer.CompareTo(((Run)element).ContentStart) >= 0)
                return entry.Piece.Start + Math.Min(((Run)element).ContentStart.GetOffsetToPosition(pointer), entry.Piece.Text.Length);
            return pointer.CompareTo(element.ElementEnd) == 0 ? entry.Piece.End : entry.Piece.Start;
        }
        return entries.Count > 0 ? entries[^1].Piece.End : 0;
    }

    // ---- blocks

    Block BlockOf(PreviewBlock block)
    {
        var indent = 24.0 * block.Indent + 18 * block.Quote;
        Block result = block.Kind switch
        {
            BlockKind.Table => TableOf(block, header: block.Header),
            BlockKind.Frontmatter => FrontmatterOf(block),
            _ => ParagraphOf(block),
        };
        result.Margin = new Thickness(result.Margin.Left + indent, result.Margin.Top, result.Margin.Right, result.Margin.Bottom);
        if (block.Quote > 0)
        {
            result.BorderBrush = Look.Line;
            result.BorderThickness = new Thickness(3, 0, 0, 0);
            result.Padding = new Thickness(12, result.Padding.Top, result.Padding.Right, result.Padding.Bottom);
            result.Foreground = Look.Secondary;
        }
        return result;
    }

    Paragraph ParagraphOf(PreviewBlock block)
    {
        var paragraph = new Paragraph { Margin = new Thickness(0, 0, 0, block.Indent > 0 ? 4 : 12) };
        switch (block.Kind)
        {
            case BlockKind.Heading:
                paragraph.FontSize = Look.HeadingSize(block.Level);
                paragraph.FontWeight = block.Level <= 2 ? FontWeights.SemiBold : FontWeights.Medium;
                paragraph.Margin = new Thickness(0, block.Level <= 2 ? 18 : 12, 0, 8);
                paragraph.LineHeight = double.NaN;
                break;
            case BlockKind.Code:
                paragraph.FontFamily = Look.Mono;
                paragraph.FontSize = Look.BodySize * 0.88;
                paragraph.Background = Look.CodeBack;
                paragraph.Padding = new Thickness(12, 10, 12, 10);
                paragraph.Margin = new Thickness(0, 4, 0, 16);
                paragraph.LineHeight = Look.BodySize * 1.3;
                break;
            case BlockKind.Rule:
                paragraph.BorderBrush = Look.Line;
                paragraph.BorderThickness = new Thickness(0, 0, 0, 1);
                paragraph.FontSize = 4;
                paragraph.LineHeight = double.NaN;
                paragraph.Margin = new Thickness(0, 8, 0, 20);
                break;
            case BlockKind.Diagram when Drawn(block) is not null:
                paragraph.Margin = new Thickness(0, 8, 0, 20);
                paragraph.LineHeight = double.NaN;
                break;
            case BlockKind.Diagram:
                // Not drawn (yet, or ever): its source.
                paragraph.FontFamily = Look.Mono;
                paragraph.FontSize = Look.BodySize * 0.88;
                paragraph.Background = Look.CodeBack;
                paragraph.Padding = new Thickness(12, 10, 12, 10);
                break;
        }
        // A list item's marker hangs to the left of its text.
        if (block.Spans.FirstOrDefault()?.Style.HasFlag(TextStyle.Marker) == true)
            paragraph.TextIndent = -20;
        if (block.Centered) paragraph.TextAlignment = TextAlignment.Center;
        codeBlock = block.Kind == BlockKind.Code;
        Inlines(paragraph.Inlines, block.Spans, block.Kind == BlockKind.Diagram ? block.Diagram : null);
        codeBlock = false;
        return paragraph;
    }

    WpfTable TableOf(PreviewBlock block, bool header)
    {
        var table = new WpfTable { CellSpacing = 0, BorderBrush = Look.Line, BorderThickness = new Thickness(0.5), Margin = new Thickness(0, 4, 0, 16) };
        var columns = block.Rows.Select(r => r.Count).DefaultIfEmpty(0).Max();
        for (var c = 0; c < columns; c++) table.Columns.Add(new TableColumn());
        var group = new TableRowGroup();
        for (var r = 0; r < block.Rows.Count; r++)
        {
            var row = new TableRow();
            if (r == 0 && header) row.Background = Look.Box;
            for (var c = 0; c < columns; c++)
            {
                var paragraph = new Paragraph { Margin = new Thickness(0) };
                if (c < block.Alignments.Count)
                    paragraph.TextAlignment = block.Alignments[c] switch { Alignment.Center => TextAlignment.Center, Alignment.Right => TextAlignment.Right, _ => TextAlignment.Left };
                if (c < block.Rows[r].Count) Inlines(paragraph.Inlines, block.Rows[r][c], null);
                row.Cells.Add(new TableCell(paragraph) { BorderBrush = Look.Line, BorderThickness = new Thickness(0.5), Padding = new Thickness(8, 4, 8, 4) });
            }
            group.Rows.Add(row);
        }
        table.RowGroups.Add(group);
        return table;
    }

    /// <summary>The frontmatter as a box of keys and values.</summary>
    WpfTable FrontmatterOf(PreviewBlock block)
    {
        var table = TableOf(block, header: false);
        table.BorderThickness = new Thickness(0);
        table.Background = Look.Box;
        table.FontSize = 12.5;
        table.Margin = new Thickness(0, 0, 0, 24);
        if (table.Columns.Count > 0) table.Columns[0].Width = new GridLength(140);
        foreach (var row in table.RowGroups[0].Rows)
            for (var c = 0; c < row.Cells.Count; c++)
            {
                row.Cells[c].BorderThickness = new Thickness(0);
                if (c == 0) row.Cells[c].Foreground = Look.Secondary;
            }
        return table;
    }

    // ---- inlines

    void Inlines(InlineCollection into, IEnumerable<PreviewSpan> spans, string? diagram)
    {
        foreach (var span in spans)
            foreach (var piece in PreviewMarks.Cut(span, shown))
            {
                if (piece.Ghost is string id)
                {
                    var ghost = new Run(piece.Text) { Foreground = Look.Green, Background = Look.GreenBack };
                    Ghosts[id] = ghost;
                    into.Add(ghost);
                    continue;
                }
                Inline element = span.Kind switch
                {
                    SpanKind.Break => new LineBreak(),
                    SpanKind.Picture when diagram is not null && diagrams.GetValueOrDefault(diagram) is Diagram drawn => DiagramOf(drawn),
                    SpanKind.Picture when diagram is not null => Styled(new Run(diagram), span, piece),
                    SpanKind.Picture => Picture(span.Picture),
                    _ => Styled(new Run(piece.Text), span, piece),
                };
                into.Add(element);
                entries.Add(new Entry(piece, element, span.Kind == SpanKind.Text));
            }
    }

    Inline Styled(Inline run, PreviewSpan span, Piece piece)
    {
        if (span.Style.HasFlag(TextStyle.Bold)) run.FontWeight = FontWeights.Bold;
        if (span.Style.HasFlag(TextStyle.Italic)) run.FontStyle = FontStyles.Italic;
        if (span.Style.HasFlag(TextStyle.Code))
        {
            run.FontFamily = Look.Mono;
            run.FontSize = Look.BodySize * 0.88;
            // Code inline has a background of its own; a code block's lines have the block's.
            if (span.Kind == SpanKind.Text && piece.Marks.Count == 0 && !codeBlock) run.Background = Look.CodeBack;
        }
        if (span.Style.HasFlag(TextStyle.Strike)) run.TextDecorations = TextDecorations.Strikethrough;
        if (span.Style.HasFlag(TextStyle.Marker)) run.Foreground = Look.Secondary;
        if (span.Link is not null)
        {
            run.Foreground = SystemColors.HotTrackBrush;
            run.TextDecorations = TextDecorations.Underline;
            run.ToolTip = span.Link;
        }
        if (piece.Marks.Count > 0) Mark(run, shown.First(s => s.Annotation.Id == piece.Marks[0]));
        return run;
    }

    /// <summary>A suggestion to take text out is red and struck through; a highlight or a comment purple.</summary>
    void Mark(Inline run, Shown annotation)
    {
        var strong = annotation.Annotation.Id == focused;
        if (annotation.Annotation.Kind is "replace" or "delete")
        {
            run.Background = strong ? Look.RedStrong : Look.Red;
            run.TextDecorations = TextDecorations.Strikethrough;
        }
        else
        {
            run.Background = strong ? Look.PurpleStrong : Look.Purple;
        }
    }

    Diagram? Drawn(PreviewBlock block) => block.Diagram is string code ? diagrams.GetValueOrDefault(code) : null;

    /// <summary>A drawn diagram at its size, smaller when the column is narrower.</summary>
    static Inline DiagramOf(Diagram diagram) =>
        new InlineUIContainer(new Image
        {
            Source = diagram.Picture, Width = diagram.Width, MaxWidth = 760,
            Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly,
        }) { BaselineAlignment = BaselineAlignment.Bottom };

    static Inline Picture(string? path)
    {
        UIElement child;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.UriSource = path!.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? new Uri(path) : new Uri(Path.GetFullPath(path));
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            child = new Image { Source = image, MaxWidth = 700, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly };
        }
        catch (Exception e) when (e is IOException or UriFormatException or NotSupportedException or ArgumentException or UnauthorizedAccessException or InvalidOperationException)
        {
            child = new TextBlock { Text = $"[{Path.GetFileName(path)}]", Foreground = Look.Secondary };
        }
        return new InlineUIContainer(child) { BaselineAlignment = BaselineAlignment.Bottom };
    }
}
