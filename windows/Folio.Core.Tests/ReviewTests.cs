namespace Folio.Core.Tests;

public class ReviewTests
{
    static Annotation Ann(string id, string context, string? target, bool resolved = false) =>
        new(id, "highlight", "agent", "t", context, target, null, null, "2026-01-01T00:00:00Z", resolved, null, null, null);

    [Fact]
    public void Place_lists_pending_annotations_in_document_order_and_the_lost_ones_last()
    {
        var doc = "One two three four.";
        var placed = Review.Place(doc, [
            Ann("late", "three ", "four"),
            Ann("lost", "nowhere ", "missing"),
            Ann("early", "One ", "two"),
            Ann("done", "One ", "two", resolved: true),
        ]);
        Assert.Equal(["early", "late", "lost"], placed.Select(p => p.Annotation.Id));
        Assert.Equal(["two", "four"], placed.Where(p => p.Found).Select(p => doc[p.From!.Value..p.To!.Value]));
    }
}
