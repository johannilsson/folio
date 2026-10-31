using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Folio.Core;
using Folio.Core.Preview;

namespace Folio.Wpf;

/// <summary>Drives the real window against throwaway files in a set made with the real CLI, the way the macOS app's
/// self-test does: what an agent writes shows up, the buttons change the files, and what is visible (the rendered
/// text, the marks, the cards, the scroll position) is what the files say. Writes a line per check to the result file
/// and exits non-zero on a failure. Needs a desktop session. <c>FOLIO_CLI</c> names the CLI, <c>FOLIO_CONFIG_DIR</c>
/// a throwaway folder for the set; <c>FOLIO_SNAPSHOT</c> is a path to save pictures under.</summary>
static class SelfTest
{
    // CRLF, as a file from Windows has it, and long enough to scroll.
    static readonly string Markdown = string.Join("\r\n", [
        "---", "title: Self-test", "---", "# Self-test", "",
        "The **quick** brown fox jumps over the lazy dog.", "",
        "Natural *wine* is made with minimal intervention.", "",
        "- first item", "- second item", "",
        "| Name | Note |", "|---|---|", "| alpha | a cell note |", "",
        "```js", "let code = 1;", "```", "",
        "```mermaid", "graph LR", "  A[Draft] --> B[Review]", "```", "",
        .. Enumerable.Range(1, 40).SelectMany(i => new[] { $"Filler paragraph {i}.", "" }),
        "The last paragraph.", ""]);

    public static async Task Run(MainWindow window, string resultFile)
    {
        var log = new StringBuilder();
        var failures = 0;
        var checks = new Checks(log, () => failures++);
        var snapshot = Environment.GetEnvironmentVariable("FOLIO_SNAPSHOT") is { Length: > 0 } s ? Path.GetFullPath(s) : null;
        var dir = Directory.CreateTempSubdirectory("folio-selftest-").FullName;
        var doc = Path.Combine(dir, "doc.md");
        var notes = Path.Combine(dir, "notes.md");
        var third = Path.Combine(dir, "third.md");
        File.WriteAllText(doc, Markdown);
        File.WriteAllText(notes, "# Notes\r\n\r\nA second file in the set.\r\n");
        File.WriteAllText(third, "# Third\r\n");
        var setName = $"selftest-{Environment.ProcessId}";

        void Finish(int code)
        {
            File.WriteAllText(resultFile, log.ToString() + (failures == 0 && code == 0 ? "✓ all checks passed\n" : "✗ failed\n"));
            Application.Current.Shutdown(code);
        }
        _ = Task.Delay(TimeSpan.FromMinutes(3)).ContinueWith(_ => Application.Current.Dispatcher.Invoke(() => { log.AppendLine("✗ timed out"); Finish(2); }));

        try
        {
            That(Environment.GetEnvironmentVariable("FOLIO_CONFIG_DIR") is { Length: > 0 }, "FOLIO_CONFIG_DIR must name a throwaway folder for the set");
            var replace = Cli("annotate", doc, "--kind", "replace", "--context-before", "The ", "--target", "quick", "--replacement", "slow");
            var delete = Cli("annotate", doc, "--kind", "delete", "--context-before", "over the ", "--target", "lazy ");
            var comment = Cli("annotate", doc, "--kind", "comment", "--context-before", "Natural ", "--target", "wine", "--comment", "Which one?");
            var highlight = Cli("annotate", doc, "--kind", "highlight", "--context-before", "alpha", "--target", "a cell note");
            Cli("set", "add", setName, doc, notes);
            window.OpenSet(setName);
            await Settle();

            await checks.Check("the set's files are in the sidebar, and the first is shown", () =>
            {
                That(window.Sidebar.Items.Count == 2, $"{window.Sidebar.Items.Count} files in the sidebar");
                That(window.ShownFile?.Name == "doc.md", $"shown: {window.ShownFile?.Name}");
                That(window.Sidebar.SelectedItem is ListBoxItem { Tag: SetFile { Name: "doc.md" } }, "the shown file is not the one selected in the sidebar");
            });

            await checks.Check("the preview shows the rendered text, not the markdown", () =>
            {
                var text = window.VisibleText;
                foreach (var markup in new[] { "**", "# Self", "|---", "```", "- first" })
                    That(!text.Contains(markup, StringComparison.Ordinal), $"\"{markup}\" is shown");
                foreach (var words in new[] { "Self-test", "brown fox jumps", "first item", "a cell note", "let code = 1;", "The last paragraph." })
                    That(text.Contains(words, StringComparison.Ordinal), $"\"{words}\" is not shown");
                MapIsTrue(window);
                // The text keeps its margin from the edge of its column (the sidebar may be hidden).
                var left = window.Rendered!.Pointer(window.Preview!.Text.IndexOf("Natural", StringComparison.Ordinal), forward: true)!
                    .GetCharacterRect(LogicalDirection.Forward).Left;
                That(left >= 24, $"the text starts {left:0} from the edge of its column");
            });

            await checks.Check("a card for each pending annotation, in document order", () =>
            {
                That(window.Shown.Select(p => p.Annotation.Id).SequenceEqual([replace, delete, comment, highlight]), $"cards: {string.Join(", ", window.Shown.Select(p => p.Annotation.Id))}");
                That(window.Cards.Count == 4, $"{window.Cards.Count} cards shown");
            });

            await checks.Check("every mark covers exactly its target, in the table too", () => MarksCoverTargets(window, 4));

            await checks.Check("a suggestion shows its replacement after the text it replaces", () =>
            {
                That(window.Rendered!.Ghosts.TryGetValue(replace, out var ghost), "no preview of the replacement");
                That(ghost!.Text == "slow", $"the preview says \"{ghost.Text}\"");
                var marked = window.Shown.Single(x => x.Annotation.Id == replace);
                That(ghost.ElementStart.CompareTo(window.Rendered.Pointer(marked.To!.Value, forward: false)) >= 0, "the preview is not after the text");
            });

            await checks.Check("cards sit beside their text, in order, without overlapping", () => CardsBesideText(window));

            await checks.Check("a mermaid block is drawn as a picture by the hidden page, not shown as its source", async () =>
            {
                await WaitFor(() => window.Diagrams.Values.Any(d => d is not null), "the diagram was not drawn", seconds: 30);
                That(!window.VisibleText.Contains("A[Draft]", StringComparison.Ordinal), "the diagram's source is still shown");
                var picture = window.Rendered!.Entries.Select(e => e.Element).OfType<InlineUIContainer>()
                    .Select(c => c.Child).OfType<Image>().Select(i => i.Source).OfType<BitmapSource>().FirstOrDefault(b => b.PixelWidth > 40);
                That(picture is not null, "no picture of the diagram in the text");
                MapIsTrue(window);
                CardsBesideText(window);
            });

            await checks.Check("code with a language is coloured by the hidden page, as the macOS app colours it", async () =>
            {
                await WaitFor(() => window.Highlighted > 0, "the code was not coloured", seconds: 30);
                foreach (var (word, syntax) in new[] { ("let", Syntax.Keyword), ("1", Syntax.Number) })
                {
                    var entry = window.Rendered!.Entries.FirstOrDefault(e => e.IsRun && e.Piece.Text == word && e.Piece.Scope is not null);
                    That(entry.Element is Run, $"\"{word}\" is not a coloured piece of its own");
                    That(entry.Element.Foreground == Look.Code(syntax), $"\"{word}\" is not in the colour of a {syntax}");
                }
                MapIsTrue(window);
            });

            Snapshot(window, snapshot, "before");

            await checks.Check("accepting a replacement patches the file, keeps its line endings and re-marks the rest", async () =>
            {
                Click(window.Cards[replace].Accept);
                await WaitFor(() => !window.Cards.ContainsKey(replace), "the card is still there");
                var text = File.ReadAllText(doc);
                That(text.Contains("The **slow** brown fox", StringComparison.Ordinal), "the file was not patched");
                That(!text.Replace("\r\n", "").Contains('\n'), "a line ending changed");
                MarksCoverTargets(window, 3);
            });

            await checks.Check("dismissing a comment resolves it and leaves the text alone", async () =>
            {
                var before = File.ReadAllText(doc);
                Click(window.Cards[comment].Accept);
                await WaitFor(() => !window.Cards.ContainsKey(comment), "the card is still there");
                That(File.ReadAllText(doc) == before, "the file changed");
                That(Sidecar.Parse(window.File!.ReadSidecar()).Single(a => a.Id == comment).ResolvedAs == "dismissed", "not dismissed");
            });

            await checks.Check("an agent's reply shows in the thread, and the focused card takes the reader's reply under it", async () =>
            {
                // An agent replies through the engine, as the MCP server does; the CLI has no reply command.
                var file = window.File!;
                var agent = new System.Text.Json.Nodes.JsonObject
                {
                    ["op"] = "reply", ["id"] = highlight, ["body"] = "Should this note say more?", ["author"] = "agent", ["source"] = "agent",
                };
                File.WriteAllText(file.SidecarPath, Engine.Edit(file.ReadSidecar(), agent).Sidecar);
                await WaitFor(() => window.Shown.Single(x => x.Annotation.Id == highlight).Annotation.Replies?.Count == 1, "the agent's reply did not show");

                window.FocusAnnotation(highlight, reveal: true);
                var card = window.Cards[highlight];
                That(card.ReplyBox is not null, "the focused card has no reply field");
                card.ReplyBox!.Text = "Agreed, I will expand it.";
                Click(card.ReplyButton!);
                await WaitFor(() => window.Shown.Single(x => x.Annotation.Id == highlight).Annotation.Replies?.Count == 2, "the reply did not arrive");
                var replies = window.Shown.Single(x => x.Annotation.Id == highlight).Annotation.Replies!;
                That((replies[0].Author, replies[1].Author, replies[1].Source, replies[1].Body) == ("agent", "me", "local", "Agreed, I will expand it."),
                     $"thread: {string.Join(" / ", replies.Select(r => $"{r.Author}: {r.Body}"))}");
                That(window.Focused == highlight && window.Cards[highlight].ReplyBox is not null, "the card lost its focus after the reply");
                That(window.Cards[highlight].ActualHeight > 0 && window.Cards[highlight].ActualHeight > window.Cards.Values.Where(c => c != window.Cards[highlight]).Max(c => c.ActualHeight),
                     "the focused card with its thread is not the tallest");
                CardsBesideText(window);
                Snapshot(window, snapshot, "thread");
            });

            string? mine = null;
            await checks.Check("selecting text shows the Comment button, and its form adds a comment on those words", async () =>
            {
                window.FocusAnnotation(null, reveal: false);
                var at = window.Preview!.Text.IndexOf("brown fox", StringComparison.Ordinal);
                window.Select(at, at + "brown fox".Length);
                That(window.Text.Selection.Text == "brown fox", $"selected \"{window.Text.Selection.Text}\"");
                That(window.Adder.Visibility == Visibility.Visible, "no Comment button");
                var left = Canvas.GetLeft(window.Adder);
                That(left >= 0 && left + window.Adder.ActualWidth <= window.Text.ActualWidth + 1, $"the button is outside the text column (x {left})");
                Click(window.Adder);
                That(window.Form is not null, "no form");
                That(window.Text.Selection.Text == "brown fox", "the selection was lost");
                window.Form!.Box.Text = "Nice phrase";
                Click(window.Form.Add);
                await WaitFor(() => window.Shown.Any(x => x.Annotation.Comment == "Nice phrase"), "the comment did not arrive");
                var added = window.Shown.Single(x => x.Annotation.Comment == "Nice phrase");
                mine = added.Annotation.Id;
                That((added.Annotation.Target, added.Annotation.Author) == ("brown fox", "me"), $"anchored to \"{added.Annotation.Target}\" by {added.Annotation.Author}");
                That(window.Form is null, "the form is still open");
                MarksCoverTargets(window, 3);
            });

            await checks.Check("an annotation an agent adds shows up without a click", async () =>
            {
                var added = Cli("annotate", doc, "--kind", "comment", "--context-before", "The last ", "--target", "paragraph", "--comment", "Cut?", "--author", "agent");
                await WaitFor(() => window.Cards.ContainsKey(added), "the new card did not appear");
                MarksCoverTargets(window, 4);
                CardsBesideText(window);
            });

            await checks.Check("the sidebar can be hidden and shown again; the text reflows and the shown file stays", () =>
            {
                That(window.SidebarShown, "the sidebar is not shown for a set");
                var width = window.Text.ActualWidth;
                Click(window.SidebarToggle);
                That(!window.SidebarShown, "the sidebar is still shown");
                That(window.Text.ActualWidth > width + 100, $"the text did not take the room ({width:0} to {window.Text.ActualWidth:0})");
                That(window.ShownFile?.Name == "doc.md", $"the window went to {window.ShownFile?.Name}");
                MarksCoverTargets(window, 4);
                CardsBesideText(window);
                Snapshot(window, snapshot, "sidebar-hidden");
                Click(window.SidebarToggle);
                That(window.SidebarShown, "the sidebar did not come back");
                That(window.Sidebar.SelectedItem is ListBoxItem { Tag: SetFile { Name: "doc.md" } }, "the sidebar selection moved");
                CardsBesideText(window);
            });

            await checks.Check("switching files in the sidebar shows the other file, and coming back returns to where it was", async () =>
            {
                window.ScrollTo(600);
                var before = window.ScrollOffset;
                That(before > 100, $"the text could not be scrolled (offset {before})");
                Pick(window, "notes.md");
                await WaitFor(() => window.ShownFile?.Name == "notes.md", "the other file is not shown");
                That(window.VisibleText.Contains("A second file in the set.", StringComparison.Ordinal), "its text is not shown");
                That(window.Cards.Count == 0, $"{window.Cards.Count} cards for a file without annotations");
                Pick(window, "doc.md");
                await WaitFor(() => window.ShownFile?.Name == "doc.md", "the first file is not shown again");
                That(Math.Abs(window.ScrollOffset - before) < 5, $"came back at {window.ScrollOffset}, not {before}");
            });

            await checks.Check("a set changed from outside keeps showing the same file", async () =>
            {
                Cli("set", "add", setName, third);
                await WaitFor(() => window.Sidebar.Items.Count == 3, "the sidebar did not get the new file");
                await Settle();
                That(window.ShownFile?.Name == "doc.md", $"the window went to {window.ShownFile?.Name}");
                That(window.Sidebar.SelectedItem is ListBoxItem { Tag: SetFile { Name: "doc.md" } }, "the sidebar selection moved");
            });

            await checks.Check("a refresh keeps the scroll position", async () =>
            {
                window.ScrollTo(400);
                var before = window.ScrollOffset;
                var second = Cli("annotate", doc, "--kind", "comment", "--context-before", "Filler paragraph 30", "--target", ".", "--comment", "Here", "--author", "agent");
                await WaitFor(() => window.Cards.ContainsKey(second), "the new card did not appear");
                That(Math.Abs(window.ScrollOffset - before) < 5, $"scrolled from {before} to {window.ScrollOffset}");
            });

            await checks.Check("an edit from outside parks an annotation that is no longer there, without moving the text", async () =>
            {
                var scrolled = window.ScrollOffset;
                File.WriteAllText(doc, File.ReadAllText(doc).Replace("lazy ", ""));
                await WaitFor(() => window.Cards.TryGetValue(delete, out var card) && card.NotFound, "the card was not marked as not found");
                That(!window.Shown.Single(x => x.Annotation.Id == delete).Marked, "the lost annotation is still marked");
                That(Math.Abs(window.ScrollOffset - scrolled) < 5, $"the refresh drew the text at {window.ScrollOffset}, not {scrolled}");
            });

            Snapshot(window, snapshot, "after");

            await checks.Check("MCP clients get in only once the person allows it, in the MCP… window, and can be shut out again", async () =>
            {
                // Add for Me writes these, not the runner's own configs.
                var claudeConfig = Path.Combine(dir, "claude_desktop_config.json");
                Environment.SetEnvironmentVariable("FOLIO_CLAUDE_CONFIG", claudeConfig);
                Environment.SetEnvironmentVariable("CODEX_HOME", dir);
                That(!Engine.McpAllowed, "MCP clients are allowed before anyone allowed them");
                var connect = window.OpenConnect();
                That(connect.Allow.IsChecked == false, "the Allow box is ticked");
                connect.Tools.SelectedIndex = 1;   // Claude Desktop
                That(connect.AddButton.IsVisible && !connect.AddButton.IsEnabled, "Add for Me does not wait for the Allow box");

                // A tool that was set up before starts the server, which answers but lets nothing in.
                using var server = await McpServer.Start(Environment.ProcessPath!);
                That(server.Hello?["result"]?["serverInfo"]?["name"]?.GetValue<string>() == "folio", "the server did not say hello");
                var off = await server.Tool("render", new() { ["file"] = doc });
                That(off.IsError && off.Text.Contains("Allow MCP Clients", StringComparison.Ordinal), $"while off, render answered: {off.Text}");

                connect.Allow.IsChecked = true;
                Click(connect.Allow);
                That(Engine.McpAllowed && connect.AddButton.IsEnabled, "ticking Allow did not let clients in");
                var on = await server.Tool("render", new() { ["file"] = doc });
                That(!on.IsError && on.Text.Contains("The last paragraph.", StringComparison.Ordinal), $"the running server did not let it in: {on.Text}");

                Click(connect.AddButton);
                That(connect.Status.Text.StartsWith("Added to", StringComparison.Ordinal), $"Add for Me said: {connect.Status.Text}");
                var entry = System.Text.Json.Nodes.JsonNode.Parse(File.ReadAllText(claudeConfig))!["mcpServers"]!["folio"]!;
                That(entry["command"]!.GetValue<string>() == Environment.ProcessPath && entry["args"]![0]!.GetValue<string>() == "--mcp",
                     $"Claude's entry: {entry.ToJsonString()}");
                connect.UpdateLayout();
                Snapshot(connect, snapshot, "mcp");

                connect.Allow.IsChecked = false;
                Click(connect.Allow);
                var shut = await server.Tool("render", new() { ["file"] = doc });
                That(!Engine.McpAllowed && shut.IsError && shut.Text.Contains("Allow MCP Clients", StringComparison.Ordinal), "unticking Allow did not shut clients out");
                That(await server.Close() == 0 && server.StrayLines == 0, "the server did not end cleanly, or said something besides the protocol");
                connect.Close();
            });
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

    /// <summary>Every run of the document shows the text of its piece, and that is the preview's text at its offsets.</summary>
    static void MapIsTrue(MainWindow window)
    {
        var preview = window.Preview!;
        foreach (var entry in window.Rendered!.Entries.Where(e => e.IsRun))
        {
            var run = (Run)entry.Element;
            That(run.Text == entry.Piece.Text, $"a run shows \"{run.Text}\", its piece is \"{entry.Piece.Text}\"");
            That(preview.Text.Substring(entry.Piece.Start, entry.Piece.Text.Length) == entry.Piece.Text, $"\"{entry.Piece.Text}\" is not at {entry.Piece.Start}");
        }
    }

    /// <summary>What a person sees marked is what the annotation points at, and it is drawn marked.</summary>
    static void MarksCoverTargets(MainWindow window, int expected)
    {
        var marked = window.Shown.Where(x => x.Marked).ToList();
        That(marked.Count == expected, $"{marked.Count} marks, expected {expected}");
        foreach (var x in marked)
        {
            var range = new TextRange(window.Rendered!.Pointer(x.From!.Value, forward: true)!, window.Rendered.Pointer(x.To!.Value, forward: false)!);
            That(range.Text == x.Annotation.Target, $"{x.Annotation.Id} marks \"{range.Text}\", its target is \"{x.Annotation.Target}\"");
            var runs = window.Rendered.Entries.Where(e => e.Piece.Marks.Contains(x.Annotation.Id)).ToList();
            That(runs.Count > 0 && runs.All(e => e.Element.Background is not null), $"{x.Annotation.Id} is not drawn marked");
        }
    }

    /// <summary>A card is at its text's top minus 4, or pushed down below the card above it; never overlapping it.</summary>
    static void CardsBesideText(MainWindow window)
    {
        double? bottom = null;
        foreach (var x in window.Shown.Where(x => x.Placed.Found))
        {
            var (anchor, top) = (window.AnchorTop(x.Annotation.Id), window.CardTop(x.Annotation.Id));
            That(!double.IsNaN(anchor) && !double.IsNaN(top), $"{x.Annotation.Id} has no anchor or card");
            That(top >= anchor - 4 - 0.5, $"{x.Annotation.Id}: card at {top:0}, above its text at {anchor:0}");
            That(bottom is null || top >= bottom.Value + 6 - 0.5, $"{x.Annotation.Id}: card at {top:0} overlaps the one above (ends at {bottom:0})");
            That(Math.Abs(top - (anchor - 4)) < 0.5 || bottom is not null && Math.Abs(top - (bottom.Value + 6)) < 0.5, $"{x.Annotation.Id}: card at {top:0}, its text at {anchor:0}");
            bottom = top + window.Cards[x.Annotation.Id].ActualHeight;
        }
    }

    static void Pick(MainWindow window, string name) =>
        window.Sidebar.SelectedItem = window.Sidebar.Items.OfType<ListBoxItem>().First(i => ((SetFile)i.Tag).Name == name);

    static void Click(ButtonBase button) => button.RaiseEvent(new RoutedEventArgs(ButtonBase.ClickEvent));

    /// <summary>Lets layout and the poll timer run.</summary>
    static Task Settle() => Task.Delay(400);

    static async Task WaitFor(Func<bool> condition, string failure, int seconds = 5)
    {
        for (var i = 0; i < seconds * 20 && !condition(); i++) await Task.Delay(50);
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

    static void Snapshot(Window window, string? basePath, string name)
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

    /// <summary>The app's own MCP server (<c>Folio.Wpf.exe --mcp</c>) spoken to over its pipes, as a tool such as Claude
    /// Desktop does.</summary>
    sealed class McpServer : IDisposable
    {
        readonly Process process;
        int lastId;

        public System.Text.Json.Nodes.JsonNode? Hello { get; private set; }
        /// <summary>Lines on stdout that were not responses: that channel has to carry nothing else.</summary>
        public int StrayLines { get; private set; }

        McpServer(Process process) => this.process = process;

        public static async Task<McpServer> Start(string exe)
        {
            var start = new ProcessStartInfo(exe, "--mcp")
            {
                RedirectStandardInput = true, RedirectStandardOutput = true, CreateNoWindow = true,
                StandardOutputEncoding = new UTF8Encoding(false),
            };
            var server = new McpServer(Process.Start(start)!);
            server.process.StandardInput.AutoFlush = true;
            server.Hello = await server.Call("initialize", new()
            {
                ["protocolVersion"] = "2025-06-18", ["capabilities"] = new System.Text.Json.Nodes.JsonObject(),
                ["clientInfo"] = new System.Text.Json.Nodes.JsonObject { ["name"] = "selftest", ["version"] = "1" },
            });
            await server.process.StandardInput.WriteLineAsync("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
            return server;
        }

        public async Task<System.Text.Json.Nodes.JsonNode?> Call(string method, System.Text.Json.Nodes.JsonObject parameters)
        {
            var id = ++lastId;
            var request = new System.Text.Json.Nodes.JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["method"] = method, ["params"] = parameters };
            await process.StandardInput.WriteLineAsync(request.ToJsonString());
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            while (await process.StandardOutput.ReadLineAsync(timeout.Token) is string line)
            {
                System.Text.Json.Nodes.JsonNode? reply = null;
                try { reply = System.Text.Json.Nodes.JsonNode.Parse(line); } catch (System.Text.Json.JsonException) { }
                if (reply?["id"]?.GetValue<int>() == id) return reply;
                StrayLines++;
            }
            return null;
        }

        public async Task<(bool IsError, string Text)> Tool(string name, System.Text.Json.Nodes.JsonObject arguments)
        {
            var reply = await Call("tools/call", new() { ["name"] = name, ["arguments"] = arguments });
            var result = reply?["result"];
            return (result?["isError"]?.GetValue<bool>() == true, result?["content"]?[0]?["text"]?.GetValue<string>() ?? reply?.ToJsonString() ?? "no answer");
        }

        /// <summary>Closes its input, which ends the server; its exit code.</summary>
        public async Task<int> Close()
        {
            process.StandardInput.Close();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            await process.WaitForExitAsync(timeout.Token);
            return process.ExitCode;
        }

        public void Dispose()
        {
            if (!process.HasExited) process.Kill();
            process.Dispose();
        }
    }
}
