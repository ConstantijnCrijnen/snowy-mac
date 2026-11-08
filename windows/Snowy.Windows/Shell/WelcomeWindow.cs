using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace Snowy.Windows.Shell;

internal static class WelcomeWindow
{
    public static readonly (string Title, string Detail)[] Pages =
    [
        ("Snow on your desktop",
            "Snow settles on open windows and the bottom taskbar. Move a window to carry or push the snow around."),
        ("Sweep snow and set the wind",
            "Sweep a pile with your pointer. Choose Shovel for a wider sweep. In Wind, drag the arrow to set its direction and strength."),
        ("Snowy in the system tray",
            "Click the snowflake near the clock to open the controls. If it’s hidden, look under the up arrow. Choose Open Snowy for wallpapers and decorations.")
    ];

    public static Window Create()
    {
        var window = Interface.Window("Welcome to Snowy", 690, 334);
        window.ResizeMode = ResizeMode.NoResize;
        var dock = new DockPanel();
        var footer = new DockPanel { Margin = new Thickness(23, 12, 19, 14) };
        DockPanel.SetDock(footer, Dock.Bottom);
        dock.Children.Add(footer);
        var separator = new Separator { Margin = new Thickness(0) };
        DockPanel.SetDock(separator, Dock.Bottom);
        dock.Children.Add(separator);

        var grid = new Grid { Margin = new Thickness(24) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(278) });
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        dock.Children.Add(grid);
        var preview = new Preview { Height = 180 };
        grid.Children.Add(preview);
        var copy = new StackPanel { Margin = new Thickness(23, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(copy, 1);
        grid.Children.Add(copy);

        var title = Interface.Text("", 24, true);
        AutomationProperties.SetHeadingLevel(title, AutomationHeadingLevel.Level1);
        copy.Children.Add(title);
        var detail = Interface.Detail("");
        copy.Children.Add(detail);
        var skip = Interface.Button("Skip", (_, _) => window.Close());
        DockPanel.SetDock(skip, Dock.Left);
        footer.Children.Add(skip);
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        DockPanel.SetDock(actions, Dock.Right);
        footer.Children.Add(actions);
        var progress = Interface.Detail("");
        progress.HorizontalAlignment = HorizontalAlignment.Center;
        progress.VerticalAlignment = VerticalAlignment.Center;
        progress.Margin = new Thickness(0);
        footer.Children.Add(progress);
        int step = 0;
        var back = Interface.Button("Back");
        var next = Interface.Button("Continue", primary: true);
        back.Click += (_, _) => Show(--step);
        next.Click += (_, _) =>
        {
            if (step == Pages.Length - 1) window.Close();
            else Show(++step);
        };
        next.IsDefault = true;
        actions.Children.Add(back);
        actions.Children.Add(next);
        window.KeyDown += (_, eventArgs) => { if (eventArgs.Key == Key.Escape) window.Close(); };
        window.Content = dock;
        Show(0);
        return window;

        void Show(int index)
        {
            (title.Text, detail.Text) = Pages[index];
            preview.Step = index;
            preview.InvalidateVisual();
            progress.Text = $"{index + 1} of {Pages.Length}";
            back.Visibility = index == 0 ? Visibility.Hidden : Visibility.Visible;
            next.Content = index == Pages.Length - 1 ? "Let it snow" : "Continue";
        }
    }

    private sealed class Preview : FrameworkElement
    {
        private static readonly Brush Frame = new SolidColorBrush(Color.FromRgb(20, 35, 59));
        private static readonly Brush Sky = new LinearGradientBrush(Color.FromRgb(41, 67, 106),
            Color.FromRgb(113, 149, 174), 85);
        private static readonly Brush Chrome = new SolidColorBrush(Color.FromRgb(228, 237, 249));
        private static readonly Brush Ink = new SolidColorBrush(Color.FromRgb(56, 94, 140));
        public int Step { get; set; }

        protected override void OnRender(DrawingContext dc)
        {
            var width = ActualWidth;
            dc.DrawRoundedRectangle(Frame, null, new Rect(0, 0, width, 180), 11, 11);
            dc.DrawRoundedRectangle(Sky, null, new Rect(1, 1, width - 2, 178), 10, 10);
            if (Step == 1)
            {
                var center = new Point(width / 2, 90);
                dc.DrawEllipse(Frame, new Pen(Chrome, 1), center, 60, 60);
                for (int y = -2; y <= 2; y++)
                for (int x = -2; x <= 2; x++)
                    if (x * x + y * y < 8)
                        dc.DrawEllipse(Ink, null, new Point(center.X + x * 20, center.Y + y * 20), 1.6, 1.6);
                WindPad.DrawArrow(dc, center, new Vector(35, -28), new Pen(Brushes.White, 4));
                return;
            }

            for (int i = 0; i < 30; i++)
            {
                var position = new Point(10 + (i * 71 % 251), 8 + (i * i * 33 + i * 23) % 143);
                dc.DrawEllipse(Chrome, null, position, i % 7 == 0 ? 2 : 1, i % 7 == 0 ? 2 : 1);
            }
            DrawWindow(dc, new Rect(27, 59, 149, 83));
            DrawWindow(dc, new Rect(108, 85, 139, 75));
            dc.DrawRoundedRectangle(Frame, null, new Rect(13, 157, width - 26, 18), 4, 4);
            for (int i = 0; i < 4; i++)
                dc.DrawRoundedRectangle(i == 3 ? Brushes.White : Ink, null,
                    new Rect(width - 65 + i * 11, 163, 6, 6), 1, 1);
            if (Step == 2)
            {
                dc.DrawRoundedRectangle(Chrome, null, new Rect(171, 65, 82, 85), 6, 6);
                for (int i = 0; i < 4; i++)
                    dc.DrawRoundedRectangle(Ink, null, new Rect(182, 77 + 16 * i, 40 + 5 * (i % 3), 2), 1, 1);
            }
        }

        private static void DrawWindow(DrawingContext dc, Rect rect)
        {
            dc.DrawRoundedRectangle(Chrome, null, rect, 7, 7);
            dc.DrawRoundedRectangle(Frame, null,
                new Rect(rect.X + 4, rect.Y + 18, rect.Width - 8, rect.Height - 22), 3, 3);
            dc.DrawLine(new Pen(Ink, 2), new Point(rect.Right - 25, rect.Top + 9), new Point(rect.Right - 14, rect.Top + 9));
            dc.DrawRoundedRectangle(Brushes.White, null,
                new Rect(rect.X + 5, rect.Y - 5, rect.Width - 10, 7), 3, 3);
        }
    }
}
