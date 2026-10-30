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

    [Fact]
    public void Lines_splits_on_both_line_endings_and_keeps_the_breaks_out_of_the_text()
    {
        Assert.Equal([new Lines.Line(0, 3), new Lines.Line(5, 2), new Lines.Line(8, 0)], Lines.Split("abc\r\nde\n"));
        Assert.Equal([new Lines.Line(0, 0)], Lines.Split(""));
    }

    [Theory]
    [InlineData(0, 0, 0)]
    [InlineData(2, 0, 2)]
    [InlineData(3, 0, 3)]   // the \r of the first break is the end of line 0
    [InlineData(4, 0, 3)]   // so is the \n
    [InlineData(5, 1, 0)]
    [InlineData(7, 1, 2)]
    public void Locate_finds_the_line_and_column_of_an_offset(int offset, int line, int column)
    {
        Assert.Equal((line, column), Lines.Locate(Lines.Split("abc\r\nde\nf"), offset));
    }
}
