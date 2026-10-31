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
