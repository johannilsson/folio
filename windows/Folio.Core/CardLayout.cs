namespace Folio.Core;

/// <summary>Where the cards go in the comments pane beside the text, and the Comment button over it, as in the
/// macOS app's <c>CardLayout</c>. Page coordinates, y down.</summary>
public static class CardLayout
{
    /// <summary>Where a card's text is: its top, and its place in the document, which orders the pane.</summary>
    public readonly record struct Anchor(double Top, int Order);

    /// <summary>A card to stack: its anchor (null when it is not found in the document) and its measured height.</summary>
    public readonly record struct Card(Anchor? Anchor, double Height);

    /// <summary>Stacks <paramref name="cards"/> in document order, each at its anchor's top minus 4, pushed down to 6
    /// below the one above when it would overlap. One not found in the document is parked at <paramref name="end"/>,
    /// after the text. Returns each card's index with its top, in document order, and how far down they reach.</summary>
    public static (List<(int Index, double Top)> Placed, double Extent) Stack(IReadOnlyList<Card> cards, double end)
    {
        const double gap = 6;
        var placed = new List<(int Index, double Top)>();
        var minTop = 0.0;
        foreach (var index in Enumerable.Range(0, cards.Count).OrderBy(i => cards[i].Anchor?.Order ?? int.MaxValue))
        {
            var top = Math.Max((cards[index].Anchor?.Top ?? end) - 4, minTop);
            placed.Add((index, top));
            minTop = top + cards[index].Height + gap;
        }
        return (placed, minTop);
    }

    /// <summary>Where the Comment button of <paramref name="width"/> × <paramref name="height"/> goes for a selection whose
    /// first line runs from <paramref name="top"/> to <paramref name="bottom"/>, between <paramref name="left"/> and
    /// <paramref name="right"/>: above it, centred, or below it when there is no room above the top of what is visible
    /// (<paramref name="visibleTop"/>). Kept inside the text column, <paramref name="textWidth"/> wide.</summary>
    public static (double X, double Y) AdderOrigin(double width, double height, double left, double right, double top, double bottom,
                                                  double visibleTop, double textWidth)
    {
        var centre = (left + right) / 2;
        var above = top - 8 - height;
        var y = above < visibleTop + 8 ? bottom + 8 : above;
        var x = Math.Min(Math.Max(8, centre - width / 2), Math.Max(8, textWidth - width - 8));
        return (x, y);
    }
}
