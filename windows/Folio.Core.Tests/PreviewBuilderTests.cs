using Folio.Core.Preview;

namespace Folio.Core.Tests;

public class PreviewBuilderTests
{
    /// <summary>The shown text, with the line breaks between blocks as "|" so a test reads on one line.</summary>
    static string Shown(PreviewDocument preview) => preview.Text.TrimEnd('\n').Replace("\n", "|");

    /// <summary>Every linear segment holds the same text in the file and on screen.</summary>
    static void LinearSegmentsMatch(string markdown, PreviewDocument preview)
    {
        foreach (var s in preview.Map.Segments.Where(s => s.Linear))
            Assert.Equal(markdown.Substring(s.Source, s.SourceLength), preview.Text.Substring(s.Display, s.Length));
    }

    [Fact]
    public void Markup_is_left_out_and_the_words_map_to_where_they_are_written()
    {
        var markdown = "## Heading\n\nSome **bold**, *italic*, `code` and [a link](https://x.dev) &amp; more.\n";
        var preview = PreviewBuilder.Build(markdown);
        Assert.Equal("Heading|Some bold, italic, code and a link & more.", Shown(preview));
        LinearSegmentsMatch(markdown, preview);

        var heading = preview.Blocks[0];
        Assert.Equal((BlockKind.Heading, 2), (heading.Kind, heading.Level));
        var spans = preview.Blocks[1].Spans;
        Assert.Equal(TextStyle.Bold, spans.Single(s => s.Text == "bold").Style);
        Assert.Equal(TextStyle.Italic, spans.Single(s => s.Text == "italic").Style);
        Assert.Equal(TextStyle.Code, spans.Single(s => s.Text == "code").Style);
        Assert.Equal("https://x.dev", spans.Single(s => s.Text == "a link").Link);

        // "bold" on screen is "bold" in the file, without its stars.
        var bold = preview.Text.IndexOf("bold", StringComparison.Ordinal);
        Assert.Equal((markdown.IndexOf("bold", StringComparison.Ordinal), markdown.IndexOf("bold", StringComparison.Ordinal) + 4), preview.Map.SourceRange(bold, bold + 4));
    }

    [Fact]
    public void An_entity_is_mapped_as_a_whole()
    {
        var markdown = "A &amp; B";
        var preview = PreviewBuilder.Build(markdown);
        var amp = preview.Text.IndexOf('&');
        Assert.Equal((2, 7), preview.Map.SourceRange(amp, amp + 1));
    }

    [Fact]
    public void Lists_get_markers_that_are_not_in_the_file()
    {
        var markdown = "- one\n  - nested\n\n3. three\n4. four\n\n- [x] done\n- [ ] open\n";
        var preview = PreviewBuilder.Build(markdown);
        Assert.Equal("• one|• nested|3. three|4. four|☑ done|☐ open", Shown(preview));
        Assert.Equal([1, 2, 1, 1, 1, 1], preview.Blocks.Select(b => b.Indent));
        Assert.All(preview.Blocks, b => Assert.Equal(TextStyle.Marker, b.Spans[0].Style));
        // The marker has no place in the file.
        Assert.Null(preview.Map.SourceRange(0, 2));
        LinearSegmentsMatch(markdown, preview);
    }

    [Fact]
    public void Code_keeps_its_lines_each_where_it_is_written()
    {
        var markdown = "Before.\n\n```JS\nlet a = 1;\n\nb();\n```\n\n    indented\n";
        var preview = PreviewBuilder.Build(markdown);
        var code = preview.Blocks[1];
        Assert.Equal((BlockKind.Code, "js", "let a = 1;\n\nb();"), (code.Kind, code.Language, code.Code));
        Assert.Equal(["let a = 1;", "\n", "\n", "b();"], code.Spans.Select(s => s.Text));
        Assert.Equal("indented", preview.Blocks[2].Code);
        LinearSegmentsMatch(markdown, preview);
    }

    [Fact]
    public void A_mermaid_block_is_a_diagram_that_stands_for_its_whole_fence()
    {
        var markdown = "```mermaid\ngraph TD\n  A --> B\n```\n";
        var preview = PreviewBuilder.Build(markdown);
        var diagram = Assert.Single(preview.Blocks);
        Assert.Equal((BlockKind.Diagram, "graph TD\n  A --> B"), (diagram.Kind, diagram.Diagram));
        Assert.Equal(SpanKind.Picture, Assert.Single(diagram.Spans).Kind);
        Assert.Equal((0, markdown.TrimEnd('\n').Length), preview.Map.SourceRange(0, 1));
    }

    [Fact]
    public void A_table_has_rows_of_cells_with_the_header_bold()
    {
        var markdown = "| Name | Size |\n|:----|----:|\n| **a** | 1 |\n| b | 22 |\n";
        var preview = PreviewBuilder.Build(markdown);
        var table = Assert.Single(preview.Blocks);
        Assert.Equal(BlockKind.Table, table.Kind);
        Assert.True(table.Header);
        Assert.Equal([Alignment.Left, Alignment.Right], table.Alignments);
        Assert.Equal([["Name", "Size"], ["a", "1"], ["b", "22"]], table.Rows.Select(r => r.Select(c => string.Concat(c.Select(s => s.Text)))));
        Assert.Equal(TextStyle.Bold, table.Rows[0][0][0].Style);
        Assert.Equal(TextStyle.Bold, table.Rows[1][0][0].Style);
        Assert.Equal("Name|Size|a|1|b|22", Shown(preview));
        LinearSegmentsMatch(markdown, preview);
    }

    [Fact]
    public void Frontmatter_is_rows_of_key_and_value()
    {
        var markdown = "---\ntitle: A plan\ntags: x, y\n---\n# Body\n";
        var preview = PreviewBuilder.Build(markdown);
        var front = preview.Blocks[0];
        Assert.Equal(BlockKind.Frontmatter, front.Kind);
        Assert.Equal([["title", "A plan"], ["tags", "x, y"]], front.Rows.Select(r => r.Select(c => string.Concat(c.Select(s => s.Text)))));
        LinearSegmentsMatch(markdown, preview);
    }

    [Fact]
    public void Html_and_quotes()
    {
        var markdown = "<div align=\"center\">\n  <b>hi</b>\n</div>\n\n> quoted **text**\n> > deeper\n";
        var preview = PreviewBuilder.Build(markdown);
        // HTML is shown as it is written, line by line.
        Assert.Equal((BlockKind.Code, "<div align=\"center\">\n  <b>hi</b>\n</div>"), (preview.Blocks[0].Kind, preview.Blocks[0].Code));
        Assert.Equal([1, 2], preview.Blocks.Skip(1).Select(b => b.Quote));
        LinearSegmentsMatch(markdown, preview);
    }

    [Fact]
    public void Pictures_are_found_from_the_files_folder()
    {
        var folder = Path.Combine(Path.GetTempPath(), "docs");
        var preview = PreviewBuilder.Build("![A diagram](img/a%20b.png)\n\nText ![web](https://x.dev/p.png) here.\n", folder);
        var alone = preview.Blocks[0];
        Assert.True(alone.Centered);
        Assert.Equal(Path.Combine(folder, "img", "a b.png"), Assert.Single(alone.Spans).Picture);
        Assert.Equal("https://x.dev/p.png", preview.Blocks[1].Spans.Single(s => s.Kind == SpanKind.Picture).Picture);
        Assert.False(preview.Blocks[1].Centered);
    }

    [Fact]
    public void Windows_line_endings_map_the_same_words()
    {
        var lf = "---\ntitle: Plan\n---\n# Title\n\nFirst **bold** line\nsecond line.\n\n- item\n\n| a | b |\n|---|---|\n| x | y |\n\n```\ncode\n```\n";
        var crlf = lf.Replace("\n", "\r\n");
        var (a, b) = (PreviewBuilder.Build(lf), PreviewBuilder.Build(crlf));
        Assert.Equal(a.Text, b.Text);
        LinearSegmentsMatch(crlf, b);
        // A word after the soft break is where it is written in the CRLF file.
        var second = b.Text.IndexOf("second", StringComparison.Ordinal);
        var (from, to) = b.Map.SourceRange(second, second + 6)!.Value;
        Assert.Equal("second", crlf[from..to]);
    }

    [Fact]
    public void What_the_engine_anchors_is_what_the_preview_marks()
    {
        // The preview's map and the engine's raw anchoring agree: the shown range of every target is the target.
        var markdown = "# Plan\r\n\r\nThe **quick** brown fox &amp; the `lazy` dog.\r\n\r\n- one item\r\n- two items\r\n\r\n| a | b |\r\n|---|---|\r\n| cell x | y |\r\n";
        var preview = PreviewBuilder.Build(markdown);
        var targets = new (string Context, string Target)[] { ("The ", "quick"), ("brown fox & the ", "lazy"), ("one item", "two"), ("ab", "cell x") };
        var found = Engine.Anchor(markdown, targets.Select((t, i) => ($"{i}", t.Context, (string?)t.Target)));
        Assert.Equal(targets.Length, found.Count);
        foreach (var (id, from, to) in found)
        {
            var (a, b) = preview.Map.DisplayRange(from, to)!.Value;
            Assert.Equal(targets[int.Parse(id)].Target, preview.Text[a..b]);
        }
    }
}
