namespace Folio.Core.Preview;

/// <summary>A coloured piece of code on screen: shown offsets and its highlight.js scope.</summary>
public readonly record struct Colour(int From, int To, string Scope);

/// <summary>The kinds of code the preview colours, as the macOS app does; <c>None</c> keeps the text colour.</summary>
public enum Syntax { None, Keyword, String, Number, Comment, Title, Name }

public static class CodeColours
{
    /// <summary>Where the colours the diagram page gave for a code block's code (offsets into
    /// <see cref="PreviewBlock.Code"/>) are on screen: its code starts at its first span that is not a list marker,
    /// and is shown as it is, line breaks included. A colour that reaches past the code is left out.</summary>
    public static List<Colour> Place(PreviewBlock block, IEnumerable<(int From, int To, string Scope)> scopes)
    {
        if (block.Kind != BlockKind.Code || block.Code is not string code
            || block.Spans.FirstOrDefault(s => !s.Style.HasFlag(TextStyle.Marker)) is not PreviewSpan first) return [];
        return scopes.Where(s => s.From >= 0 && s.To > s.From && s.To <= code.Length)
            .Select(s => new Colour(first.Start + s.From, first.Start + s.To, s.Scope)).ToList();
    }

    /// <summary>Which colour a highlight.js scope is.</summary>
    public static Syntax Of(string scope) => scope switch
    {
        "keyword" or "selector-tag" or "doctag" or "deletion" => Syntax.Keyword,
        "string" or "regexp" or "addition" or "template-variable" or "selector-attr" => Syntax.String,
        "number" or "literal" or "symbol" or "meta" or "attr" or "attribute" or "variable" or "property"
            or "selector-id" or "selector-class" or "bullet" => Syntax.Number,
        "comment" or "quote" => Syntax.Comment,
        "title" or "built_in" or "type" or "class" or "function" or "section" => Syntax.Title,
        "tag" or "name" => Syntax.Name,
        _ => Syntax.None,
    };
}
