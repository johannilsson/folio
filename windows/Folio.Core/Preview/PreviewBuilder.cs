using System.Text;
using Markdig;
using Markdig.Extensions.Tables;
using Markdig.Extensions.TaskLists;
using Markdig.Extensions.Yaml;
using Markdig.Syntax;
using Markdig.Syntax.Inlines;
using MarkdigTable = Markdig.Extensions.Tables.Table;

namespace Folio.Core.Preview;

/// <summary>Turns markdown into the preview's blocks and the map of where its characters came from, like the
/// macOS app's <c>PreviewBuilder</c>. Blocks it does not draw (HTML) are shown as their markdown, so nothing in
/// the file is missing from the view.</summary>
public static class PreviewBuilder
{
    static readonly MarkdownPipeline Pipeline = new MarkdownPipelineBuilder()
        .UsePipeTables().UseEmphasisExtras(Markdig.Extensions.EmphasisExtras.EmphasisExtraOptions.Strikethrough)
        .UseTaskLists().UseYamlFrontMatter().UseAutoLinks().UsePreciseSourceLocation().Build();

    /// <summary>The preview of <paramref name="markdown"/>; relative pictures are found from <paramref name="folder"/>.</summary>
    public static PreviewDocument Build(string markdown, string? folder = null) => new Builder(markdown, folder).Run();

    sealed class Builder(string source, string? folder)
    {
        readonly StringBuilder text = new();
        readonly List<PreviewMap.Segment> segments = [];
        readonly List<PreviewBlock> blocks = [];
        List<PreviewSpan> spans = [];
        /// <summary>The marker of a list item, written ahead of the item's first block.</summary>
        string? marker;

        readonly record struct Context(int Indent, int Quote);

        public PreviewDocument Run()
        {
            Blocks(Markdown.Parse(source, Pipeline), new Context(0, 0));
            return new PreviewDocument(text.ToString(), blocks, new PreviewMap(segments));
        }

        // ---- writing

        void Emit(string shown, int? from, int length, bool linear, SpanKind kind, TextStyle style, string? link = null, string? picture = null)
        {
            if (shown.Length == 0) return;
            if (from is int start && start >= 0 && length > 0)
                segments.Add(new(text.Length, shown.Length, start, length, linear && length == shown.Length));
            spans.Add(new PreviewSpan(text.Length, shown, kind, style, link, picture));
            text.Append(shown);
        }

        /// <summary>Text that has its own place in the file: found inside the node's source when it is written the
        /// same way there, else standing for the whole node.</summary>
        void Leaf(string shown, SourceSpan span, TextStyle style, string? link)
        {
            if (span.Start < 0 || span.End >= source.Length || span.End < span.Start)
            {
                Emit(shown, null, 0, false, SpanKind.Text, style, link);
                return;
            }
            var found = source.IndexOf(shown, span.Start, span.Length, StringComparison.Ordinal);
            if (found >= 0) Emit(shown, found, shown.Length, true, SpanKind.Text, style, link);
            else Emit(shown, span.Start, span.Length, false, SpanKind.Text, style, link);
        }

        /// <summary>The end of a block (or a cell): a line break of the rendering's own.</summary>
        void Close() => text.Append('\n');

        PreviewBlock Open(PreviewBlock block)
        {
            blocks.Add(block);
            spans = block.Spans;
            if (marker is not null)
            {
                Emit(marker + " ", null, 0, false, SpanKind.Text, TextStyle.Marker);
                marker = null;
            }
            return block;
        }

        // ---- blocks

        void Blocks(ContainerBlock parent, Context context)
        {
            foreach (var child in parent) Block(child, context);
        }

        void Block(Block node, Context context)
        {
            switch (node)
            {
                case YamlFrontMatterBlock front:
                    Frontmatter(front);
                    break;
                case HeadingBlock heading:
                    Open(new PreviewBlock { Kind = BlockKind.Heading, Level = heading.Level, Indent = context.Indent, Quote = context.Quote });
                    Inlines(heading.Inline, TextStyle.None, null);
                    Close();
                    break;
                case ParagraphBlock paragraph:
                    var only = paragraph.Inline?.FirstChild is LinkInline { IsImage: true } image && image.NextSibling is null;
                    Open(new PreviewBlock { Kind = BlockKind.Paragraph, Indent = context.Indent, Quote = context.Quote, Centered = only });
                    Inlines(paragraph.Inline, TextStyle.None, null);
                    Close();
                    break;
                case FencedCodeBlock fence when fence.Info?.Equals("mermaid", StringComparison.OrdinalIgnoreCase) == true:
                    var diagram = string.Join("\n", Lines(fence).Select(l => l.Text));
                    Open(new PreviewBlock { Kind = BlockKind.Diagram, Indent = context.Indent, Quote = context.Quote, Diagram = diagram, Centered = true });
                    Emit("￼", fence.Span.Start, fence.Span.Length, false, SpanKind.Picture, TextStyle.None);
                    Close();
                    break;
                case CodeBlock code:
                    CodeLines(Lines(code), (code as FencedCodeBlock)?.Info, context);
                    break;
                case MarkdigTable table:
                    Table(table, context);
                    break;
                case QuoteBlock quote:
                    Blocks(quote, context with { Quote = context.Quote + 1 });
                    break;
                case ListBlock list:
                    var number = int.TryParse(list.OrderedStart, out var first) ? first : 1;
                    foreach (var item in list.OfType<ListItemBlock>())
                    {
                        var task = (item.FirstOrDefault() as ParagraphBlock)?.Inline?.FirstChild as TaskList;
                        marker = task is not null ? (task.Checked ? "☑" : "☐") : list.IsOrdered ? $"{number++}." : "•";
                        Blocks(item, context with { Indent = context.Indent + 1 });
                        marker = null;
                    }
                    break;
                case ThematicBreakBlock rule:
                    Open(new PreviewBlock { Kind = BlockKind.Rule, Indent = context.Indent, Quote = context.Quote });
                    Emit(" ", rule.Span.Start, rule.Span.Length, false, SpanKind.Text, TextStyle.None);
                    Close();
                    break;
                case LinkReferenceDefinitionGroup or LinkReferenceDefinition or BlankLineBlock:
                    break;
                case ContainerBlock container:
                    Blocks(container, context);
                    break;
                case LeafBlock leaf:
                    // HTML, and anything else not drawn: shown as it is written.
                    CodeLines(RawLines(leaf), null, context);
                    break;
            }
        }

        readonly record struct Line(string Text, int Start);

        /// <summary>The lines of a block as the parser read them: where each is in the file, without its indentation.</summary>
        static List<Line> Lines(LeafBlock block)
        {
            var lines = new List<Line>();
            for (var i = 0; i < block.Lines.Count; i++)
            {
                var slice = block.Lines.Lines[i].Slice;
                lines.Add(new Line(slice.ToString(), slice.Start));
            }
            while (lines.Count > 0 && lines[^1].Text.Length == 0) lines.RemoveAt(lines.Count - 1);
            return lines;
        }

        /// <summary>The block's lines as they are written in the file.</summary>
        List<Line> RawLines(Block block)
        {
            var lines = new List<Line>();
            if (block.Span.Start < 0) return lines;
            var start = block.Span.Start;
            var end = Math.Min(block.Span.End + 1, source.Length);
            while (start <= end)
            {
                var stop = source.IndexOf('\n', start, end - start);
                if (stop < 0) stop = end;
                var length = stop - start - (stop > start && source[stop - 1] == '\r' ? 1 : 0);
                lines.Add(new Line(source.Substring(start, length), start));
                start = stop + 1;
            }
            while (lines.Count > 0 && lines[^1].Text.Length == 0) lines.RemoveAt(lines.Count - 1);
            return lines;
        }

        void CodeLines(List<Line> lines, string? language, Context context)
        {
            var code = string.Join("\n", lines.Select(l => l.Text));
            Open(new PreviewBlock { Kind = BlockKind.Code, Indent = context.Indent, Quote = context.Quote, Language = string.IsNullOrWhiteSpace(language) ? null : language.Trim().ToLowerInvariant(), Code = code });
            for (var i = 0; i < lines.Count; i++)
            {
                if (i > 0) Emit("\n", null, 0, false, SpanKind.Break, TextStyle.Code);
                Emit(lines[i].Text, lines[i].Start, lines[i].Text.Length, true, SpanKind.Text, TextStyle.Code);
            }
            Close();
        }

        /// <summary>The frontmatter as rows of key and value, each found where it is written.</summary>
        void Frontmatter(YamlFrontMatterBlock front)
        {
            var block = Open(new PreviewBlock { Kind = BlockKind.Frontmatter });
            foreach (var line in Lines(front))
            {
                var colon = line.Text.IndexOf(':');
                var key = colon < 0 ? "" : line.Text[..colon].Trim();
                var value = (colon < 0 ? line.Text : line.Text[(colon + 1)..]).Trim();
                if (key.Length == 0 && value.Length == 0) continue;
                var row = new List<List<PreviewSpan>>();
                foreach (var (part, from) in new[] { (key, 0), (value, colon + 1) })
                {
                    spans = [];
                    if (part.Length > 0) Emit(part, line.Start + line.Text.IndexOf(part, Math.Max(0, from), StringComparison.Ordinal), part.Length, true, SpanKind.Text, TextStyle.None);
                    row.Add(spans);
                    Close();
                }
                block.Rows.Add(row);
            }
            spans = block.Spans;
        }

        void Table(MarkdigTable table, Context context)
        {
            var rows = table.OfType<TableRow>().ToList();
            var block = Open(new PreviewBlock { Kind = BlockKind.Table, Indent = context.Indent, Quote = context.Quote, Header = rows.FirstOrDefault()?.IsHeader == true });
            foreach (var definition in table.ColumnDefinitions)
                block.Alignments.Add(definition.Alignment switch
                {
                    TableColumnAlign.Center => Alignment.Center,
                    TableColumnAlign.Right => Alignment.Right,
                    _ => Alignment.Left,
                });
            foreach (var row in rows)
            {
                var cells = new List<List<PreviewSpan>>();
                foreach (var cell in row.OfType<TableCell>())
                {
                    spans = [];
                    foreach (var paragraph in cell.OfType<ParagraphBlock>()) Inlines(paragraph.Inline, row.IsHeader ? TextStyle.Bold : TextStyle.None, null);
                    cells.Add(spans);
                    Close();
                }
                block.Rows.Add(cells);
            }
            // The parser has a column for what follows the last "|" too.
            var columns = block.Rows.Max(r => r.Count);
            if (block.Alignments.Count > columns) block.Alignments.RemoveRange(columns, block.Alignments.Count - columns);
            spans = block.Spans;
        }

        // ---- inline

        void Inlines(ContainerInline? parent, TextStyle style, string? link)
        {
            if (parent is null) return;
            foreach (var child in parent) Inline(child, style, link);
        }

        void Inline(Inline node, TextStyle style, string? link)
        {
            switch (node)
            {
                case LiteralInline literal:
                    // After a task's checkbox, which is the item's marker, the space is the marker's.
                    var words = literal.Content.ToString();
                    Leaf(literal.PreviousSibling is TaskList ? words.TrimStart() : words, literal.Span, style, link);
                    break;
                case CodeInline code:
                    Leaf(code.Content, code.Span, style | TextStyle.Code, link);
                    break;
                case HtmlEntityInline entity:
                    Emit(entity.Transcoded.ToString(), entity.Span.Start, entity.Span.Length, false, SpanKind.Text, style, link);
                    break;
                case LineBreakInline { IsHard: true } hard:
                    Emit("\n", hard.Span.Start, hard.Span.Length, false, SpanKind.Break, style);
                    break;
                case LineBreakInline soft:
                    // A space for the line's end, "\n" or "\r\n", which is not the same text.
                    var end = soft.Span.Start + (source.AsSpan(soft.Span.Start).StartsWith("\r\n") ? 2 : 1);
                    Emit(" ", soft.Span.Start, end - soft.Span.Start, false, SpanKind.Text, style, link);
                    break;
                case LinkInline { IsImage: true } image:
                    if (Picture(image.Url) is string picture)
                        Emit("￼", image.Span.Start, image.Span.Length, false, SpanKind.Picture, style, link, picture);
                    else
                        Inlines(image, style, link);
                    break;
                case LinkInline anchor:
                    Inlines(anchor, style, anchor.Url);
                    break;
                case AutolinkInline auto:
                    Leaf(auto.Url, auto.Span, style, auto.IsEmail ? "mailto:" + auto.Url : auto.Url);
                    break;
                case HtmlInline html:
                    Leaf(html.Tag, html.Span, style | TextStyle.Code, link);
                    break;
                case EmphasisInline emphasis:
                    var next = emphasis.DelimiterChar switch
                    {
                        '~' => TextStyle.Strike,
                        '*' or '_' => emphasis.DelimiterCount >= 2 ? TextStyle.Bold : TextStyle.Italic,
                        _ => TextStyle.None,
                    };
                    Inlines(emphasis, style | next, link);
                    break;
                case TaskList:
                    break;   // the list item's marker
                case ContainerInline container:
                    Inlines(container, style, link);
                    break;
            }
        }

        /// <summary>Where a picture is: a web address as it is, a path from the file's folder.</summary>
        string? Picture(string? url)
        {
            if (string.IsNullOrWhiteSpace(url)) return null;
            if (Uri.TryCreate(url, UriKind.Absolute, out var absolute) && absolute.Scheme is "http" or "https" or "file") return url;
            if (folder is null) return null;
            try { return System.IO.Path.GetFullPath(System.IO.Path.Combine(folder, Uri.UnescapeDataString(url))); }
            catch (ArgumentException) { return null; }
        }
    }
}
