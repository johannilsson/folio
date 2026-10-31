namespace Folio.Core.Tests;

/// <summary>The engine's MCP switch and the ways to connect a tool, as the Windows client's Connect window uses them.</summary>
public class McpTests
{
    [Fact]
    public void Access_is_off_until_it_is_turned_on_and_can_be_turned_off_again()
    {
        // The engine keeps it in FOLIO_CONFIG_DIR, which only the process's start can set for it.
        Assert.True(Environment.GetEnvironmentVariable("FOLIO_CONFIG_DIR") is { Length: > 0 }, "FOLIO_CONFIG_DIR must name a throwaway folder; run windows/verify.sh");
        Assert.False(Engine.McpAllowed);
        Engine.SetMcpAllowed(true);
        Assert.True(Engine.McpAllowed);
        Engine.SetMcpAllowed(false);
        Assert.False(Engine.McpAllowed);
    }

    [Fact]
    public void Each_tool_gets_what_to_run_or_paste_with_this_programs_path()
    {
        var exe = Path.Combine(Path.GetTempPath(), "Folio", "Folio.Wpf.exe");
        var snippets = Engine.McpSnippets(exe);
        Assert.Equal(["Claude Code", "Claude Desktop", "Codex", "Other tools (JSON)", "Any MCP client"], snippets.Select(s => s.Name));
        Assert.All(snippets, s => Assert.Contains("--mcp", s.Text));
        // Add for Me only where Folio writes the tool's config, which it names.
        Assert.Equal([null, "claude", "codex", null, null], snippets.Select(s => s.Client));
        Assert.All(snippets.Where(s => s.Client is not null), s => Assert.False(string.IsNullOrEmpty(s.Config)));
        var desktop = System.Text.Json.Nodes.JsonNode.Parse(snippets[1].Text)!["mcpServers"]!["folio"]!;
        Assert.Equal(exe, desktop["command"]!.GetValue<string>());
    }
}

public class AppLinkTests
{
    [Fact]
    public async Task A_request_on_the_socket_reaches_the_answer_and_its_line_comes_back()
    {
        var config = Environment.GetEnvironmentVariable("FOLIO_CONFIG_DIR");
        Assert.True(config is { Length: > 0 }, "FOLIO_CONFIG_DIR must name a throwaway folder; run windows/verify.sh");
        var asked = new List<string>();
        Engine.AppListen(line =>
        {
            asked.Add(line.Trim());
            return "{\"ok\":{\"windows\":[{\"file\":\"ü.md\"}]}}";
        });
        try
        {
            // What the MCP server does (src/live.rs): one line out, one line back, on app.sock in the config folder.
            using var socket = new System.Net.Sockets.Socket(System.Net.Sockets.AddressFamily.Unix, System.Net.Sockets.SocketType.Stream, System.Net.Sockets.ProtocolType.Unspecified);
            await socket.ConnectAsync(new System.Net.Sockets.UnixDomainSocketEndPoint(Path.Combine(config, "app.sock")));
            using var stream = new System.Net.Sockets.NetworkStream(socket);
            using var writer = new StreamWriter(stream, new System.Text.UTF8Encoding(false)) { AutoFlush = true };
            using var reader = new StreamReader(stream, System.Text.Encoding.UTF8);
            await writer.WriteLineAsync("{\"op\":\"state\"}");
            var answer = await reader.ReadLineAsync();
            Assert.Equal("{\"ok\":{\"windows\":[{\"file\":\"ü.md\"}]}}", answer);
            Assert.Equal(["{\"op\":\"state\"}"], asked);
            // A second Folio does not take the socket from this one.
            Assert.Throws<EngineException>(() => Engine.AppListen(_ => "{}"));
        }
        finally { Engine.AppStop(); }
        Assert.False(File.Exists(Path.Combine(config, "app.sock")));
    }

    [Fact]
    public void A_set_finds_its_file_by_path()
    {
        var dir = Path.Combine(Path.GetTempPath(), "set");
        var file = new SetFile("a", "a.md", "set", Path.Combine(dir, "a.md"), Path.Combine(dir, ".folio", "a.md.folio"));
        var set = new FolioSet("s", "m", [file]);
        Assert.Same(file, set.Find(Path.Combine(dir, "sub", "..", "a.md")));
        Assert.Null(set.Find(Path.Combine(dir, "b.md")));
        Assert.Equal(OperatingSystem.IsWindows(), set.Find(Path.Combine(dir, "A.MD")) is not null);
    }
}
