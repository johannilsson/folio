using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Threading;
using Folio.Core;
using Microsoft.Win32;

namespace Folio.Wpf;

/// <summary>One window, one file: the markdown as text with its annotations marked, and a card for each. The
/// file and its sidecar on disk are the state; <see cref="Refresh"/> draws everything from them again, and a
/// timer calls it when either changes.</summary>
public partial class MainWindow : Window
{
    static readonly Brush Purple = new SolidColorBrush(Color.FromArgb(0x66, 0xA7, 0x8B, 0xFA));
    static readonly Brush Red = new SolidColorBrush(Color.FromArgb(0x55, 0xEF, 0x44, 0x44));

    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMilliseconds(300) };
    ReviewFile? file;
    string stamp = "";

    // What the self-test looks at.
    internal List<Placed> Shown { get; private set; } = [];
    internal List<(Placed Placed, TextRange Range)> Marked { get; private set; } = [];
    internal Dictionary<string, Card> CardsById { get; } = [];
    internal double ScrollOffset => Text.VerticalOffset;
    internal void ScrollTo(double offset) => Text.ScrollToVerticalOffset(offset);
    internal string VisibleText => new TextRange(Text.Document.ContentStart, Text.Document.ContentEnd).Text;
    internal string Status => StatusText.Text;

    internal sealed record Card(FrameworkElement Element, Button Accept, Button Reject, bool NotFound);

    public MainWindow()
    {
        InitializeComponent();
        poll.Tick += (_, _) => { if (file is not null && file.Stamp() != stamp) Refresh(keepScroll: true); };
    }

    void OnOpen(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "Markdown (*.md;*.markdown)|*.md;*.markdown|All files|*.*" };
        if (dialog.ShowDialog(this) == true) Open(dialog.FileName);
    }

    public void Open(string path)
    {
        file = new ReviewFile(path);
        PathText.Text = file.Path;
        Refresh(keepScroll: false);
        poll.Start();
    }

    void Refresh(bool keepScroll)
    {
        if (file is null) return;
        var scroll = Text.VerticalOffset;
        try
        {
            stamp = file.Stamp();   // before reading, so a write in between shows up as another change
            var doc = file.ReadText();
            Shown = Review.Place(doc, Sidecar.Parse(file.ReadSidecar()));
            ShowText(doc);
            ShowCards();
            StatusText.Text = $"{Shown.Count} pending";
        }
        catch (Exception e) when (e is IOException or EngineException or System.Text.Json.JsonException)
        {
            StatusText.Text = e.Message;   // a half-written file: the next change draws it again
        }
        // Laid out now, not later: a callback after the next frame would draw one frame at the top first.
        if (keepScroll) { Text.UpdateLayout(); Text.ScrollToVerticalOffset(scroll); }
    }

    /// <summary>One block per line, so an offset of the engine is a line and a column. All positions are taken
    /// before anything is marked: a mark splits its run, and offsets counted after that would include the split.</summary>
    void ShowText(string doc)
    {
        var lines = Lines.Split(doc);
        var runs = lines.Select(l => new Run(doc.Substring(l.Start, l.Length))).ToList();
        var flow = new FlowDocument(new Paragraph()) { PagePadding = new Thickness(16) };
        flow.Blocks.Clear();
        foreach (var run in runs) flow.Blocks.Add(new Paragraph(run) { Margin = new Thickness(0) });
        Text.Document = flow;

        TextPointer At(int offset)
        {
            var (line, column) = Lines.Locate(lines, offset);
            return runs[line].ContentStart.GetPositionAtOffset(column)!;
        }
        Marked = Shown.Where(p => p.Found && p.To > p.From)
            .Select(p => (p, new TextRange(At(p.From!.Value), At(p.To!.Value)))).ToList();
        foreach (var (placed, range) in Marked)
        {
            var suggestion = placed.Annotation.Kind is "replace" or "delete";
            range.ApplyPropertyValue(TextElement.BackgroundProperty, suggestion ? Red : Purple);
            if (suggestion) range.ApplyPropertyValue(Inline.TextDecorationsProperty, TextDecorations.Strikethrough);
        }
    }

    void ShowCards()
    {
        Cards.Children.Clear();
        CardsById.Clear();
        foreach (var placed in Shown)
        {
            var card = MakeCard(placed);
            CardsById[placed.Annotation.Id] = card;
            Cards.Children.Add(card.Element);
        }
    }

    Card MakeCard(Placed placed)
    {
        var a = placed.Annotation;
        var accept = new Button { Content = a.IsComment ? "Dismiss" : "Accept", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(0, 0, 6, 0) };
        var reject = new Button { Content = "Reject", Padding = new Thickness(10, 2, 10, 2), Visibility = a.IsComment ? Visibility.Collapsed : Visibility.Visible };
        // A comment is dismissed, which resolves it like a rejection and changes no text.
        accept.Click += (_, _) => Act(() => { if (a.IsComment) file!.Reject(a.Id); else file!.Accept(a.Id); });
        reject.Click += (_, _) => Act(() => file!.Reject(a.Id));

        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = $"{a.Kind} · {a.Author}", FontWeight = FontWeights.SemiBold });
        body.Children.Add(new TextBlock { Text = a.Summary, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 6) });
        if (!placed.Found)
            body.Children.Add(new TextBlock { Text = "Not found in document", Foreground = Brushes.Gray, FontStyle = FontStyles.Italic, Margin = new Thickness(0, 0, 0, 6) });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        buttons.Children.Add(accept);
        buttons.Children.Add(reject);
        body.Children.Add(buttons);

        var border = new Border
        {
            Child = body, Padding = new Thickness(10), Margin = new Thickness(0, 0, 0, 8), CornerRadius = new CornerRadius(6),
            BorderBrush = Brushes.LightGray, BorderThickness = new Thickness(1), Background = Brushes.White, Opacity = placed.Found ? 1 : 0.6,
        };
        border.MouseLeftButtonUp += (_, _) => Marked.FirstOrDefault(m => m.Placed.Annotation.Id == a.Id).Range?.Start.Paragraph?.BringIntoView();
        return new Card(border, accept, reject, !placed.Found);
    }

    void Act(Action action)
    {
        try { action(); }
        catch (Exception e) when (e is IOException or EngineException) { StatusText.Text = e.Message; return; }
        Refresh(keepScroll: true);
    }
}
