using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Threading;
using Folio.Core;
using Folio.Core.Preview;
using Microsoft.Win32;

namespace Folio.Wpf;

/// <summary>A window for one file, or for a set with its files in a sidebar: the rendered markdown with the annotations
/// marked, and a card for each beside it. The files on disk are the state; <see cref="Refresh"/> draws everything from
/// them again, and a timer calls it when the file, its sidecar or the set changes.</summary>
public partial class MainWindow : Window
{
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMilliseconds(300) };
    readonly CardActions actions;
    readonly Button adder;
    /// <summary>Where each file was scrolled to, as a fraction, by its id in the set (its path otherwise).</summary>
    readonly Dictionary<string, double> fractions = [];
    readonly Dictionary<string, CardView> cards = [];
    /// <summary>The diagrams drawn so far by their source (null: it did not draw, its source stays), for every file.</summary>
    readonly Dictionary<string, Diagram?> diagrams = [];
    /// <summary>The colours of each block of code by its language and code, as the page gave them, for every file.</summary>
    readonly Dictionary<(string Language, string Code), List<(int From, int To, string Scope)>> highlights = [];
    DiagramPage? diagramPage;

    FolioSet? set;
    string setStamp = "";
    ReviewFile? file;
    string key = "";
    string stamp = "";
    string? markdown;
    PreviewDocument? preview;
    List<Shown> shown = [];
    RenderedPreview? rendered;
    string? focused;
    /// <summary>The selection the Comment button is for: where it starts on screen, and its range in the file.</summary>
    (int Display, int From, int To)? selection;
    /// <summary>The form for a new comment, and the selection it is about.</summary>
    (CommentForm Form, int Display, int From, int To)? form;
    /// <summary>Set while the sidebar is changed from code, so that is not taken as a click.</summary>
    bool picking;
    /// <summary>Whether the sidebar is wanted; it is shown when it is and a set is open.</summary>
    bool sidebarWanted = true;

    // What the self-test looks at.
    internal FolioSet? Set => set;
    internal SetFile? ShownFile => set?.Files.FirstOrDefault(f => f.Id == key);
    internal ReviewFile? File => file;
    internal PreviewDocument? Preview => preview;
    internal RenderedPreview? Rendered => rendered;
    internal IReadOnlyList<Shown> Shown => shown;
    internal IReadOnlyDictionary<string, CardView> Cards => cards;
    internal CommentForm? Form => form?.Form;
    internal Button Adder => adder;
    internal string? Focused => focused;
    internal double ScrollOffset => Scroll.VerticalOffset;
    internal string VisibleText => new TextRange(Text.Document.ContentStart, Text.Document.ContentEnd).Text;
    internal string Status => StatusText.Text;
    internal IReadOnlyDictionary<string, Diagram?> Diagrams => diagrams;
    internal int Highlighted => highlights.Count(h => h.Value.Count > 0);

    public MainWindow()
    {
        InitializeComponent();
        actions = new CardActions(
            Accept: id => Act(() => file!.Accept(id)),
            Reject: id => Act(() => file!.Reject(id)),
            Reply: (id, body) => Act(() => file!.Reply(id, body)),
            Focus: id => FocusAnnotation(id, reveal: true));
        // The Comment button does not take the keyboard, so the selection stays selected.
        adder = new Button { Content = "Comment", Focusable = false, Padding = new Thickness(12, 4, 12, 4), Visibility = Visibility.Collapsed };
        adder.Click += (_, _) => OpenForm();
        Overlay.Children.Add(adder);

        poll.Tick += (_, _) => Poll();
        Text.PreviewMouseLeftButtonUp += (_, _) => Dispatcher.InvokeAsync(AfterClick, DispatcherPriority.Input);
        Text.SelectionChanged += (_, _) => { if (Text.Selection.IsEmpty) HideAdder(); };
        PreviewKeyDown += OnKey;
    }

    // ---- opening

    void OnOpen(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "Markdown (*.md;*.markdown)|*.md;*.markdown|All files|*.*" };
        if (dialog.ShowDialog(this) == true) Open(dialog.FileName);
    }

    void OnMcp(object sender, RoutedEventArgs e) => OpenConnect();

    /// <summary>The MCP… window, for this program's own path.</summary>
    internal ConnectWindow OpenConnect()
    {
        var connect = new ConnectWindow(Environment.ProcessPath!) { Owner = this };
        connect.Show();
        return connect;
    }

    void OnSetsOpened(object? sender, EventArgs e)
    {
        try { SetPicker.ItemsSource = Engine.SetNames(); }
        catch (EngineException error) { StatusText.Text = error.Message; }
    }

    void OnSetPicked(object sender, SelectionChangedEventArgs e)
    {
        if (!picking && SetPicker.SelectedItem is string name) OpenSet(name);
    }

    void OnSidebarPicked(object sender, SelectionChangedEventArgs e)
    {
        if (!picking && Sidebar.SelectedItem is ListBoxItem { Tag: SetFile picked } && picked.Id != key) ShowSetFile(picked);
    }

    /// <summary>One file, without a sidebar.</summary>
    public void Open(string path)
    {
        set = null;
        ShowSidebar();
        var review = new ReviewFile(path);
        Show(review, review.Path);
    }

    /// <summary>A set: its files in the sidebar, the first one shown.</summary>
    public void OpenSet(string name)
    {
        try
        {
            set = Engine.SetLoad(name);
            setStamp = Stamp(set.Manifest);
        }
        catch (EngineException error) { StatusText.Text = error.Message; return; }
        ShowSidebar();
        picking = true;
        SetPicker.ItemsSource = new[] { name };
        SetPicker.SelectedItem = name;
        picking = false;
        FillSidebar();
        if (set.Keep(null) is SetFile first) ShowSetFile(first);
        poll.Start();
    }

    void OnSidebarToggled(object sender, RoutedEventArgs e)
    {
        sidebarWanted = !sidebarWanted;
        ShowSidebar();
    }

    /// <summary>The sidebar for the window's state: shown when a set is open and it is wanted. The text reflows, so the
    /// cards are placed again, and the page stays at the same place in the text.</summary>
    void ShowSidebar()
    {
        var on = set is not null && sidebarWanted;
        SidebarToggle.IsEnabled = set is not null;
        SidebarToggle.IsChecked = sidebarWanted;
        Sidebar.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        if (SidebarColumn.Width.Value == (on ? 230 : 0)) return;
        var fraction = Scroll.ScrollableHeight > 0 ? Scroll.VerticalOffset / Scroll.ScrollableHeight : 0;
        SidebarColumn.Width = new GridLength(on ? 230 : 0);
        if (rendered is null) return;
        Scroll.UpdateLayout();
        LayoutCards();
        Scroll.UpdateLayout();
        ScrollTo(fraction * Scroll.ScrollableHeight);
    }

    internal bool SidebarShown => Sidebar.IsVisible && SidebarColumn.ActualWidth > 0;

    internal void ShowSetFile(SetFile picked) => Show(new ReviewFile(picked.Path), picked.Id);

    void Show(ReviewFile review, string id)
    {
        Remember();
        file = review;
        key = id;
        markdown = null;
        preview = null;
        focused = null;
        form = null;
        PathText.Text = review.Path;
        SelectInSidebar();
        Refresh(fraction: fractions.GetValueOrDefault(id));
        poll.Start();
    }

    /// <summary>The sidebar drawn from the set; the shown file stays selected (by id, never by its place in the list).</summary>
    void FillSidebar()
    {
        picking = true;
        Sidebar.Items.Clear();
        var groups = set!.Files.Select(f => f.Group).Distinct().Count();
        foreach (var f in set.Files)
            Sidebar.Items.Add(new ListBoxItem { Content = groups > 1 ? $"{f.Group}/{f.Name}" : f.Name, Tag = f, ToolTip = f.Path, Padding = new Thickness(8, 4, 8, 4) });
        picking = false;
        SelectInSidebar();
    }

    void SelectInSidebar()
    {
        picking = true;
        Sidebar.SelectedItem = Sidebar.Items.OfType<ListBoxItem>().FirstOrDefault(i => ((SetFile)i.Tag).Id == key);
        picking = false;
    }

    void Remember()
    {
        if (file is not null) fractions[key] = Scroll.ScrollableHeight > 0 ? Scroll.VerticalOffset / Scroll.ScrollableHeight : 0;
    }

    // ---- following the disk

    void Poll()
    {
        if (set is not null && Stamp(set.Manifest) != setStamp)
        {
            try
            {
                set = Engine.SetLoad(set.Name);
                setStamp = Stamp(set.Manifest);
                FillSidebar();
                var kept = set.Keep(key);
                if (kept is not null && kept.Id != key) ShowSetFile(kept);
            }
            catch (EngineException error) { StatusText.Text = error.Message; }
        }
        if (file is not null && file.Stamp() != stamp) Refresh();
    }

    /// <summary>Reads the file and its sidecar and draws everything again, keeping the scroll position (or going to
    /// <paramref name="fraction"/> of the way down).</summary>
    void Refresh(double? fraction = null)
    {
        if (file is null) return;
        var offset = Scroll.VerticalOffset;
        try
        {
            stamp = file.Stamp();   // before reading, so a write in between shows up as another change
            var text = file.ReadText();
            if (text != markdown || preview is null)
            {
                markdown = text;
                preview = PreviewBuilder.Build(text, Path.GetDirectoryName(file.Path));
            }
            shown = PreviewMarks.Show(preview, Review.Place(text, Sidecar.Parse(file.ReadSidecar())));
            if (focused is not null && !shown.Any(s => s.Annotation.Id == focused)) focused = null;
            Draw();
            var lost = shown.Count(s => !s.Placed.Found);
            StatusText.Text = $"{shown.Count} pending" + (lost > 0 ? $", {lost} not found" : "");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or EngineException or System.Text.Json.JsonException)
        {
            StatusText.Text = e.Message;   // a half-written file: the next change draws it again
        }
        Scroll.UpdateLayout();
        ScrollTo(fraction is double f ? f * Scroll.ScrollableHeight : offset);
    }

    /// <summary>Scrolls now: the scroll viewer takes the offset at its next layout, so that is done here, before the
    /// next frame is drawn and before anyone reads the offset.</summary>
    internal void ScrollTo(double offset)
    {
        Scroll.UpdateLayout();
        Scroll.ScrollToVerticalOffset(offset);
        Scroll.UpdateLayout();
    }

    void Draw()
    {
        rendered = new RenderedPreview(preview!, shown, focused, diagrams, highlights);
        Text.Document = rendered.Document;
        HideAdder();
        Text.UpdateLayout();
        LayoutCards();
        AskPage();
    }

    /// <summary>Asks the hidden page for what the shown file needs and it has not been asked for yet, one thing at a time:
    /// the colours of each block of code with a language, then each diagram. Until the answer is there, the code is
    /// plain and the diagram is its source; the file is drawn again when it comes.</summary>
    async void AskPage()
    {
        var code = preview!.Blocks.Where(b => b.Kind == BlockKind.Code && b.Language is not null && !string.IsNullOrEmpty(b.Code))
            .Select(b => (b.Language!, b.Code!)).Where(k => !highlights.ContainsKey(k)).Distinct().ToList();
        var waiting = preview.Blocks.Select(b => b.Diagram).OfType<string>().Where(d => !diagrams.ContainsKey(d)).Distinct().ToList();
        if (code.Count + waiting.Count == 0 || (diagramPage ??= DiagramPage.Find() is string folder ? new DiagramPage(this, folder) : null) is not DiagramPage page) return;
        // Asked for once, also while the answer is on its way.
        foreach (var key in code) highlights[key] = [];
        foreach (var d in waiting) diagrams[d] = null;
        foreach (var (language, text) in code)
        {
            var scopes = await page.Highlight(text, language);
            highlights[(language, text)] = scopes;
            if (scopes.Count > 0 && preview?.Blocks.Any(b => b.Language == language && b.Code == text) == true) Redraw();
        }
        foreach (var d in waiting)
        {
            var drawn = await page.Draw(d);
            diagrams[d] = drawn;
            if (drawn is not null && preview?.Blocks.Any(b => b.Diagram == d) == true) Redraw();
        }
    }

    /// <summary>Draws again with the same files, as after focusing a card, keeping the scroll position.</summary>
    void Redraw()
    {
        var offset = Scroll.VerticalOffset;
        Draw();
        ScrollTo(offset);
    }

    // ---- cards

    void LayoutCards()
    {
        Pane.Children.Clear();
        cards.Clear();
        var items = new List<(FrameworkElement View, CardLayout.Card Card)>();
        foreach (var s in shown)
        {
            var view = new CardView(s, s.Annotation.Id == focused, actions);
            cards[s.Annotation.Id] = view;
            Pane.Children.Add(view);
            items.Add((view, new CardLayout.Card(AnchorOf(s.At), view.Measured())));
        }
        if (form is var (pending, display, _, _))
        {
            Pane.Children.Add(pending);
            items.Add((pending, new CardLayout.Card(AnchorOf(display), pending.Measured())));
        }
        var textHeight = Text.ActualHeight;
        var (placed, extent) = CardLayout.Stack(items.Select(i => i.Card).ToList(), end: textHeight);
        foreach (var (index, top) in placed)
        {
            Canvas.SetLeft(items[index].View, 12);
            Canvas.SetTop(items[index].View, top);
        }
        Pane.Height = Math.Max(textHeight, extent + 24);
    }

    CardLayout.Anchor? AnchorOf(int? at) =>
        at is int offset && rendered?.Pointer(offset, forward: true) is TextPointer pointer ? new CardLayout.Anchor(TopOf(pointer), offset) : null;

    /// <summary>Where a position's line starts, in the page's coordinates (which the pane shares).</summary>
    internal double TopOf(TextPointer pointer)
    {
        var rect = pointer.GetCharacterRect(LogicalDirection.Forward);
        return rect.IsEmpty ? 0 : Text.TranslatePoint(rect.TopLeft, Page).Y;
    }

    internal double AnchorTop(string id) => shown.FirstOrDefault(s => s.Annotation.Id == id)?.At is int at && rendered?.Pointer(at, true) is TextPointer p ? TopOf(p) : double.NaN;

    internal double CardTop(string id) => cards.TryGetValue(id, out var card) ? Canvas.GetTop(card) : double.NaN;

    // ---- focus, selection, new comments

    void AfterClick()
    {
        if (rendered is null) return;
        if (!Text.Selection.IsEmpty)
        {
            ShowAdder();
            return;
        }
        var at = rendered.Offset(Text.Selection.Start);
        var hit = shown.Where(s => s.Marked && s.From <= at && at < s.To).OrderByDescending(s => s.From).FirstOrDefault();
        if (hit is not null) FocusAnnotation(hit.Annotation.Id, reveal: false);
        else if (focused is not null) FocusAnnotation(null, reveal: false);
    }

    /// <summary>Focuses an annotation (null: none): its card gets the accent border and its reply field.</summary>
    internal void FocusAnnotation(string? id, bool reveal)
    {
        if (focused == id && !reveal) return;
        focused = id;
        Redraw();
        if (id is null || !cards.TryGetValue(id, out var card)) return;
        if (reveal) Reveal(id);
        card.ReplyBox?.Focus();
    }

    /// <summary>Scrolls the annotation's text into view when it is not.</summary>
    void Reveal(string id)
    {
        var top = AnchorTop(id);
        if (double.IsNaN(top)) return;
        if (top < Scroll.VerticalOffset + 40 || top > Scroll.VerticalOffset + Scroll.ViewportHeight - 80)
            ScrollTo(Math.Max(0, top - 80));
    }

    /// <summary>Selects shown offsets <paramref name="from"/>..<paramref name="to"/> as a person would, and shows the Comment button.</summary>
    internal void Select(int from, int to)
    {
        if (rendered?.Pointer(from, forward: true) is not TextPointer start || rendered.Pointer(to, forward: false) is not TextPointer end) return;
        Text.Selection.Select(start, end);
        ShowAdder();
    }

    void ShowAdder()
    {
        if (rendered is null || preview is null) return;
        var (a, b) = (rendered.Offset(Text.Selection.Start), rendered.Offset(Text.Selection.End));
        if (b <= a || preview.Map.SourceRange(a, b) is not var (from, to))
        {
            HideAdder();
            return;
        }
        selection = (a, from, to);
        var first = Text.Selection.Start.GetCharacterRect(LogicalDirection.Forward);
        var last = Text.Selection.End.GetCharacterRect(LogicalDirection.Backward);
        var topLeft = Text.TranslatePoint(first.TopLeft, Overlay);
        var right = Math.Abs(last.Top - first.Top) < 2 ? Text.TranslatePoint(last.TopRight, Overlay).X : topLeft.X + 80;
        adder.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var (x, y) = CardLayout.AdderOrigin(adder.DesiredSize.Width, adder.DesiredSize.Height, topLeft.X, right, topLeft.Y, topLeft.Y + first.Height,
                                            visibleTop: Scroll.VerticalOffset, textWidth: Text.ActualWidth);
        Canvas.SetLeft(adder, x);
        Canvas.SetTop(adder, y);
        adder.Visibility = Visibility.Visible;
    }

    void HideAdder()
    {
        adder.Visibility = Visibility.Collapsed;
        selection = null;
    }

    void OpenForm()
    {
        if (selection is not var (display, from, to)) return;
        var pending = new CommentForm(add: AddComment, cancel: CloseForm);
        form = (pending, display, from, to);
        HideAdder();
        LayoutCards();
        pending.Box.Focus();
    }

    void AddComment(string comment)
    {
        if (form is not var (_, _, from, to) || file is null) return;
        string? id = null;
        Act(() => id = file.AddComment(from, to, comment), after: () =>
        {
            form = null;
            if (id is null) StatusText.Text = "There is no text in the selection to comment on";
            focused = id;
        });
    }

    void CloseForm()
    {
        form = null;
        LayoutCards();
    }

    void OnKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Escape) return;
        if (form is not null) CloseForm();
        else if (focused is not null) FocusAnnotation(null, reveal: false);
        else return;
        e.Handled = true;
    }

    // ---- actions

    /// <summary>Does an action on the files and draws them again; a file in use is a message, not a crash.</summary>
    void Act(Action action, Action? after = null)
    {
        try { action(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or EngineException)
        {
            StatusText.Text = e.Message;
            return;
        }
        after?.Invoke();
        Refresh();
    }

    static string Stamp(string path) =>
        System.IO.File.Exists(path) ? $"{System.IO.File.GetLastWriteTimeUtc(path).Ticks}:{new FileInfo(path).Length}" : "-";
}
