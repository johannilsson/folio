namespace Folio.Core;

/// <summary>A file of a set: <c>Name</c> is its path relative to its root, <c>Group</c> the root's folder name.</summary>
public sealed record SetFile(string Id, string Name, string Group, string Path, string FolioPath);

/// <summary>A named list of files (<c>folio set</c>), kept in <c>Manifest</c>, which the CLI and agents change.</summary>
public sealed record FolioSet(string Name, string Manifest, List<SetFile> Files)
{
    /// <summary>The file to show after the set changed: the one shown before when it is still in the set, by
    /// id, else the first. Never falls back because the list was rebuilt.</summary>
    public SetFile? Keep(string? shownId) => Files.FirstOrDefault(f => f.Id == shownId) ?? Files.FirstOrDefault();
}
