using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Folio.Core.Preview;

namespace Folio.Wpf;

/// <summary>What a card asks the window to do; the window does it on the files and draws again.</summary>
sealed record CardActions(Action<string> Accept, Action<string> Reject, Action<string, string> Reply, Action<string> Focus);

/// <summary>An annotation's card in the comments pane: who, what, its thread, and its buttons. The focused card has
/// the accent border and a field to reply in.</summary>
sealed class CardView : Border
{
    public const double CardWidth = 280;

    public Shown Shown { get; }
    public Button Accept { get; }
    public Button Reject { get; }
    public TextBox? ReplyBox { get; }
    public Button? ReplyButton { get; }
    public bool NotFound => !Shown.Placed.Found;

    public CardView(Shown shown, bool focused, CardActions actions)
    {
        Shown = shown;
        var a = shown.Annotation;
        Width = CardWidth;
        Padding = new Thickness(12, 10, 12, 10);
        CornerRadius = new CornerRadius(8);
        Background = Brushes.White;
        BorderBrush = focused ? SystemColors.HighlightBrush : new SolidColorBrush(Color.FromArgb(0x30, 0, 0, 0));
        BorderThickness = new Thickness(focused ? 2 : 1);
        Opacity = NotFound ? 0.6 : 1;
        Cursor = Cursors.Hand;

        var body = new StackPanel();
        body.Children.Add(new TextBlock
        {
            Text = $"{a.Author} · {a.Kind}", FontWeight = FontWeights.SemiBold, FontSize = 12, Foreground = Look.Secondary,
        });
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0), FontSize = 13.5 };
        if (a.Kind == "comment") text.Text = a.Comment ?? "";
        else
        {
            text.Text = a.Summary;
            if (!string.IsNullOrEmpty(a.Comment))
                body.Children.Add(new TextBlock { Text = a.Comment, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0), FontSize = 13.5 });
        }
        body.Children.Insert(1, text);
        if (NotFound)
            body.Children.Add(new TextBlock { Text = "Not found in document", Foreground = Look.Secondary, FontStyle = FontStyles.Italic, Margin = new Thickness(0, 6, 0, 0), FontSize = 12 });

        foreach (var reply in a.Replies ?? [])
        {
            var line = new TextBlock { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0), FontSize = 13 };
            line.Inlines.Add(new System.Windows.Documents.Run(reply.Author + "  ") { FontWeight = FontWeights.SemiBold });
            line.Inlines.Add(new System.Windows.Documents.Run(reply.Body));
            body.Children.Add(line);
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 10, 0, 0) };
        Accept = new Button { Content = a.IsComment ? "Dismiss" : "Accept", Padding = new Thickness(12, 3, 12, 3), Margin = new Thickness(0, 0, 6, 0) };
        Reject = new Button { Content = "Reject", Padding = new Thickness(12, 3, 12, 3), Visibility = a.IsComment ? Visibility.Collapsed : Visibility.Visible };
        // A comment is dismissed, which resolves it like a rejection and changes no text.
        Accept.Click += (_, e) => { e.Handled = true; if (a.IsComment) actions.Reject(a.Id); else actions.Accept(a.Id); };
        Reject.Click += (_, e) => { e.Handled = true; actions.Reject(a.Id); };
        buttons.Children.Add(Accept);
        buttons.Children.Add(Reject);
        body.Children.Add(buttons);

        if (focused)
        {
            var reply = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
            ReplyButton = new Button { Content = "Reply", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(6, 0, 0, 0), IsEnabled = false };
            ReplyBox = new TextBox { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, MinHeight = 24, VerticalContentAlignment = VerticalAlignment.Center };
            var box = ReplyBox;
            box.TextChanged += (_, _) => ReplyButton.IsEnabled = box.Text.Trim().Length > 0;
            void Send() { if (box.Text.Trim().Length > 0) actions.Reply(a.Id, box.Text.Trim()); }
            ReplyButton.Click += (_, e) => { e.Handled = true; Send(); };
            box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { e.Handled = true; Send(); } };
            DockPanel.SetDock(ReplyButton, Dock.Right);
            reply.Children.Add(ReplyButton);
            reply.Children.Add(ReplyBox);
            body.Children.Add(reply);
        }

        Child = body;
        MouseLeftButtonUp += (_, e) => { if (e.OriginalSource is not TextBox) actions.Focus(a.Id); };
    }

    /// <summary>Its height at the pane's width, measured, not guessed.</summary>
    public double Measured()
    {
        Measure(new Size(CardWidth, double.PositiveInfinity));
        return DesiredSize.Height;
    }
}

/// <summary>The form for a new comment on the selected text, in the pane where its card will be.</summary>
sealed class CommentForm : Border
{
    public TextBox Box { get; }
    public Button Add { get; }
    public Button Cancel { get; }

    public CommentForm(Action<string> add, Action cancel)
    {
        Width = CardView.CardWidth;
        Padding = new Thickness(12, 10, 12, 10);
        CornerRadius = new CornerRadius(8);
        Background = Brushes.White;
        BorderBrush = SystemColors.HighlightBrush;
        BorderThickness = new Thickness(2);

        var body = new StackPanel();
        body.Children.Add(new TextBlock { Text = "New comment", FontWeight = FontWeights.SemiBold, FontSize = 12, Foreground = Look.Secondary });
        Box = new TextBox { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 56, Margin = new Thickness(0, 6, 0, 0) };
        body.Children.Add(Box);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Right };
        Cancel = new Button { Content = "Cancel", Padding = new Thickness(12, 3, 12, 3), Margin = new Thickness(0, 0, 6, 0), IsCancel = true };
        Add = new Button { Content = "Comment", Padding = new Thickness(12, 3, 12, 3), IsEnabled = false };
        Box.TextChanged += (_, _) => Add.IsEnabled = Box.Text.Trim().Length > 0;
        Add.Click += (_, _) => add(Box.Text.Trim());
        Cancel.Click += (_, _) => cancel();
        buttons.Children.Add(Cancel);
        buttons.Children.Add(Add);
        body.Children.Add(buttons);
        Child = body;
    }

    public double Measured()
    {
        Measure(new Size(CardView.CardWidth, double.PositiveInfinity));
        return DesiredSize.Height;
    }
}
