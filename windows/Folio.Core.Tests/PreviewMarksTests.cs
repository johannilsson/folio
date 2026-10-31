using Folio.Core.Preview;

namespace Folio.Core.Tests;

public class PreviewMapTests
{
    /// <summary>"A **bold** word" as the preview shows it, "A bold word": the bold marks are left out.</summary>
    static readonly PreviewMap Bold = new([new(0, 2, 0, 2, true), new(2, 4, 4, 4, true), new(6, 5, 10, 5, true)]);

    [Fact]
    public void Maps_shown_words_to_the_file_and_back()
    {
        // "bold word" on screen is "bold** word" in the file; "bold" in the file is "bold" on screen.
        Assert.Equal((4, 15), Bold.SourceRange(2, 11));
        Assert.Equal((2, 6), Bold.DisplayRange(4, 8));
    }

    [Fact]
    public void A_position_inside_marks_snaps_to_the_shown_text()
    {
        // Inside the closing "**": a start snaps forward to " word", an end back to after "bold".
        Assert.Equal(6, Bold.DisplayLocation(9, end: false));
        Assert.Equal(6, Bold.DisplayLocation(9, end: true));
        Assert.Equal(2, Bold.DisplayLocation(3, end: false));
    }

    [Fact]
    public void Text_only_in_the_rendering_has_no_place_in_the_file()
    {
        // "- one" shown as "• one": only the bullet is selected.
        var list = new PreviewMap([new(2, 3, 2, 3, true)]);
        Assert.Null(list.SourceRange(0, 2));
        Assert.Equal((2, 5), list.SourceRange(0, 5));
    }

    [Fact]
    public void A_segment_that_is_not_linear_is_mapped_as_a_whole()
    {
        // "&amp;" shown as "&".
        var entity = new PreviewMap([new(0, 1, 0, 5, false)]);
        Assert.Equal((0, 5), entity.SourceRange(0, 1));
        Assert.Equal((0, 1), entity.DisplayRange(1, 3));
    }
}

public class PreviewMarksTests
{
    static Annotation Ann(string id, string kind, string context, string? target, string? replacement = null) =>
        new(id, kind, "agent", "t", context, target, replacement, kind == "comment" ? "Note" : null, "2026-01-01T00:00:00Z", false, null, null, null);

    static List<Shown> Show(string markdown, PreviewDocument preview, params Annotation[] annotations) =>
        PreviewMarks.Show(preview, Review.Place(markdown, annotations));

    [Fact]
    public void A_mark_covers_the_target_as_it_is_shown_and_a_suggestion_follows_it()
    {
        var markdown = "The **quick** brown fox.";
        var preview = PreviewBuilder.Build(markdown);
        var shown = Show(markdown, preview, Ann("r", "replace", "The ", "quick", "slow"), Ann("i", "insert", "brown fox", null, "!"));

        var replace = shown.Single(s => s.Annotation.Id == "r");
        Assert.Equal("quick", preview.Text[replace.From!.Value..replace.To!.Value]);
        Assert.Equal(replace.To, PreviewMarks.GhostAt(replace));
        var insert = shown.Single(s => s.Annotation.Id == "i");
        Assert.False(insert.Marked);
        Assert.Equal(preview.Text.IndexOf('.'), PreviewMarks.GhostAt(insert));
    }

    [Fact]
    public void Cut_splits_a_span_at_its_marks_and_puts_suggestions_in_after_them()
    {
        var markdown = "One two three four.";
        var preview = PreviewBuilder.Build(markdown);
        var shown = Show(markdown, preview, Ann("a", "replace", "One ", "two three", "2 3"), Ann("b", "comment", "One two ", "three"));
        var pieces = PreviewMarks.Cut(preview.Blocks[0].Spans.Single(), shown);
        Assert.Equal(["One ", "two ", "three", "2 3", " four."], pieces.Select(p => p.Text));
        Assert.Equal([[], ["a"], ["b", "a"], [], []], pieces.Select(p => p.Marks));
        Assert.Equal("a", pieces[3].Ghost);
        // The preview takes up no place in the text: the piece after it starts where the mark ends.
        Assert.Equal(pieces[2].End, pieces[4].Start);
    }

    [Fact]
    public void A_mark_across_spans_is_cut_in_each()
    {
        var markdown = "Some **bold** words";
        var preview = PreviewBuilder.Build(markdown);
        var shown = Show(markdown, preview, Ann("h", "highlight", "Some ", "bold words"));
        var pieces = preview.Blocks[0].Spans.SelectMany(s => PreviewMarks.Cut(s, shown)).ToList();
        Assert.Equal(["Some ", "bold", " words"], pieces.Select(p => p.Text));
        Assert.Equal([[], ["h"], ["h"]], pieces.Select(p => p.Marks));
    }

    [Fact]
    public void An_annotation_not_found_is_shown_nowhere()
    {
        var markdown = "Hello.";
        var shown = Show(markdown, PreviewBuilder.Build(markdown), Ann("x", "comment", "nowhere ", "gone"));
        Assert.Equal((false, null), (shown.Single().Marked, shown.Single().At));
    }
}

public class CardLayoutTests
{
    [Fact]
    public void Cards_sit_at_their_anchor_in_document_order_and_are_pushed_down_when_they_overlap()
    {
        var (placed, extent) = CardLayout.Stack([
            new(new CardLayout.Anchor(100, 1), 50),
            new(new CardLayout.Anchor(20, 0), 100),
            new(null, 30),
        ], end: 400);
        Assert.Equal([(1, 16.0), (0, 122.0), (2, 396.0)], placed);
        Assert.Equal(432, extent);
    }

    [Fact]
    public void The_comment_button_goes_above_the_selection_or_below_it_at_the_top_of_the_window()
    {
        Assert.Equal((100.0, 162.0), CardLayout.AdderOrigin(80, 30, 120, 160, 200, 220, visibleTop: 0, textWidth: 760));
        Assert.Equal((100.0, 228.0), CardLayout.AdderOrigin(80, 30, 120, 160, 200, 220, visibleTop: 180, textWidth: 760));
        // Kept inside the text column.
        Assert.Equal((672.0, 162.0), CardLayout.AdderOrigin(80, 30, 740, 800, 200, 220, visibleTop: 0, textWidth: 760));
    }
}

public class SetTests
{
    [Fact]
    public void A_set_made_with_the_cli_lists_its_files_by_root()
    {
        // The engine reads the sets from FOLIO_CONFIG_DIR, which only the process's start can set for it.
        Assert.True(Environment.GetEnvironmentVariable("FOLIO_CONFIG_DIR") is { Length: > 0 }, "FOLIO_CONFIG_DIR must name a throwaway folder; run windows/verify.sh");
        using var a = new Fixture("# A\n", "alpha.md");
        using var b = new Fixture("# B\n", "beta.md");
        var name = $"t{Guid.NewGuid():N}"[..12];
        a.RunCli("set", "add", name, a.File, b.File);

        Assert.Contains(name, Engine.SetNames());
        var set = Engine.SetLoad(name);
        Assert.Equal([a.File, b.File], set.Files.Select(f => f.Path));
        Assert.Equal(["alpha.md", "beta.md"], set.Files.Select(f => f.Name));
        Assert.Equal(Engine.SidecarPath(a.File), set.Files[0].FolioPath);
    }

    [Fact]
    public void After_a_change_the_set_keeps_showing_the_same_file()
    {
        SetFile F(string id) => new(id, id, "g", id, id);
        var set = new FolioSet("s", "m", [F("a"), F("b"), F("c")]);
        Assert.Equal("b", set.Keep("b")!.Id);
        Assert.Equal("a", set.Keep("gone")!.Id);
        Assert.Null(new FolioSet("s", "m", []).Keep("b"));
    }
}

public class CodeColoursTests
{
    [Fact]
    public void The_pages_colours_land_on_the_code_as_it_is_shown_after_a_list_marker()
    {
        var markdown = "Before.\r\n\r\n- ```js\r\n  let a = 1;\r\n  b();\r\n  ```\r\n";
        var preview = PreviewBuilder.Build(markdown);
        var code = preview.Blocks.Single(b => b.Kind == BlockKind.Code);
        Assert.Equal("let a = 1;\nb();", code.Code);
        // What __folioHighlight answers: offsets into the code.
        var colours = CodeColours.Place(code, [(0, 3, "keyword"), (8, 9, "number"), (11, 12, "title"), (14, 99, "beyond")]);
        Assert.Equal(["let", "1", "b"], colours.Select(c => preview.Text[c.From..c.To]));
    }

    [Fact]
    public void Cut_gives_each_piece_its_innermost_scope_and_keeps_marks()
    {
        var markdown = "```js\nlet word = \"a b\";\n```\n";
        var preview = PreviewBuilder.Build(markdown);
        var code = preview.Blocks.Single();
        var at = code.Spans[0].Start;
        // A string with a nested piece, and a mark over "word".
        var colours = CodeColours.Place(code, [(0, 3, "keyword"), (11, 16, "string"), (12, 13, "subst")]);
        var shown = PreviewMarks.Show(preview, Review.Place(markdown, [
            new Annotation("m", "highlight", "agent", "t", "let ", "word", null, null, "2026-01-01T00:00:00Z", false, null, null, null)]));
        var pieces = PreviewMarks.Cut(code.Spans[0], shown, colours);
        Assert.Equal(["let", " ", "word", " = ", "\"", "a", " b\"", ";"], pieces.Select(p => p.Text));
        Assert.Equal(["keyword", null, null, null, "string", "subst", "string", null], pieces.Select(p => p.Scope));
        Assert.Equal(["m"], pieces[2].Marks);
        Assert.Equal(at, pieces[0].Start);
    }

    [Theory]
    [InlineData("keyword", Syntax.Keyword)]
    [InlineData("built_in", Syntax.Title)]
    [InlineData("attr", Syntax.Number)]
    [InlineData("quote", Syntax.Comment)]
    [InlineData("tag", Syntax.Name)]
    [InlineData("punctuation", Syntax.None)]
    public void A_scope_has_the_colour_the_macOS_app_gives_it(string scope, Syntax syntax) => Assert.Equal(syntax, CodeColours.Of(scope));
}
