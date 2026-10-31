namespace Folio.Core;

/// <summary>A file of a set: <c>Name</c> is its path relative to its root, <c>Group</c> the root's folder name.</summary>
public sealed record SetFile(string Id, string Name, string Group, string Path, string FolioPath);

/// <summary>A named list of files (<c>folio set</c>), kept in <c>Manifest</c>, which the CLI and agents change.</summary>
public sealed record FolioSet(string Name, string Manifest, List<SetFile> Files)
{
    /// <summary>The file to show after the set changed: the one shown before when it is still in the set, by
    /// id, else the first. Never falls back because the list was rebuilt.</summary>
    public SetFile? Keep(string? shownId) => Files.FirstOrDefault(f => f.Id == shownId) ?? Files.FirstOrDefault();

    /// <summary>The set's file at <paramref name="path"/>, if it has it.</summary>
    public SetFile? Find(string path) => Files.FirstOrDefault(f => SamePath(f.Path, path));

    /// <summary>Whether two paths name the same file: as full paths, ignoring case on Windows, whose file names do.</summary>
    public static bool SamePath(string a, string b) =>
        string.Equals(System.IO.Path.GetFullPath(a), System.IO.Path.GetFullPath(b),
                      OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}
