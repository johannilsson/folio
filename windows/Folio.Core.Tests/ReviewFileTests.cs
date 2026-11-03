using System.Text.Json.Nodes;

namespace Folio.Core.Tests;

/// <summary>The client against the CLI on the same files: what an agent writes is what the client reads, and the reverse.</summary>
public class ReviewFileTests
{
    [Fact]
    public void Reads_what_the_cli_annotated()
    {
        using var fixture = new Fixture("The quick brown fox.\n");
        fixture.Annotate("replace", "The ", "quick", replacement: "slow");
        var review = new ReviewFile(fixture.File);
        var placed = Review.Place(review.ReadText(), Sidecar.Parse(review.ReadSidecar()));
        var only = Assert.Single(placed);
        Assert.Equal("replace", only.Annotation.Kind);
        Assert.Equal("\"quick\" → \"slow\"", only.Annotation.Summary);
        Assert.Equal((4, 9), (only.From, only.To));
    }

    [Fact]
    public void Accept_patches_the_markdown_and_resolves_the_annotation()
    {
        using var fixture = new Fixture("The quick brown fox.\n");
        var id = fixture.Annotate("replace", "The ", "quick", replacement: "slow");
        var review = new ReviewFile(fixture.File);

        review.Accept(id);

        Assert.Equal("The slow brown fox.\n", review.ReadText());
        var annotation = Assert.Single(Sidecar.Parse(review.ReadSidecar()));
        Assert.True(annotation.Resolved);
        Assert.Equal("accepted", annotation.ResolvedAs);
        Assert.Empty(Review.Place(review.ReadText(), Sidecar.Parse(review.ReadSidecar())));
    }

    [Fact]
    public void Accept_keeps_windows_line_endings()
    {
        using var fixture = new Fixture("First line.\r\nSecond line.\r\n");
        var id = fixture.Annotate("insert", "First line.", replacement: "\nAdded.");
        var review = new ReviewFile(fixture.File);

        review.Accept(id);

        Assert.Equal("First line.\r\nAdded.\r\nSecond line.\r\n", review.ReadText());
    }

    [Fact]
    public void Reject_leaves_the_markdown_alone_and_dismisses_a_comment()
    {
        using var fixture = new Fixture("The quick brown fox.\n");
        var suggestion = fixture.Annotate("delete", "The ", "quick ");
        var comment = fixture.Annotate("comment", "brown ", "fox", comment: "Which one?");
        var review = new ReviewFile(fixture.File);

        review.Reject(suggestion);
        review.Reject(comment);

        Assert.Equal("The quick brown fox.\n", review.ReadText());
        var resolved = Sidecar.Parse(review.ReadSidecar()).ToDictionary(a => a.Id, a => a.ResolvedAs);
        Assert.Equal("rejected", resolved[suggestion]);
        Assert.Equal("dismissed", resolved[comment]);
    }

    [Fact]
    public void An_action_keeps_what_an_agent_wrote_in_the_meantime()
    {
        using var fixture = new Fixture("The quick brown fox jumps.\n");
        var first = fixture.Annotate("comment", "The ", "quick", comment: "One");
        var review = new ReviewFile(fixture.File);
        Review.Place(review.ReadText(), Sidecar.Parse(review.ReadSidecar()));   // the client has "seen" the first one

        var second = fixture.Annotate("comment", "brown ", "fox", comment: "Two");   // an agent adds another
        review.Reject(first);

        var all = Sidecar.Parse(review.ReadSidecar());
        Assert.Equal([first, second], all.Select(a => a.Id));
        Assert.True(all[0].Resolved);
        Assert.False(all[1].Resolved);
    }

    [Fact]
    public void A_reply_and_a_new_comment_are_the_local_readers_and_the_cli_reads_them()
    {
        using var fixture = new Fixture("The **quick** brown fox.\n");
        var agent = fixture.Annotate("comment", "The ", "quick", comment: "Fast?");
        var review = new ReviewFile(fixture.File);

        review.Reply(agent, "Yes, fast.");
        // "quick** brown" selected in the markdown: anchored by its rendered words, without the stars.
        var doc = review.ReadText();
        var mine = review.AddComment(doc.IndexOf("quick", StringComparison.Ordinal), doc.IndexOf(" fox", StringComparison.Ordinal), "Two words");

        var all = Sidecar.Parse(review.ReadSidecar());
        var reply = Assert.Single(all.Single(a => a.Id == agent).Replies!);
        Assert.Equal(("me", "local", "Yes, fast."), (reply.Author, reply.Source, reply.Body));
        var comment = all.Single(a => a.Id == mine);
        Assert.Equal(("quick brown", "The ", "local"), (comment.Target, comment.ContextBefore, comment.Source));
        Assert.Contains(mine!, fixture.RunCli("review", fixture.File));
        // Only markup selected: nothing to anchor a comment to.
        Assert.Null(review.AddComment(doc.IndexOf("**", StringComparison.Ordinal), doc.IndexOf("**", StringComparison.Ordinal) + 2, "Stars"));
    }

    [Fact]
    public void Accept_keeps_a_byte_order_mark_and_the_offsets_do_not_count_it()
    {
        using var fixture = new Fixture("");
        File.WriteAllBytes(fixture.File, [0xEF, 0xBB, 0xBF, .. "The quick fox.\r\n"u8.ToArray()]);
        var id = fixture.Annotate("replace", "The ", "quick", replacement: "slow");
        var review = new ReviewFile(fixture.File);
        var placed = Review.Place(review.ReadText(), Sidecar.Parse(review.ReadSidecar())).Single();
        Assert.Equal((4, 9), (placed.From, placed.To));

        review.Accept(id);

        Assert.Equal([0xEF, 0xBB, 0xBF, .. "The slow fox.\r\n"u8.ToArray()], File.ReadAllBytes(fixture.File));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(review.SidecarPath)!, "*.tmp"));
    }

    [Fact]
    public void Stamp_changes_when_the_cli_writes_and_not_when_nothing_does()
    {
        using var fixture = new Fixture("Hello world.\n");
        var review = new ReviewFile(fixture.File);
        var before = review.Stamp();
        Assert.Equal(before, review.Stamp());
        fixture.Annotate("comment", "Hello ", "world", comment: "Hi");
        Assert.NotEqual(before, review.Stamp());
    }

    [Fact]
    public void Edit_through_the_engine_adds_a_comment_the_cli_can_read()
    {
        using var fixture = new Fixture("Hello world.\n");
        var review = new ReviewFile(fixture.File);
        var edit = new JsonObject { ["op"] = "add_comment", ["context_before"] = "Hello ", ["target"] = "world", ["comment"] = "Nice", ["author"] = "me", ["source"] = "local" };
        var (sidecar, id) = Engine.Edit(review.ReadSidecar(), edit);
        Assert.NotNull(id);
        Assert.Equal("Nice", Assert.Single(Sidecar.Parse(sidecar)).Comment);
    }
}
