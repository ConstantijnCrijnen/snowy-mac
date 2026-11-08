using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Snowy.Core;
using Snowy.Windows.Decorations;
using Snowy.Windows.Desktop;
using Snowy.Windows.Shell;
using Tray = System.Windows.Forms;

namespace Snowy.Windows;

public partial class App : Application
{
    private readonly string dataDirectory = DataDirectory();
    private readonly PackageUpdater updater = new();
    private Mutex? instance;
    private EventWaitHandle? openSignal;
    private RegisteredWaitHandle? signalWait;
    private DispatcherTimer? updateTimer;
    private WeatherSettings settings = new();
    private DesktopHost? desktop;
    private DecorationService? decorations;
    private Tray.NotifyIcon? icon;
    private System.Drawing.Icon? trayArt;
    private Window? main;
    private Window? wind;
    private Window? welcome;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = new Mutex(false, @"Local\Snowy.Windows", out var first);
        openSignal = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Snowy.Windows.Open");
        if (!first)
        {
            openSignal.Set();
            Shutdown();
            return;
        }

        settings = WeatherSettings.Load(dataDirectory);
        desktop = new DesktopHost(() => settings.Desktop);
        decorations = new DecorationService(dataDirectory);
        decorations.Attach(desktop);
        desktop.Frame += decorations.Render;
        CreateTray();
        signalWait = ThreadPool.RegisterWaitForSingleObject(openSignal, (_, _) =>
        {
            _ = Dispatcher.BeginInvoke(OpenSnowy);
        }, null, Timeout.Infinite, false);

        if (!settings.SawWalkthrough)
        {
            settings.SawWalkthrough = true;
            Save();
            OpenWelcome();
        }

        updateTimer = new DispatcherTimer { Interval = TimeSpan.FromHours(6) };
        updateTimer.Tick += async (_, _) => await updater.Check();
        updateTimer.Start();
        _ = updater.Check();
    }

    private void CreateTray()
    {
        using var stream = GetResourceStream(new Uri("pack://application:,,,/Assets/Snowy.ico")).Stream;
        trayArt = new System.Drawing.Icon(stream, 32, 32);
        var menu = new ContextMenu { Placement = PlacementMode.MousePoint };
        var support = Item("Drop some coins", () => OpenUrl("https://snowy.aauburn.com/#drop-some-coins"));
        var open = Item("Open Snowy…", OpenSnowy);
        var pause = Item("Pause Snow", () => { settings.Enabled = !settings.Enabled; Save(); });
        var clear = Item("Clear Settled Snow", () => desktop?.Clear());
        var tools = new MenuItem { Header = "Cursor Tool" };
        var toolOptions = Enum.GetValues<SnowTool>().Select(tool =>
            Item(tool.ToString(), () => { settings.Tool = tool; Save(); })).ToArray();
        foreach (var item in toolOptions) tools.Items.Add(item);
        var snowfall = new MenuItem { Header = "Snowfall" };
        var fallOptions = Enum.GetValues<Snowfall>().Select(level =>
            Item(level.ToString(), () => { settings.Snowfall = level; Save(); })).ToArray();
        foreach (var item in fallOptions) snowfall.Items.Add(item);
        var update = new MenuItem
        {
            Header = "Update",
            Foreground = SystemColors.HotTrackBrush,
            Visibility = Visibility.Collapsed
        };
        update.Click += async (_, _) =>
        {
            if (updater.UsesBetaInstaller)
            {
                OpenUrl(PackageUpdater.BetaDownload.AbsoluteUri);
                return;
            }
            if (!await updater.Install())
                icon?.ShowBalloonTip(4000, "Snowy Update", "The update couldn’t be installed. Please try again later.", Tray.ToolTipIcon.Warning);
        };
        var windItem = Item("Wind…", () => Dispatcher.BeginInvoke(DispatcherPriority.Background, OpenWind));
        foreach (var item in new Control[] { support, new Separator(), open, pause, clear, tools,
                     snowfall, windItem, new Separator(), update, Item("Quit Snowy", () => Shutdown()) })
            menu.Items.Add(item);
        menu.Opened += (_, _) =>
        {
            // The tray can open the menu while Snowy has no active window.
            if (PresentationSource.FromVisual(menu) is HwndSource source) SetForegroundWindow(source.Handle);
            menu.Focus();
        };
        icon = new Tray.NotifyIcon { Icon = trayArt, Text = "Snowy controls", Visible = true };
        icon.MouseClick += (_, args) =>
        {
            if (args.Button is not (Tray.MouseButtons.Left or Tray.MouseButtons.Right) || menu.IsOpen) return;
            pause.Header = settings.Enabled ? "Pause Snow" : "Resume Snow";
            foreach (var item in toolOptions) item.IsChecked = Equals(item.Header, settings.Tool.ToString());
            foreach (var item in fallOptions) item.IsChecked = Equals(item.Header, settings.Snowfall.ToString());
            update.Visibility = updater.Available ? Visibility.Visible : Visibility.Collapsed;
            update.IsEnabled = !updater.Installing;
            menu.IsOpen = true;
        };
    }

    private static MenuItem Item(string text, Action action)
    {
        var item = new MenuItem { Header = text };
        item.Click += (_, _) => action();
        return item;
    }

    private void OpenSnowy()
    {
        if (main is null && desktop is not null && decorations is not null)
        {
            main = SnowyWindow.Create(desktop, decorations, dataDirectory, OpenWelcome);
            main.Closed += (_, _) => main = null;
        }
        Present(main);
    }

    private void OpenWelcome()
    {
        if (welcome is null)
        {
            welcome = WelcomeWindow.Create();
            if (main?.IsVisible == true)
            {
                welcome.Owner = main;
                welcome.WindowStartupLocation = WindowStartupLocation.CenterOwner;
            }
            welcome.Closed += (_, _) => welcome = null;
        }
        Present(welcome);
    }

    private void OpenWind()
    {
        if (wind is not null) { Present(wind); return; }
        var window = Interface.Window("Wind", 276, 294);
        window.ShowInTaskbar = false;
        window.ResizeMode = ResizeMode.NoResize;
        var stack = new StackPanel { Margin = new Thickness(12) };
        var pad = new WindPad(settings.Wind, settings.SetWind, Save);
        stack.Children.Add(pad);
        var caption = Interface.Detail("Drag to set direction and strength.");
        caption.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(caption);
        window.Content = stack;
        var cursor = Tray.Control.MousePosition;
        window.SourceInitialized += (_, _) =>
        {
            var source = PresentationSource.FromVisual(window);
            if (source?.CompositionTarget is not { } target) return;
            var bounds = Tray.Screen.FromPoint(cursor).WorkingArea;
            var transform = target.TransformFromDevice;
            var position = transform.Transform(new Point(cursor.X, cursor.Y));
            var topLeft = transform.Transform(new Point(bounds.Left, bounds.Top));
            var bottomRight = transform.Transform(new Point(bounds.Right, bounds.Bottom));
            window.Left = Math.Clamp(position.X - window.Width / 2, topLeft.X, Math.Max(topLeft.X, bottomRight.X - window.Width));
            window.Top = Math.Clamp(position.Y - window.Height - 8, topLeft.Y, Math.Max(topLeft.Y, bottomRight.Y - window.Height));
        };
        window.KeyDown += (_, args) => { if (args.Key == Key.Escape) window.Close(); };
        window.Deactivated += (_, _) => { if (window.IsVisible) window.Close(); };
        window.Closed += (_, _) => wind = null;
        wind = window;
        Present(window);
        pad.Focus();
    }

    private static void Present(Window? window)
    {
        if (window is null) return;
        if (!window.IsVisible) window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    private static void OpenUrl(string url)
    {
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (System.ComponentModel.Win32Exception) { }
    }

    private static string DataDirectory()
    {
        // Explorer needs an actual on-disk path when it applies a wallpaper from outside our package.
        try { return Path.Combine(global::Windows.Storage.ApplicationData.Current.LocalFolder.Path, "Snowy"); }
        catch (Exception error) when (error is InvalidOperationException or COMException)
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Snowy");
        }
    }

    private void Save() => settings.Save(dataDirectory);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);

    protected override void OnExit(ExitEventArgs e)
    {
        updateTimer?.Stop();
        signalWait?.Unregister(null);
        openSignal?.Dispose();
        icon?.Dispose();
        trayArt?.Dispose();
        desktop?.Dispose();
        instance?.Dispose();
        base.OnExit(e);
    }
}
