using System.Diagnostics;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Forms = System.Windows.Forms;
using Snowy.Core;

namespace Snowy.Windows.Desktop;

/// <summary>Display bounds and origin are physical pixels. Scale is physical pixels per WPF DIP.</summary>
public readonly record struct DesktopScreen(
    string Id, string Name, int Left, int Top, int Width, int Height, float Scale);

public readonly record struct DesktopOptions(
    bool Enabled, Snowfall Snowfall, Vector2 Wind, SnowTool Tool);

/// <summary>Paint context valid only while the DesktopHost.Frame event is running.</summary>
public sealed class DesktopFrameContext(
    DesktopScreen screen,
    IReadOnlyList<Body> bodies,
    DrawingContext canvas,
    float deltaSeconds,
    Vector2? pointer,
    Vector2 wind,
    SnowTool tool,
    bool reducedMotion)
{
    public DesktopScreen Screen { get; } = screen;
    public IReadOnlyList<Body> Bodies { get; } = bodies;
    public DrawingContext Canvas { get; } = canvas;
    public float DeltaSeconds { get; } = deltaSeconds;
    public Vector2? Pointer { get; } = pointer;
    public Vector2 Wind { get; } = wind;
    public SnowTool Tool { get; } = tool;
    public bool ReducedMotion { get; } = reducedMotion;
}

/// <summary>
/// Runs a transparent, click-through desktop layer per display. Samples visible top-level HWND
/// geometry and the bottom taskbar using read-only Win32/DWM APIs. All body coordinates are
/// display-local DIPs. The overlay hides snow beneath window rectangles and reveals the settled
/// profile above their top edges.
/// </summary>
public sealed class DesktopHost : IDisposable
{
    private const int FrameMilliseconds = 33;
    private const int GeometryMilliseconds = 100;
    private const int MaxDisplays = 6;
    private const int MaxPixels = 16_777_216;
    private const long MaxTotalPixels = 24_000_000;
    private const int MaxBodies = 512;
    private const int FullscreenEdgeTolerance = 4;
    private const int ReducedMotionFrameMilliseconds = 67;
    private const float WindowCornerDip = 8;
    private static readonly Brush SnowFill = CreateSnowFill();
    private static readonly Pen SnowEdge = CreateSnowEdge();
    private readonly Func<DesktopOptions> _getOptions;
    private readonly Dispatcher _dispatcher;
    private readonly DispatcherTimer _timer;
    private readonly Dictionary<string, DisplayRuntime> _displays = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, IReadOnlyList<Body>> _decorationBodies = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<IntPtr> _overlayHandles = new();
    private long _lastFrame;
    private long _lastGeometry;
    private bool _disposed;
    private bool _started;
    private bool _wasEnabled;
    private bool _powerConstrained;
    private static readonly Brush[] FlakeBrushes = CreateFlakeBrushes();

    /// <summary>Draw decoration content while the screen's DrawingContext is active.</summary>
    public event Action<DesktopFrameContext>? Frame;

    /// <summary>Native GDI device names, for example \.\DISPLAY1.</summary>
    public IReadOnlyList<DesktopScreen> Screens => _displays.Values.Select(item => item.Screen).ToArray();

    /// <summary>The host starts itself on the calling WPF dispatcher.</summary>
    public DesktopHost(Func<DesktopOptions> getOptions)
    {
        _getOptions = getOptions ?? throw new ArgumentNullException(nameof(getOptions));
        _dispatcher = Application.Current?.Dispatcher
            ?? throw new InvalidOperationException("DesktopHost requires a running WPF application.");
        _dispatcher.VerifyAccess();
        _timer = new DispatcherTimer(DispatcherPriority.Render, _dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(FrameMilliseconds)
        };
        _timer.Tick += OnTick;
        Start();
    }

    public void Start()
    {
        ThrowIfDisposed();
        _dispatcher.VerifyAccess();
        if (_started) return;
        _started = true;
        RebuildDisplays();
        _lastFrame = Stopwatch.GetTimestamp();
        _lastGeometry = _lastFrame;
        _timer.Start();
    }

    /// <summary>Returns current window, taskbar, search and decoration bodies for a monitor.</summary>
    public IReadOnlyList<Body> GetBodies(DesktopScreen screen) =>
        _displays.TryGetValue(screen.Id, out var runtime) ? runtime.Bodies : Array.Empty<Body>();

    /// <summary>Publishes decoration colliders in display-local DIPs. Safe to call off-dispatcher.</summary>
    public void SetDecorationBodies(DesktopScreen screen, IReadOnlyList<Body> bodies)
    {
        ArgumentNullException.ThrowIfNull(bodies);
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(() => SetDecorationBodies(screen, bodies));
            return;
        }
        if (!_displays.ContainsKey(screen.Id)) return;
        _decorationBodies[screen.Id] = bodies;
        _displays[screen.Id].SetDecorationBodies(bodies);
    }

    public void Clear()
    {
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.BeginInvoke(Clear);
            return;
        }
        foreach (var runtime in _displays.Values)
        {
            runtime.Simulation.Clear();
            runtime.View.InvalidateVisual();
        }
    }

    public void Dispose()
    {
        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.Invoke(Dispose);
            return;
        }
        if (_disposed) return;
        _disposed = true;
        _started = false;
        _timer.Stop();
        _timer.Tick -= OnTick;
        Frame = null;
        foreach (var runtime in _displays.Values) runtime.Dispose();
        _displays.Clear();
        _decorationBodies.Clear();
    }

    private void OnTick(object? sender, EventArgs e)
    {
        if (_disposed || !_started) return;
        var now = Stopwatch.GetTimestamp();
        var geometryChanged = false;
        var pollingInterval = _wasEnabled ? GeometryMilliseconds : 400;
        if (Stopwatch.GetElapsedTime(_lastGeometry, now).TotalMilliseconds >= pollingInterval)
        {
            geometryChanged = UpdateGeometry();
            _powerConstrained = Win32.IsPowerConstrained();
            _lastGeometry = now;
        }

        DesktopOptions options;
        try { options = _getOptions(); }
        catch (Exception error)
        {
            Debug.WriteLine($"Snowy settings unavailable ({error.GetType().Name}).");
            return;
        }
        if (!options.Enabled)
        {
            _wasEnabled = false;
            if (geometryChanged)
                foreach (var runtime in _displays.Values) runtime.View.InvalidateVisual();
            _timer.Interval = TimeSpan.FromMilliseconds(400);
            return;
        }
        _wasEnabled = true;

        var dt = Math.Clamp((float)Stopwatch.GetElapsedTime(_lastFrame, now).TotalSeconds, 0, 0.1f);
        _lastFrame = now;
        var reduceMotion = !SystemParameters.ClientAreaAnimation;
        var frameInterval = reduceMotion || _powerConstrained
            ? ReducedMotionFrameMilliseconds
            : FrameMilliseconds;
        var cursor = GetCursorPos();
        var anyVisible = false;
        foreach (var runtime in _displays.Values)
        {
            if (IsFullscreen(runtime.Screen))
            {
                if (runtime.Visible) runtime.Window.Hide();
                runtime.Visible = false;
                continue;
            }
            if (!runtime.Visible)
            {
                runtime.Window.Show();
                runtime.Window.Anchor(runtime.Screen);
                runtime.Visible = true;
            }
            var pointer = LocalPointer(cursor, runtime.Screen);
            var wind = ClampWind(options.Wind);
            runtime.Simulation.Step(dt, options.Snowfall, wind, pointer, options.Tool, reduceMotion);
            runtime.SetFrame(dt, pointer, wind, options.Tool, reduceMotion);
            runtime.View.InvalidateVisual();
            anyVisible = true;
        }
        _timer.Interval = TimeSpan.FromMilliseconds(anyVisible ? frameInterval : 100);
    }

    private void RebuildDisplays()
    {
        var screens = EligibleScreens().Select(CreateScreen).ToArray();
        var validIds = screens.Select(s => s.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var staleId in _displays.Keys.Where(id => !validIds.Contains(id)).ToArray())
        {
            _overlayHandles.Remove(_displays[staleId].Window.Handle);
            _displays[staleId].Dispose();
            _displays.Remove(staleId);
            _decorationBodies.Remove(staleId);
        }
        foreach (var screen in screens)
        {
            if (_displays.TryGetValue(screen.Id, out var current) && current.Screen == screen) continue;
            if (current is not null)
            {
                _overlayHandles.Remove(current.Window.Handle);
                current.Dispose();
                _displays.Remove(screen.Id);
            }
            var runtime = new DisplayRuntime(this, screen);
            _overlayHandles.Add(runtime.Window.Handle);
            if (_decorationBodies.TryGetValue(screen.Id, out var decorations))
                runtime.SetDecorationBodies(decorations);
            _displays.Add(screen.Id, runtime);
        }
        UpdateGeometryCore();
    }

    private bool UpdateGeometry()
    {
        if (EligibleScreens().Length != _displays.Count ||
            _displays.Values.Any(item => !item.Screen.MatchesCurrentScreen()))
        {
            RebuildDisplays();
            return true;
        }
        return UpdateGeometryCore();
    }

    private bool UpdateGeometryCore()
    {
        var windows = NativeTracker.VisibleWindows(_overlayHandles);
        var taskbars = NativeTracker.BottomTaskbars();
        var changed = false;
        foreach (var runtime in _displays.Values)
        {
            var screen = runtime.Screen;
            var bodies = new List<Body>(Math.Min(MaxBodies, windows.Count + taskbars.Count));
            var masks = new List<Body>(windows.Count + taskbars.Count);
            foreach (var window in windows)
            {
                if (!Intersects(window.Bounds, screen)) continue;
                var bounds = LocalBounds(window.Bounds, screen);
                var body = new Body(window.Id, bounds.Position, bounds.Size,
                    window.IsSearch ? BodyKind.Search : BodyKind.Window, WindowCornerDip);
                masks.Add(body);
                if (window.HasSurface && bodies.Count < MaxBodies - taskbars.Count) bodies.Add(body);
            }
            foreach (var taskbar in taskbars)
            {
                if (!Intersects(taskbar.Bounds, screen)) continue;
                var bounds = LocalBounds(taskbar.Bounds, screen);
                var body = new Body(taskbar.Id, bounds.Position, bounds.Size, BodyKind.Taskbar, 0);
                masks.Add(body);
                if (IsBottomTaskbar(taskbar.Bounds, screen)) bodies.Add(body);
            }
            changed |= runtime.SetShellBodies(bodies, masks);
        }
        return changed;
    }

    private void Render(DisplayRuntime runtime, DrawingContext canvas)
    {
        var screen = runtime.Screen;
        // This cached region is rebuilt on the geometry poll, rather than for each paint.
        // The topmost transparent window excludes real HWND interiors so snow stays behind them.
        canvas.PushClip(runtime.VisibleArea);
        try
        {
            Frame?.Invoke(new DesktopFrameContext(screen, runtime.Bodies, canvas,
                runtime.DeltaSeconds, runtime.Pointer, runtime.Wind, runtime.Tool, runtime.ReducedMotion));
        }
        catch (Exception error)
        {
            Debug.WriteLine($"Snowy frame callback failed ({error.GetType().Name}).");
        }
        try { DrawSnow(canvas, runtime.Simulation); }
        catch (Exception error) { Debug.WriteLine($"Snowy snow rendering failed ({error.GetType().Name})."); }
        finally { canvas.Pop(); }
    }

    private static void DrawSnow(DrawingContext canvas, SnowSimulation simulation)
    {
        foreach (var profile in simulation.Profiles)
        {
            if (profile.Heights.Length < 2 || profile.Spacing <= 0) continue;
            var hasSnow = false;
            for (var i = 0; i < profile.Heights.Length; i++)
            {
                if (profile.Heights[i] > 0.5f) { hasSnow = true; break; }
            }
            if (!hasSnow) continue;
            var geometry = new StreamGeometry();
            using (var path = geometry.Open())
            {
                path.BeginFigure(new Point(profile.X, profile.Y - profile.Heights[0]), true, true);
                for (var index = 1; index < profile.Heights.Length; index++)
                    path.LineTo(new Point(profile.X + index * profile.Spacing,
                        profile.Y - profile.Heights[index]), true, false);
                var endX = profile.X + (profile.Heights.Length - 1) * profile.Spacing;
                path.LineTo(new Point(endX, profile.Y + 1), true, false);
                path.LineTo(new Point(profile.X, profile.Y + 1), true, false);
            }
            geometry.Freeze();
            canvas.DrawGeometry(SnowFill, SnowEdge, geometry);
        }
        foreach (var flake in simulation.Flakes)
        {
            var alpha = (byte)Math.Clamp((int)(flake.Opacity * 245), 0, 245);
            canvas.DrawEllipse(FlakeBrushes[alpha], null, new Point(flake.Position.X, flake.Position.Y),
                flake.Radius, flake.Radius);
        }
        foreach (var patch in simulation.LoosePatches)
        {
            if (patch.Width <= 0 || patch.Height <= 0) continue;
            var rectangle = new Rect(patch.Position.X - patch.Width * 0.5,
                patch.Position.Y - patch.Height * 0.5, patch.Width, patch.Height);
            var opacity = Math.Clamp(patch.Opacity, 0, 1);
            canvas.PushOpacity(opacity);
            canvas.DrawRoundedRectangle(SnowFill, null, rectangle,
                Math.Min(patch.Height * 0.45, patch.Width * 0.2),
                Math.Min(patch.Height * 0.45, patch.Width * 0.2));
            canvas.Pop();
        }
    }

    private static Brush CreateSnowFill()
    {
        var brush = new LinearGradientBrush(Color.FromArgb(244, 255, 255, 255),
            Color.FromArgb(238, 215, 234, 250), new Point(0, 0), new Point(0, 1));
        brush.Freeze();
        return brush;
    }

    private static Pen CreateSnowEdge()
    {
        var brush = new SolidColorBrush(Color.FromArgb(238, 255, 255, 255));
        brush.Freeze();
        var pen = new Pen(brush, 1.1);
        pen.Freeze();
        return pen;
    }

    private static Brush[] CreateFlakeBrushes()
    {
        var brushes = new Brush[246];
        for (var alpha = 0; alpha < brushes.Length; alpha++)
        {
            var brush = new SolidColorBrush(Color.FromArgb((byte)alpha, 251, 253, 255));
            brush.Freeze();
            brushes[alpha] = brush;
        }
        return brushes;
    }

    private static Forms.Screen[] EligibleScreens()
    {
        var selected = new List<Forms.Screen>(MaxDisplays);
        long totalPixels = 0;
        foreach (var screen in Forms.Screen.AllScreens)
        {
            if (selected.Count >= MaxDisplays) break;
            var area = (long)screen.Bounds.Width * screen.Bounds.Height;
            if (screen.Bounds.Width <= 0 || screen.Bounds.Height <= 0 || area > MaxPixels ||
                totalPixels + area > MaxTotalPixels) continue;
            selected.Add(screen);
            totalPixels += area;
        }
        return selected.ToArray();
    }

    private static DesktopScreen CreateScreen(Forms.Screen screen)
    {
        var rect = screen.Bounds;
        var scale = Win32.GetScaleAt(rect.Left + rect.Width / 2, rect.Top + rect.Height / 2);
        const string devicePrefix = @"\\.\DISPLAY";
        var name = screen.DeviceName.StartsWith(devicePrefix, StringComparison.OrdinalIgnoreCase)
            ? $"Display {screen.DeviceName[devicePrefix.Length..]}"
            : screen.DeviceName;
        return new DesktopScreen(screen.DeviceName, name,
            rect.Left, rect.Top, rect.Width, rect.Height, scale);
    }

    private static bool Intersects(PixelRect rect, DesktopScreen screen) =>
        rect.Right > screen.Left && rect.Left < screen.Left + screen.Width &&
        rect.Bottom > screen.Top && rect.Top < screen.Top + screen.Height;

    private static bool IsBottomTaskbar(PixelRect rect, DesktopScreen screen)
    {
        if (!Intersects(rect, screen)) return false;
        var nearBottom = Math.Abs(rect.Bottom - (screen.Top + screen.Height)) <= Math.Max(24, screen.Height * 0.04);
        var width = rect.Right - rect.Left;
        var visibleHeight = Math.Min(rect.Bottom, screen.Top + screen.Height) - Math.Max(rect.Top, screen.Top);
        return nearBottom && width >= screen.Width * 0.55 && visibleHeight >= 12 && width > (rect.Bottom - rect.Top) * 2;
    }

    private static (Vector2 Position, Vector2 Size) LocalBounds(PixelRect rect, DesktopScreen screen)
    {
        var left = Math.Max(rect.Left, screen.Left);
        var top = Math.Max(rect.Top, screen.Top);
        var right = Math.Min(rect.Right, screen.Left + screen.Width);
        var bottom = Math.Min(rect.Bottom, screen.Top + screen.Height);
        var scale = Math.Max(0.5f, screen.Scale);
        return (new Vector2((left - screen.Left) / scale, (top - screen.Top) / scale),
            new Vector2((right - left) / scale, (bottom - top) / scale));
    }

    private static Vector2 ClampWind(Vector2 wind)
    {
        if (!float.IsFinite(wind.X) || !float.IsFinite(wind.Y)) return Vector2.Zero;
        var length = wind.Length();
        return length > 1 ? wind / length : wind;
    }

    private static PixelPoint GetCursorPos() => Win32.GetCursorPos(out var point) ? point : default;

    private static Vector2? LocalPointer(PixelPoint point, DesktopScreen screen)
    {
        if (point.X < screen.Left || point.X >= screen.Left + screen.Width ||
            point.Y < screen.Top || point.Y >= screen.Top + screen.Height) return null;
        return new Vector2((point.X - screen.Left) / screen.Scale, (point.Y - screen.Top) / screen.Scale);
    }

    private static bool IsFullscreen(DesktopScreen screen)
    {
        var handle = Win32.GetForegroundWindow();
        if (handle == IntPtr.Zero || !Win32.GetWindowRect(handle, out var rect)) return false;
        return Math.Abs(rect.Left - screen.Left) <= FullscreenEdgeTolerance &&
            Math.Abs(rect.Top - screen.Top) <= FullscreenEdgeTolerance &&
            Math.Abs(rect.Right - (screen.Left + screen.Width)) <= FullscreenEdgeTolerance &&
            Math.Abs(rect.Bottom - (screen.Top + screen.Height)) <= FullscreenEdgeTolerance;
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(DesktopHost));
    }

    private sealed class DisplayRuntime : IDisposable
    {
        private IReadOnlyList<Body> _decorationBodies = Array.Empty<Body>();
        public DesktopScreen Screen { get; }
        public OverlayWindow Window { get; }
        public OverlayCanvas View { get; }
        public SnowSimulation Simulation { get; }
        public Geometry VisibleArea { get; private set; }
        public IReadOnlyList<Body> ShellBodies { get; private set; } = Array.Empty<Body>();
        private IReadOnlyList<Body> _masks = Array.Empty<Body>();
        public IReadOnlyList<Body> Bodies { get; private set; } = Array.Empty<Body>();
        public bool Visible { get; set; }
        public float DeltaSeconds { get; private set; }
        public Vector2? Pointer { get; private set; }
        public Vector2 Wind { get; private set; }
        public SnowTool Tool { get; private set; }
        public bool ReducedMotion { get; private set; }

        public DisplayRuntime(DesktopHost host, DesktopScreen screen)
        {
            Screen = screen;
            Simulation = new SnowSimulation(
                Math.Max(1, (int)Math.Ceiling(screen.Width / screen.Scale)),
                Math.Max(1, (int)Math.Ceiling(screen.Height / screen.Scale)));
            VisibleArea = new RectangleGeometry(new Rect(0, 0, screen.Width / screen.Scale, screen.Height / screen.Scale));
            View = new OverlayCanvas(host, this);
            Window = new OverlayWindow(screen, View);
            Window.Show();
            Visible = true;
            Window.Anchor(screen);
        }

        public bool SetShellBodies(IReadOnlyList<Body> bodies, IReadOnlyList<Body> masks)
        {
            var bodiesChanged = !ShellBodies.SequenceEqual(bodies);
            var masksChanged = !_masks.SequenceEqual(masks);
            if (bodiesChanged)
            {
                ShellBodies = bodies;
                MergeBodies();
            }
            if (masksChanged)
            {
                _masks = masks;
                RebuildVisibleArea();
            }
            return bodiesChanged || masksChanged;
        }

        public void SetDecorationBodies(IReadOnlyList<Body> bodies)
        {
            if (_decorationBodies.SequenceEqual(bodies)) return;
            _decorationBodies = bodies;
            MergeBodies();
        }

        private void MergeBodies()
        {
            var merged = new List<Body>(ShellBodies.Count + _decorationBodies.Count);
            merged.AddRange(ShellBodies);
            merged.AddRange(_decorationBodies);
            Bodies = merged;
            Simulation.SetBodies(Bodies);
        }

        private void RebuildVisibleArea()
        {
            var bounds = new RectangleGeometry(new Rect(0, 0,
                Screen.Width / Screen.Scale, Screen.Height / Screen.Scale));
            var occluders = new GeometryGroup { FillRule = FillRule.Nonzero };
            foreach (var body in _masks)
            {
                var rect = new Rect(body.Position.X, body.Position.Y,
                    Math.Max(0, body.Size.X), Math.Max(0, body.Size.Y));
                if (!rect.IsEmpty && rect.IntersectsWith(bounds.Rect))
                {
                    var radius = Math.Clamp(body.CornerRadius, 0, (float)Math.Min(rect.Width, rect.Height) * 0.5f);
                    occluders.Children.Add(new RectangleGeometry(rect, radius, radius));
                }
            }
            occluders.Freeze();
            var visible = new CombinedGeometry(GeometryCombineMode.Exclude, bounds, occluders);
            visible.Freeze();
            VisibleArea = visible;
        }

        public void SetFrame(float dt, Vector2? pointer, Vector2 wind, SnowTool tool, bool reducedMotion)
        {
            DeltaSeconds = dt;
            Pointer = pointer;
            Wind = wind;
            Tool = tool;
            ReducedMotion = reducedMotion;
        }

        public void Dispose()
        {
            Simulation.Clear();
            Window.Close();
        }
    }

    private sealed class OverlayCanvas(DesktopHost host, DisplayRuntime runtime) : FrameworkElement
    {
        protected override void OnRender(DrawingContext drawingContext)
        {
            base.OnRender(drawingContext);
            host.Render(runtime, drawingContext);
        }
    }

    private sealed class OverlayWindow : Window
    {
        private readonly DesktopScreen _screen;
        private IntPtr _handle;
        public IntPtr Handle => _handle;

        public OverlayWindow(DesktopScreen screen, FrameworkElement content)
        {
            _screen = screen;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ShowActivated = false;
            ShowInTaskbar = false;
            Focusable = false;
            ResizeMode = ResizeMode.NoResize;
            Topmost = true;
            Content = content;
            Left = screen.Left / screen.Scale;
            Top = screen.Top / screen.Scale;
            Width = screen.Width / screen.Scale;
            Height = screen.Height / screen.Scale;
            SourceInitialized += OnSourceInitialized;
        }

        private void OnSourceInitialized(object? sender, EventArgs e)
        {
            _handle = new WindowInteropHelper(this).Handle;
            var style = Win32.GetWindowLongPtr(_handle, Win32.GwlExStyle).ToInt64();
            style |= Win32.WsExTransparent | Win32.WsExToolWindow | Win32.WsExNoActivate | Win32.WsExLayered;
            Win32.SetWindowLongPtr(_handle, Win32.GwlExStyle, new IntPtr(style));
            Anchor(_screen);
        }

        public void Anchor(DesktopScreen screen)
        {
            if (_handle != IntPtr.Zero)
                Win32.SetWindowPos(_handle, Win32.HwndTopmost, screen.Left, screen.Top,
                    screen.Width, screen.Height, Win32.SwpNoActivate | Win32.SwpShowWindow);
        }
    }

    private readonly record struct TrackedWindow(long Id, PixelRect Bounds, bool IsSearch, bool HasSurface);
    private readonly record struct TrackedTaskbar(long Id, PixelRect Bounds);

    private static class NativeTracker
    {
        private static readonly HashSet<string> SearchProcesses = new(StringComparer.OrdinalIgnoreCase)
        {
            "SearchHost", "SearchApp", "StartMenuExperienceHost"
        };

        public static List<TrackedWindow> VisibleWindows(IReadOnlySet<IntPtr> overlayHandles)
        {
            var result = new List<TrackedWindow>();
            var processNames = new Dictionary<uint, string?>();
            Win32.EnumWindows((handle, _) =>
            {
                if (result.Count >= MaxBodies) return false;
                if (overlayHandles.Contains(handle)) return true;
                if (!Win32.IsWindowVisible(handle) || Win32.IsIconic(handle) || !Win32.GetWindowRect(handle, out var bounds))
                    return true;
                if (bounds.Right - bounds.Left < 40 || bounds.Bottom - bounds.Top < 40) return true;
                if (Win32.DwmGetWindowAttribute(handle, Win32.DwmwaCloaked, out int cloaked, sizeof(int)) == 0 && cloaked != 0)
                    return true;
                Win32.GetWindowThreadProcessId(handle, out var processId);
                var className = Win32.ClassName(handle);
                if (className is "Progman" or "WorkerW" or "Shell_TrayWnd" or "Shell_SecondaryTrayWnd")
                    return true;
                if (!processNames.TryGetValue(processId, out var process))
                {
                    process = Win32.TryGetProcessName((int)processId);
                    processNames[processId] = process;
                }
                var search = SearchProcesses.Contains(process ?? string.Empty) || Win32.LooksLikeSearchClass(className);
                var actualBounds = bounds;
                if (Win32.DwmGetWindowAttribute(handle, Win32.DwmwaExtendedFrameBounds, out PixelRect extended, Marshal.SizeOf<PixelRect>()) == 0 &&
                    extended.Right > extended.Left && extended.Bottom > extended.Top)
                    actualBounds = extended;
                var style = Win32.GetWindowLongPtr(handle, Win32.GwlExStyle).ToInt64();
                // Snap previews and shell flyouts occlude the animation while visible. They do
                // not become solids that erase snow or leave piles when they dismiss.
                var transientShell = process is "Widgets" or "WidgetService" or "ShellExperienceHost" or "ShellHost" ||
                    (process?.Equals("explorer", StringComparison.OrdinalIgnoreCase) == true &&
                        className is not ("CabinetWClass" or "ExploreWClass")) ||
                    className.Contains("SnapAssist", StringComparison.OrdinalIgnoreCase) ||
                    className.Contains("SnapBar", StringComparison.OrdinalIgnoreCase) ||
                    className is "MultitaskingViewFrame";
                var hasSurface = search || (!transientShell && (style & Win32.WsExToolWindow) == 0);
                result.Add(new TrackedWindow(handle.ToInt64(), actualBounds, search, hasSurface));
                return true;
            }, IntPtr.Zero);
            return result;
        }

        public static List<TrackedTaskbar> BottomTaskbars()
        {
            var result = new List<TrackedTaskbar>();
            Win32.EnumWindows((handle, _) =>
            {
                var className = Win32.ClassName(handle);
                if ((className is "Shell_TrayWnd" or "Shell_SecondaryTrayWnd") &&
                    Win32.IsWindowVisible(handle) && Win32.GetWindowRect(handle, out var bounds))
                    result.Add(new TrackedTaskbar(handle.ToInt64(), bounds));
                return true;
            }, IntPtr.Zero);
            return result;
        }
    }

    private readonly record struct PixelRect(int Left, int Top, int Right, int Bottom);
    private readonly record struct PixelPoint(int X, int Y);

    private static class Win32
    {
        public const int GwlExStyle = -20;
        public const long WsExTransparent = 0x00000020L;
        public const long WsExToolWindow = 0x00000080L;
        public const long WsExLayered = 0x00080000L;
        public const long WsExNoActivate = 0x08000000L;
        public const uint DwmwaExtendedFrameBounds = 9;
        public const uint DwmwaCloaked = 14;
        public const uint SwpNoActivate = 0x0010;
        public const uint SwpShowWindow = 0x0040;
        public static readonly IntPtr HwndTopmost = new(-1);
        public delegate bool EnumWindowProc(IntPtr handle, IntPtr data);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool EnumWindows(EnumWindowProc callback, IntPtr data);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsWindowVisible(IntPtr handle);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool IsIconic(IntPtr handle);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetWindowRect(IntPtr handle, out PixelRect rect);
        [DllImport("user32.dll")]
        internal static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        internal static extern uint GetWindowThreadProcessId(IntPtr handle, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        internal static extern IntPtr FindWindow(string className, string? windowName);
        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
        internal static extern IntPtr GetWindowLongPtr(IntPtr handle, int index);
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
        internal static extern IntPtr SetWindowLongPtr(IntPtr handle, int index, IntPtr value);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool GetCursorPos(out PixelPoint point);
        [DllImport("dwmapi.dll")]
        internal static extern int DwmGetWindowAttribute(IntPtr handle, uint attribute, out int value, int size);
        [DllImport("dwmapi.dll")]
        internal static extern int DwmGetWindowAttribute(IntPtr handle, uint attribute, out PixelRect value, int size);
        [DllImport("shcore.dll")]
        private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);
        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromPoint(PixelPoint point, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "GetClassNameW")]
        private static extern int GetClassNameNative(IntPtr handle, StringBuilder text, int capacity);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int size);
        [DllImport("kernel32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

        [StructLayout(LayoutKind.Sequential)]
        private struct SystemPowerStatus
        {
            public byte AcLineStatus;
            public byte BatteryFlag;
            public byte BatteryLifePercent;
            public byte SystemStatusFlag;
            public uint BatteryLifeTime;
            public uint BatteryFullLifeTime;
        }

        internal static bool IsPowerConstrained() =>
            GetSystemPowerStatus(out var status) &&
            (status.AcLineStatus == 0 || status.SystemStatusFlag == 1 || (status.BatteryFlag & 0x04) != 0);

        internal static string ClassName(IntPtr handle)
        {
            var buffer = new StringBuilder(256);
            var length = GetClassNameNative(handle, buffer, buffer.Capacity);
            return length > 0 ? buffer.ToString() : string.Empty;
        }

        internal static string? TryGetProcessName(int processId)
        {
            if (processId <= 0) return null;
            var process = OpenProcess(0x1000, false, processId);
            if (process == IntPtr.Zero) return null;
            try
            {
                var buffer = new StringBuilder(1024);
                var size = buffer.Capacity;
                return QueryFullProcessImageName(process, 0, buffer, ref size)
                    ? Path.GetFileNameWithoutExtension(buffer.ToString())
                    : null;
            }
            finally { CloseHandle(process); }
        }

        internal static bool LooksLikeSearchClass(string className)
        {
            if (className.Contains("Search", StringComparison.OrdinalIgnoreCase) ||
                className.Contains("StartMenuExperienceHost", StringComparison.OrdinalIgnoreCase) ||
                className.Contains("WidgetBoard", StringComparison.OrdinalIgnoreCase) ||
                className.Contains("WidgetsBoard", StringComparison.OrdinalIgnoreCase) ||
                className.Contains("XamlExplorerHostIslandWindow", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        internal static float GetScaleAt(int x, int y)
        {
            var monitor = MonitorFromPoint(new PixelPoint(x, y), 2);
            if (monitor == IntPtr.Zero || GetDpiForMonitor(monitor, 0, out var dpiX, out _) != 0 || dpiX == 0)
                return 1f;
            return Math.Clamp(dpiX / 96f, 0.75f, 4f);
        }
    }
}

internal static class ScreenIdentity
{
    internal static bool MatchesCurrentScreen(this DesktopScreen target) =>
        Forms.Screen.AllScreens.Any(screen =>
            string.Equals(screen.DeviceName, target.Id, StringComparison.OrdinalIgnoreCase) &&
            screen.Bounds.Left == target.Left && screen.Bounds.Top == target.Top &&
            screen.Bounds.Width == target.Width && screen.Bounds.Height == target.Height);
}
