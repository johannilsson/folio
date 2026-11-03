using System.Diagnostics;

namespace Folio.Core.Tests;

/// <summary>A throwaway folder with a markdown file in it, and the real CLI to write annotations as an agent does.</summary>
sealed class Fixture : IDisposable
{
    readonly string dir = Directory.CreateTempSubdirectory("folio-core-").FullName;

    public string File { get; }

    public Fixture(string markdown, string name = "doc.md")
    {
        File = Path.Combine(dir, name);
        System.IO.File.WriteAllText(File, markdown);
    }

    /// <summary>The CLI (target/debug/folio), set by windows/verify.sh. Not found is a failure, not a skip.</summary>
    static string Cli => Environment.GetEnvironmentVariable("FOLIO_CLI") is { Length: > 0 } cli && System.IO.File.Exists(cli)
        ? cli
        : throw new InvalidOperationException("FOLIO_CLI must name the folio CLI binary; run windows/verify.sh");

    public string RunCli(params string[] args)
    {
        var start = new ProcessStartInfo(Cli) { RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = dir };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        Assert.True(process.ExitCode == 0, $"folio {string.Join(' ', args)} failed: {error}");
        return output.Trim();
    }

    public string Annotate(string kind, string contextBefore, string? target = null, string? replacement = null, string? comment = null)
    {
        var args = new List<string> { "annotate", File, "--kind", kind, "--context-before", contextBefore, "--author", "agent", "--source", "agent" };
        if (target is not null) args.AddRange(["--target", target]);
        if (replacement is not null) args.AddRange(["--replacement", replacement]);
        if (comment is not null) args.AddRange(["--comment", comment]);
        return RunCli(args.ToArray());
    }

    public void Dispose() { try { Directory.Delete(dir, recursive: true); } catch (IOException) { } }
}
