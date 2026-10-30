namespace Folio.Core;

/// <summary>An unresolved annotation and where it is in the markdown; no range when it cannot be found.</summary>
public sealed record Placed(Annotation Annotation, int? From, int? To)
{
    public bool Found => From is not null;
}

/// <summary>The rules of what a review shows, as functions of the markdown and the annotations.</summary>
public static class Review
{
    /// <summary>The unresolved annotations in document order; those not found in it come last, in sidecar order.</summary>
    public static List<Placed> Place(string doc, IEnumerable<Annotation> annotations)
    {
        var pending = annotations.Where(a => !a.Resolved).ToList();
        var found = Engine.Anchor(doc, pending.Select(a => (a.Id, a.ContextBefore, a.Target))).ToDictionary(r => r.Id);
        var placed = pending.Select(a => found.TryGetValue(a.Id, out var r) ? new Placed(a, r.From, r.To) : new Placed(a, null, null));
        return placed.Where(p => p.Found).OrderBy(p => p.From).ThenBy(p => p.To)
            .Concat(placed.Where(p => !p.Found)).ToList();
    }
}
