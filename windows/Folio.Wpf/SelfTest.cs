using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Folio.Core;

namespace Folio.Wpf;

/// <summary>Drives the real window against a throwaway copy of a file and the real CLI, the way the macOS app's
/// self-test does: what an agent writes shows up, the buttons change the files, and the text and marks that
/// are visible are what the files say. Writes a line per check to the result file and exits non-zero on a failure.
/// Needs a desktop session. <c>FOLIO_CLI</c> names the CLI; <c>FOLIO_SNAPSHOT</c> is a path to save pictures under.</summary>
static class SelfTest
{
    // CRLF, as a file from Windows has it, and long enough to scroll.
    static readonly string Markdown = string.Join("\r\n",
        ["# Self-test", "", "The quick brown fox jumps over the lazy dog.", "", "Natural wine is made with minimal intervention.", "", .. Enumerable.Range(1, 60).Select(i => $"Filler line {i}."), "", "The last paragraph.", ""]);

    public static async Task Run(MainWindow window, string resultFile)
    {
        var log = new StringBuilder();
        var failures = 0;
        var checks = new Checks(log, () => failures++);
        var snapshot = Environment.GetEnvironmentVariable("FOLIO_SNAPSHOT") is { Length: > 0 } s ? Path.GetFullPath(s) : null;
        var dir = Directory.CreateTempSubdirectory("folio-selftest-").FullName;
        var path = Path.Combine(dir, "doc.md");
        File.WriteAllText(path, Markdown);

        void Finish(int code)
        {
            File.WriteAllText(resultFile, log.ToString() + (failures == 0 && code == 0 ? "✓ all checks passed\n" : "✗ failed\n"));
            Application.Current.Shutdown(code);
        }
        _ = Task.Delay(TimeSpan.FromMinutes(2)).ContinueWith(_ => Application.Current.Dispatcher.Invoke(() => { log.AppendLine("✗ timed out"); Finish(2); }));

        try
        {
            var replace = Cli("annotate", path, "--kind", "replace", "--context-before", "The ", "--target", "quick", "--replacement", "slow");
            var delete = Cli("annotate", path, "--kind", "delete", "--context-before", "over the ", "--target", "lazy ");
            var comment = Cli("annotate", path, "--kind", "comment", "--context-before", "Natural ", "--target", "wine", "--comment", "Which one?");
            window.Open(path);
            await Settle();

            await checks.Check("the window shows the file's text", () =>
                That(Flat(window.VisibleText) == Flat(Markdown), "the text shown differs from the file"));

            await checks.Check("a card for each pending annotation, in document order", () =>
            {
                That(window.Shown.Select(p => p.Annotation.Id).SequenceEqual([replace, delete, comment]), $"cards: {string.Join(", ", window.Shown.Select(p => p.Annotation.Id))}");
                That(window.CardsById.Count == 3, $"{window.CardsById.Count} cards shown");
            });

            await checks.Check("every mark covers exactly its target", () => MarksCoverTargets(window, 3));

            Snapshot(window, snapshot, "before");

            await checks.Check("accepting a replacement patches the file, keeps its line endings and re-marks the rest", () =>
            {
                Click(window.CardsById[replace].Accept);
                var text = File.ReadAllText(path);
                That(text.Contains("The slow brown fox") && !text.Contains("quick"), "the file was not patched");
                That(!Regex.IsMatch(text, "(?<!\r)\n"), "a bare line feed was written into a CRLF file");
                That(window.VisibleText.Contains("The slow brown fox"), "the text shown was not updated");
                That(!window.CardsById.ContainsKey(replace), "the accepted card is still there");
                MarksCoverTargets(window, 2);
            });

            await checks.Check("dismissing a comment resolves it and leaves the text alone", () =>
            {
                var before = File.ReadAllText(path);
                Click(window.CardsById[comment].Accept);
                That(File.ReadAllText(path) == before, "the file changed");
                var resolved = Sidecar.Parse(File.ReadAllText(Engine.SidecarPath(path))).Single(a => a.Id == comment);
                That(resolved is { Resolved: true, ResolvedAs: "dismissed" }, $"resolved as {resolved.ResolvedAs}");
                That(!window.CardsById.ContainsKey(comment), "the dismissed card is still there");
            });

            string added = "";
            await checks.Check("an annotation an agent adds shows up without a click", async () =>
            {
                added = Cli("annotate", path, "--kind", "comment", "--context-before", "The last ", "--target", "paragraph", "--comment", "Cut?", "--author", "agent");
                await WaitFor(() => window.CardsById.ContainsKey(added), "the new card did not appear");
                MarksCoverTargets(window, 2);
            });

            await checks.Check("a refresh keeps the scroll position", async () =>
            {
                window.ScrollTo(400);
                await Settle();
                var before = window.ScrollOffset;
                That(before > 100, $"the text could not be scrolled (offset {before})");
                var second = Cli("annotate", path, "--kind", "comment", "--context-before", "Filler line 30", "--target", ".", "--comment", "Here", "--author", "agent");
                await WaitFor(() => window.CardsById.ContainsKey(second), "the new card did not appear");
                await Settle();
                That(Math.Abs(window.ScrollOffset - before) < 5, $"scrolled from {before} to {window.ScrollOffset}");
            });

            await checks.Check("an edit from outside parks an annotation that is no longer there, without moving the text", async () =>
            {
                var scrolled = window.ScrollOffset;
                File.WriteAllText(path, File.ReadAllText(path).Replace("lazy ", ""));
                await WaitFor(() => window.CardsById.TryGetValue(delete, out var card) && card.NotFound, "the card was not marked as not found");
                That(!window.Marked.Any(m => m.Placed.Annotation.Id == delete), "the lost annotation is still marked");
                That(Math.Abs(window.ScrollOffset - scrolled) < 5, $"the refresh drew the text at {window.ScrollOffset}, not {scrolled}");
            });

            Snapshot(window, snapshot, "after");
        }
        catch (Exception e) { failures++; log.AppendLine("✗ " + e); }
        Finish(failures == 0 ? 0 : 1);
    }

    sealed class Checks(StringBuilder log, Action failed)
    {
        public Task Check(string name, Action body) => Check(name, () => { body(); return Task.CompletedTask; });

        public async Task Check(string name, Func<Task> body)
        {
            try { await body(); log.AppendLine("✓ " + name); }
            catch (Exception e) { failed(); log.AppendLine($"✗ {name}: {e.Message}"); }
        }
    }

    static void That(bool ok, string message) { if (!ok) throw new InvalidOperationException(message); }

    /// <summary>Text without its line breaks: the blocks of the view and the lines of the file break differently.</summary>
    static string Flat(string text) => text.Replace("\r", "").Replace("\n", "");

    /// <summary>What a person sees marked is what the annotation points at.</summary>
    static void MarksCoverTargets(MainWindow window, int expected)
    {
        That(window.Marked.Count == expected, $"{window.Marked.Count} marks, expected {expected}");
        foreach (var (placed, range) in window.Marked)
            That(Flat(range.Text) == Flat(placed.Annotation.Target!), $"{placed.Annotation.Id} marks \"{Flat(range.Text)}\", its target is \"{placed.Annotation.Target}\"");
    }

    static void Click(ButtonBase button) => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    /// <summary>Lets layout and the poll timer run.</summary>
    static Task Settle() => Task.Delay(300);

    static async Task WaitFor(Func<bool> condition, string failure)
    {
        for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(50);
        That(condition(), failure);
    }

    /// <summary>Runs the CLI, as an agent does, and returns what it printed.</summary>
    static string Cli(params string[] args)
    {
        var exe = Environment.GetEnvironmentVariable("FOLIO_CLI") is { Length: > 0 } cli ? cli : throw new InvalidOperationException("FOLIO_CLI must name the folio CLI binary");
        var start = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var arg in args) start.ArgumentList.Add(arg);
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEnd();
        var error = process.StandardError.ReadToEnd();
        process.WaitForExit();
        That(process.ExitCode == 0, $"folio {string.Join(' ', args)} failed: {error}");
        return output.Trim();
    }

    static void Snapshot(MainWindow window, string? basePath, string name)
    {
        if (basePath is null) return;
        window.UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)window.ActualWidth, (int)window.ActualHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory(Path.GetDirectoryName($"{basePath}-{name}.png")!);
        using var stream = File.Create($"{basePath}-{name}.png");
        encoder.Save(stream);
    }
}
