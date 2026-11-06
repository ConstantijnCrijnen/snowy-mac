using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Snowy.Windows.Decorations;
using Snowy.Windows.Desktop;
using Snowy.Windows.Wallpapers;

namespace Snowy.Windows.Shell;

internal static class SnowyWindow
{
    public static Window Create(DesktopHost desktop, DecorationService decorations, string dataDirectory,
        Action replayWalkthrough)
    {
        var window = Interface.Window("Snowy", 870, 620);
        window.MinWidth = 690;
        window.MinHeight = 470;
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(172) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        var sidebar = new DockPanel { Background = SystemColors.ControlBrush, LastChildFill = true };
        var brand = Interface.Text("❄  Snowy", 20, true);
        brand.Margin = new Thickness(17, 19, 12, 17);
        DockPanel.SetDock(brand, Dock.Top);
        sidebar.Children.Add(brand);
        var menu = new ListBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(8, 0, 8, 0)
        };
        foreach (var (symbol, title) in new[] { ("▧", "Wallpapers"), ("♧", "Decorations"), ("☰", "Guide") })
            menu.Items.Add(new ListBoxItem { Content = $"{symbol}   {title}", Padding = new Thickness(9, 8, 6, 8) });
        sidebar.Children.Add(menu);
        grid.Children.Add(sidebar);
        var detail = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
        Grid.SetColumn(detail, 1);
        grid.Children.Add(detail);
        var pages = new FrameworkElement?[] { null, null, null };
        menu.SelectionChanged += (_, _) =>
        {
            var index = menu.SelectedIndex;
            if (index < 0) return;
            detail.Content = pages[index] ??= index switch
            {
                0 => new WallpaperPanel(new WallpaperLibrary(dataDirectory), desktop),
                1 => new ScenePanel(decorations, desktop),
                _ => Guide(replayWalkthrough)
            };
        };
        menu.SelectedIndex = 1;
        window.Content = grid;
        return window;
    }

    private static ScrollViewer Guide(Action replay)
    {
        var content = new StackPanel { Margin = new Thickness(26) };
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 18) };
        var walkthrough = Interface.Button("Replay Walkthrough", (_, _) => replay());
        DockPanel.SetDock(walkthrough, Dock.Right);
        header.Children.Add(walkthrough);
        header.Children.Add(Interface.Text("Guide", 28, true));
        content.Children.Add(header);
        content.Children.Add(Group("Snow controls", WelcomeWindow.Pages.Select(page =>
            (page.Title, page.Detail)).ToArray()));
        content.Children.Add(Group("Make it yours",
            ("Set a wallpaper", "Choose a winter scene or import a picture and apply it to one display or all of them."),
            ("Decorate the desktop", "Choose a preset or open the editor to arrange props and hang lights. Enable Push with Cursor to slide individual decorations.")));
        content.Children.Add(Interface.Detail($"Snowy for Windows {typeof(SnowyWindow).Assembly.GetName().Version?.ToString(3)}"));
        return new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private static GroupBox Group(string title, params (string Title, string Detail)[] rows)
    {
        var body = new StackPanel { Margin = new Thickness(12, 9, 12, 0) };
        foreach (var (heading, detail) in rows)
        {
            body.Children.Add(Interface.Text(heading, 14, true));
            body.Children.Add(Interface.Detail(detail));
        }
        return new GroupBox { Header = title, Content = body, Margin = new Thickness(0, 0, 0, 15) };
    }
}
