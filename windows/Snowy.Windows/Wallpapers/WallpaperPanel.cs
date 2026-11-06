using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using Snowy.Windows.Desktop;
using Snowy.Windows.Shell;

namespace Snowy.Windows.Wallpapers;

internal sealed class WallpaperPanel : ScrollViewer
{
    private readonly WallpaperLibrary library;
    private readonly DesktopHost desktop;
    private readonly ComboBox displays = new() { MinWidth = 175, Margin = new Thickness(0, 0, 8, 0) };
    private readonly ListBox cards = new()
    {
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        HorizontalContentAlignment = HorizontalAlignment.Stretch
    };
    private readonly TextBlock status = Interface.Detail("");
    private readonly Button apply;
    private readonly Button import;
    private Wallpaper? selected;
    private bool working;

    public WallpaperPanel(WallpaperLibrary library, DesktopHost desktop)
    {
        this.library = library;
        this.desktop = desktop;
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        var page = new StackPanel { Margin = new Thickness(26) };
        page.Children.Add(Interface.Text("Wallpapers", 28, true));
        page.Children.Add(Interface.Detail("Choose a winter scene or add your own. Imported pictures stay on this PC."));
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
        AutomationProperties.SetName(displays, "Apply wallpaper to display");
        displays.DropDownOpened += (_, _) => RefreshDisplays();
        bar.Children.Add(displays);
        apply = Interface.Button("Set Wallpaper", (_, _) => ApplySelected(), primary: true);
        bar.Children.Add(apply);
        import = Interface.Button("Import Images…", async (_, _) => await Import());
        bar.Children.Add(import);
        page.Children.Add(bar);
        page.Children.Add(status);
        var grid = new FrameworkElementFactory(typeof(WrapPanel));
        cards.ItemsPanel = new ItemsPanelTemplate(grid);
        AutomationProperties.SetName(cards, "Wallpapers");
        ScrollViewer.SetHorizontalScrollBarVisibility(cards, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(cards, ScrollBarVisibility.Disabled);
        cards.SelectionChanged += (_, _) =>
        {
            selected = (cards.SelectedItem as ListBoxItem)?.Tag as Wallpaper;
            RefreshButtons();
        };
        page.Children.Add(cards);
        Content = page;
        RefreshDisplays();
        Loaded += async (_, _) =>
        {
            if (cards.Items.Count > 0 || working) return;
            working = true;
            RefreshButtons();
            try { await Reload(); }
            finally
            {
                working = false;
                RefreshButtons();
            }
        };
        RefreshButtons();
    }

    private sealed record DisplayChoice(string Name, DesktopScreen? Screen)
    {
        public override string ToString() => Name;
    }

    private void RefreshDisplays()
    {
        var id = (displays.SelectedItem as DisplayChoice)?.Screen?.Id;
        var choices = new List<DisplayChoice> { new("All displays", null) };
        choices.AddRange(desktop.Screens.Select(screen => new DisplayChoice(screen.Name, screen)));
        displays.ItemsSource = choices;
        displays.SelectedItem = choices.FirstOrDefault(choice => choice.Screen?.Id == id) ?? choices[0];
    }

    private async Task Reload()
    {
        var previous = selected;
        cards.Items.Clear();
        try
        {
            var previews = await Task.Run(() => library.List().Select(wallpaper =>
            {
                ImageSource? image = null;
                try { image = library.Preview(wallpaper); }
                catch (Exception error) when (WallpaperLibrary.IsImageError(error)) { }
                return (Wallpaper: wallpaper, Image: image);
            }).ToArray());
            foreach (var (wallpaper, image) in previews)
            {
                if (image is null) continue;
                var card = new StackPanel { Width = 177 };
                card.Children.Add(new Image { Source = image, Height = 100, Stretch = Stretch.UniformToFill });
                var caption = Interface.Text(wallpaper.Title, 13, true);
                caption.Margin = new Thickness(0, 6, 0, 1);
                card.Children.Add(caption);
                var item = new ListBoxItem { Content = card, Tag = wallpaper, Margin = new Thickness(0, 0, 8, 8) };
                AutomationProperties.SetName(item, wallpaper.Title);
                cards.Items.Add(item);
                if (wallpaper == previous) cards.SelectedItem = item;
            }
            if (cards.SelectedIndex < 0 && cards.Items.Count > 0) cards.SelectedIndex = 0;
        }
        catch (Exception error) when (WallpaperLibrary.IsImageError(error))
        {
            status.Text = "The wallpaper library couldn’t be opened.";
        }
        RefreshButtons();
    }

    private async Task Import()
    {
        var dialog = new OpenFileDialog
        {
            Multiselect = true,
            Filter = "Images|*.jpg;*.jpeg;*.png;*.heic;*.heif;*.tiff;*.tif;*.webp;*.bmp"
        };
        if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
        working = true;
        RefreshButtons();
        status.Text = "Importing images…";
        try
        {
            var paths = dialog.FileNames;
            var (added, skipped) = await Task.Run(() => library.Import(paths));
            status.Text = skipped == 0 ? $"Imported {added}." : $"Imported {added}. Skipped {skipped} unsupported images or files over the library limits.";
            await Reload();
        }
        catch (Exception error) when (WallpaperLibrary.IsImageError(error))
        {
            status.Text = "The images couldn’t be imported.";
        }
        finally
        {
            working = false;
            RefreshButtons();
        }
    }

    private void ApplySelected()
    {
        if (selected is null) return;
        try
        {
            var screen = (displays.SelectedItem as DisplayChoice)?.Screen;
            library.Apply(selected, screen);
            status.Text = $"Applied {selected.Title}.";
        }
        catch (Exception error) when (WallpaperLibrary.IsImageError(error))
        {
            status.Text = "Windows couldn’t set this wallpaper.";
        }
    }

    private void RefreshButtons()
    {
        apply.IsEnabled = !working && selected is not null;
        import.IsEnabled = !working;
    }
}
