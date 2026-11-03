namespace Folio.Core.Tests;

public class EngineTests
{
    [Fact]
    public void Anchor_gives_utf16_offsets_that_slice_the_target_out_of_the_markdown()
    {
        // The emoji is two UTF-16 units; the offsets must count them as .NET does.
        var doc = "😀 The quick brown fox.\n";
        var found = Engine.Anchor(doc, [("a", "The ", "quick")]).Single();
        Assert.Equal("quick", doc[found.From..found.To]);
    }

    [Fact]
    public void Anchor_has_no_range_for_what_is_not_in_the_text()
    {
        Assert.Empty(Engine.Anchor("Hello world.", [("gone", "nowhere ", "missing")]));
    }

    [Fact]
    public void An_engine_error_is_an_exception_with_its_message()
    {
        var error = Assert.Throws<EngineException>(() => Engine.Accept("Hello.", Engine.EmptySidecar, "nope"));
        Assert.Equal("no pending annotation with that id", error.Message);
    }

    [Fact]
    public void SidecarPath_is_where_the_cli_writes_it()
    {
        using var fixture = new Fixture("Hello world.\n");
        fixture.Annotate("comment", "Hello ", "world", comment: "Why?");
        Assert.True(File.Exists(Engine.SidecarPath(fixture.File)));
    }
}
