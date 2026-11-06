using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Snowy.Windows.Shell;

internal static class Interface
{
    public static TextBlock Text(string text, double size = 14, bool heading = false) => new()
    {
        Text = text,
        FontSize = size,
        TextWrapping = TextWrapping.Wrap,
        FontWeight = heading ? FontWeights.SemiBold : FontWeights.Normal,
        Margin = new Thickness(0, 0, 0, heading ? 9 : 6)
    };

    public static TextBlock Detail(string text) => new()
    {
        Text = text,
        FontSize = 14,
        TextWrapping = TextWrapping.Wrap,
        Foreground = SystemColors.GrayTextBrush,
        Margin = new Thickness(0, 0, 0, 12)
    };

    public static Button Button(string text, RoutedEventHandler? action = null, bool primary = false)
    {
        var button = new Button
        {
            Content = text,
            Padding = new Thickness(13, 6, 13, 6),
            MinHeight = 31,
            Margin = new Thickness(0, 0, 8, 0)
        };
        if (primary && !SystemParameters.HighContrast)
        {
            button.Background = new SolidColorBrush(Color.FromRgb(29, 105, 179));
            button.Foreground = Brushes.White;
            button.BorderBrush = new SolidColorBrush(Color.FromRgb(24, 84, 144));
        }
        if (action is not null) button.Click += action;
        return button;
    }

    public static Window Window(string title, double width, double height) => new()
    {
        Title = title,
        Width = width,
        Height = height,
        FontSize = 14,
        Icon = System.Windows.Media.Imaging.BitmapFrame.Create(new Uri("pack://application:,,,/Assets/Snowy.ico")),
        WindowStartupLocation = WindowStartupLocation.CenterScreen
    };
}
