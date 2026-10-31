using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Folio.Core;

namespace Folio.Wpf;

/// <summary>The MCP… button: whether MCP clients may read and annotate documents (off until the person turns it on,
/// the same switch as the macOS app's Folio ▸ Allow MCP Clients), and how to connect a tool to this program's MCP
/// server: pick the tool to see what to run or paste, Copy it, or for Claude Desktop and Codex let Folio write it into
/// their config (Add for Me), which only works while clients are allowed.</summary>
sealed class ConnectWindow : Window
{
    readonly string exe;
    readonly List<McpSnippet> snippets;

    public CheckBox Allow { get; }
    public ComboBox Tools { get; }
    public TextBox Text { get; }
    public Button AddButton { get; }
    public TextBlock Status { get; }
    readonly TextBlock hint = new() { TextWrapping = TextWrapping.Wrap, Foreground = Look.Secondary, Margin = new Thickness(0, 6, 0, 6) };

    public ConnectWindow(string exe)
    {
        this.exe = exe;
        snippets = Engine.McpSnippets(exe);
        Title = "Connect MCP clients to Folio";
        Width = 560;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        Background = Brushes.White;

        Allow = new CheckBox { Content = "Allow MCP clients to read and annotate documents", IsChecked = Engine.McpAllowed, FontWeight = FontWeights.SemiBold };
        Allow.Click += (_, _) => SetAllowed(Allow.IsChecked == true);
        Tools = new ComboBox { ItemsSource = snippets.Select(s => s.Name).ToList(), SelectedIndex = 0, Width = 240, HorizontalAlignment = HorizontalAlignment.Left };
        Tools.SelectionChanged += (_, _) => ShowTool(Tools.SelectedIndex);
        Text = new TextBox
        {
            IsReadOnly = true, FontFamily = Look.Mono, FontSize = 12, TextWrapping = TextWrapping.Wrap, Height = 150,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var copy = new Button { Content = "Copy", Padding = new Thickness(12, 3, 12, 3), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Top };
        copy.Click += (_, _) => Clipboard.SetText(Text.Text);
        AddButton = new Button { Content = "Add for Me", Padding = new Thickness(12, 3, 12, 3), Margin = new Thickness(0, 0, 8, 0), VerticalAlignment = VerticalAlignment.Top };
        AddButton.Click += (_, _) => Add();
        Status = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Look.Secondary, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };

        var buttons = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
        DockPanel.SetDock(copy, Dock.Left);
        DockPanel.SetDock(AddButton, Dock.Left);
        buttons.Children.Add(copy);
        buttons.Children.Add(AddButton);
        buttons.Children.Add(Status);

        var body = new StackPanel { Margin = new Thickness(20) };
        body.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 12),
            Text = "Folio is an MCP server: a tool starts this program with --mcp. A tool can read and annotate your documents "
                   + "only while MCP clients are allowed, and you can turn that off again at any time.",
        });
        body.Children.Add(Allow);
        body.Children.Add(new Separator { Margin = new Thickness(0, 14, 0, 14) });
        body.Children.Add(Tools);
        body.Children.Add(hint);
        body.Children.Add(Text);
        body.Children.Add(buttons);
        Content = body;
        ShowTool(0);
    }

    /// <summary>Ticks or unticks Allow: kept in the config folder, where the server reads it at every tool call.</summary>
    void SetAllowed(bool on)
    {
        try { Engine.SetMcpAllowed(on); }
        catch (EngineException e) { Status.Text = e.Message; }
        Allow.IsChecked = Engine.McpAllowed;
        AddButton.IsEnabled = Engine.McpAllowed;
    }

    void ShowTool(int index)
    {
        if (index < 0 || index >= snippets.Count) return;
        var snippet = snippets[index];
        hint.Text = snippet.Hint;
        Text.Text = snippet.Text;
        var direct = snippet.Client is not null ? Visibility.Visible : Visibility.Collapsed;
        AddButton.Visibility = direct;
        AddButton.IsEnabled = Engine.McpAllowed;
        Status.Visibility = direct;
        Status.Foreground = Look.Secondary;
        Status.Text = $"Writes this into {snippet.Config ?? "its config"}, keeping everything else in the file.";
    }

    /// <summary>Add for Me: writes the selected tool's entry into its config and says what it did.</summary>
    void Add()
    {
        if (Tools.SelectedIndex < 0 || snippets[Tools.SelectedIndex] is not { Client: string client } snippet) return;
        try
        {
            var (config, change) = Engine.McpConnect(client, exe);
            Status.Text = change switch
            {
                "unchanged" => $"Already in {config}; nothing changed.",
                "added" => $"Added to {config}. Restart {snippet.Name} to use it.",
                _ => $"Updated in {config}. Restart {snippet.Name} to use it.",
            };
            Status.Foreground = Brushes.Black;
        }
        catch (EngineException e)
        {
            Status.Text = e.Message;
            Status.Foreground = Brushes.Firebrick;
        }
    }
}
