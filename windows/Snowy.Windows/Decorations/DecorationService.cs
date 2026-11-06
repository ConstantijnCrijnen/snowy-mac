using System.Numerics;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using Snowy.Core;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Decorations;

/// <summary>Per-monitor persisted pixel props and softly moving strings of lights.</summary>
public sealed class DecorationService
{
    private const double PixelScale = 3;
    private readonly string dataDirectory;
    private readonly DecorationCatalog catalog;
    private readonly Dictionary<string, DecorationScene> scenes = new(StringComparer.Ordinal);
    private readonly Dictionary<string, LightRuntime> lightRuntimes = new(StringComparer.Ordinal);
    private readonly Dictionary<Guid, float> propVelocities = [];
    private IReadOnlyDictionary<string, IReadOnlyList<Body>> iconBodies = new Dictionary<string, IReadOnlyList<Body>>(StringComparer.OrdinalIgnoreCase);
    private readonly object gate = new();
    private DesktopHost? host;
    private bool loaded;
    private Vector2? previousCursor;
    private DateTime lastMotionSave = DateTime.UtcNow;
    private DateTime lastIconPoll = DateTime.MinValue;
    private Task? iconPoll;
    private bool includeDesktopIcons;
    private DateTime lastIconSuccess = DateTime.MinValue;
    private bool editorOpen;
    private int iconGeneration;
    private SceneEditorWindow? editorWindow;

    public event EventHandler? Changed;
    public DecorationCatalog Catalog => catalog;
    public bool IncludeDesktopIcons => includeDesktopIcons;

    public DecorationService(string dataDirectory, DecorationCatalog? catalog = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(dataDirectory);
        this.dataDirectory = Path.GetFullPath(dataDirectory);
        this.catalog = catalog ?? new DecorationCatalog();
    }

    public void Attach(DesktopHost desktopHost) => host = desktopHost ?? throw new ArgumentNullException(nameof(desktopHost));

    public void SetDesktopIconAnchors(bool enabled)
    {
        EnsureLoaded();
        if (includeDesktopIcons == enabled) return;
        includeDesktopIcons = enabled;
        lock (gate)
        {
            iconGeneration++;
            try
            {
                Persist();
                if (!enabled) iconBodies = new Dictionary<string, IReadOnlyList<Body>>(StringComparer.OrdinalIgnoreCase);
            }
            catch
            {
                includeDesktopIcons = !enabled;
                iconGeneration++;
                throw;
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public DecorationScene Scene(string screenId)
    {
        EnsureLoaded();
        lock (gate) return scenes.GetValueOrDefault(screenId, DecorationScene.Empty);
    }

    public void Save(string screenId, DecorationScene scene)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(screenId);
        EnsureLoaded();
        lock (gate)
        {
            var hadPrevious = scenes.TryGetValue(screenId, out var previous);
            scenes[screenId] = scene.Bounded(catalog.Ids);
            try { Persist(); }
            catch
            {
                if (hadPrevious) scenes[screenId] = previous!;
                else scenes.Remove(screenId);
                throw;
            }
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void SelectPreset(string screenId, DecorationPreset preset, DesktopScreen screen)
    {
        var taskbar = IsBottomTaskbar(GetHostBodies(screen), screen);
        Save(screenId, catalog.CreatePreset(preset, DipWidth(screen), taskbar.HasValue));
    }

    public IReadOnlyList<Body> GetBodies(DesktopScreen screen) =>
        BuildBodies(screen, GetHostBodies(screen));

    public IReadOnlyList<Body> GetBodies(DesktopFrameContext context) =>
        BuildBodies(context.Screen, context.Bodies);

    public void Render(DesktopFrameContext context)
    {
        var screen = context.Screen;
        var current = AdvanceProps(screen, Scene(screen.Id), context.Bodies, context.Pointer,
            context.DeltaSeconds, context.Tool);
        var currentBodies = BuildBodies(screen, context.Bodies);
        var id = screen.Id;
        var runtime = GetLightRuntime(id, current.Lights, screen);
        var hasIconAnchors = current.Lights.Any(light => light.Anchors.Any(anchor => anchor.BodyId < 0));
        var detached = runtime.Advance(current.Lights, screen, GetAnchorBodies(screen, editorOpen || hasIconAnchors), context.Wind,
            context.Pointer, context.DeltaSeconds, context.ReducedMotion);
        if (detached.Count > 0)
        {
            var updated = current.Lights.Select(light => detached.FirstOrDefault(item => item.Id == light.Id) ?? light).ToList();
            current = current with { Lights = updated };
            try { Save(screen.Id, current); }
            catch (IOException) { }
        }

        var drawing = context.Canvas;
        RenderProps(drawing, screen, context.Bodies, current.Props);
        RenderLights(drawing, runtime);
        PublishBodies(screen, currentBodies);
    }

    private DecorationScene AdvanceProps(DesktopScreen screen, DecorationScene current,
        IReadOnlyList<Body> bodies, Vector2? pointer, float elapsed, SnowTool tool)
    {
        var now = DateTime.UtcNow;
        var dt = Math.Clamp(float.IsFinite(elapsed) ? elapsed : 1f / 30, 1f / 120, 1f / 20);
        if (pointer is null || current.Props.Count == 0)
        {
            previousCursor = null;
            return current;
        }
        var cursor = pointer.Value;
        var previous = previousCursor;
        previousCursor = cursor;
        var props = current.Props.ToList();
        var changed = false;
        var screenWidth = DipWidth(screen);
        var taskbar = IsBottomTaskbar(bodies, screen);
        for (var index = 0; index < props.Count; index++)
        {
            var prop = props[index];
            if (!prop.Pushes || catalog.Find(prop.AssetId) is not { } piece) continue;
            var multiplier = tool == SnowTool.Shovel ? 1.5f : 1f;
            var width = piece.Width * (float)(PixelScale * prop.Scale);
            var height = piece.Height * (float)(PixelScale * prop.Scale);
            var left = (float)(prop.X * screenWidth - width / 2);
            var top = prop.Support == DecorationSupport.TaskbarTop && taskbar is { } bar
                ? (float)bar.Top - height : (float)DipHeight(screen) - height;
            var closest = new Vector2(Math.Clamp(cursor.X, left, left + width), Math.Clamp(cursor.Y, top, top + height));
            var velocity = propVelocities.GetValueOrDefault(prop.Id);
            if (previous is { } oldCursor)
            {
                var distance = Vector2.DistanceSquared(oldCursor, cursor);
                if (distance > 0.1f && Vector2.DistanceSquared(cursor, closest) <= 34 * 34)
                {
                    var horizontal = cursor.X - oldCursor.X;
                    if (MathF.Abs(horizontal) > 0.1f)
                        velocity = Math.Clamp(velocity + horizontal / dt * 0.16f * multiplier, -340, 340);
                }
            }
            var movement = velocity * dt;
            velocity *= MathF.Exp(-7.5f * dt);
            if (MathF.Abs(velocity) < 7) velocity = 0;
            var center = prop.X * screenWidth + movement;
            center = Math.Clamp(center, width / 2, Math.Max(width / 2, screenWidth - width / 2));
            foreach (var other in props)
            {
                if (other.Id == prop.Id || other.Support != prop.Support || catalog.Find(other.AssetId) is not { } otherPiece) continue;
                var otherHeight = otherPiece.Height * PixelScale * other.Scale;
                var otherTop = other.Support == DecorationSupport.TaskbarTop && taskbar is { } taskbarBounds
                    ? taskbarBounds.Top - otherHeight : DipHeight(screen) - otherHeight;
                if (top + height < otherTop + 2 || otherTop + otherHeight < top + 2) continue;
                var otherWidth = otherPiece.Width * PixelScale * other.Scale;
                var otherCenter = other.X * screenWidth;
                if (movement > 0 && otherCenter > prop.X * screenWidth)
                    center = Math.Min(center, otherCenter - otherWidth / 2 - width / 2);
                else if (movement < 0 && otherCenter < prop.X * screenWidth)
                    center = Math.Max(center, otherCenter + otherWidth / 2 + width / 2);
            }
            velocity = center != prop.X * screenWidth + movement ? 0 : velocity;
            propVelocities[prop.Id] = velocity;
            var x = Math.Clamp(center / screenWidth, 0, 1);
            if (Math.Abs(x - prop.X) > 0.00001)
            {
                props[index] = prop with { X = x };
                changed = true;
            }
        }
        if (!changed) return current;
        var updated = current with { Props = props };
        lock (gate) scenes[screen.Id] = updated;
        if ((now - lastMotionSave).TotalSeconds >= 1)
        {
            try
            {
                lock (gate) Persist();
                lastMotionSave = now;
            }
            catch (IOException) { /* Keep the moving scene responsive if storage is unavailable. */ }
        }
        return updated;
    }

    public void OpenEditor(DesktopHost host)
    {
        Attach(host);
        if (editorWindow is { IsVisible: true }) { editorWindow.Activate(); return; }
        editorOpen = true;
        editorWindow = new SceneEditorWindow(this, host, catalog);
        editorWindow.Closed += (_, _) => { editorOpen = false; editorWindow = null; };
        editorWindow.Show();
    }

    public IReadOnlyList<Body> GetAnchorBodies(DesktopScreen screen, bool allowRefresh = false)
    {
        var bodies = GetHostBodies(screen);
        if (!includeDesktopIcons) return bodies;
        if (allowRefresh) RefreshIconGeometry();
        lock (gate)
            return iconBodies.TryGetValue(screen.Id, out var icons) ? bodies.Concat(icons).ToArray() : bodies;
    }

    private void RefreshIconGeometry()
    {
        var desktop = host;
        if (desktop is null || !includeDesktopIcons || (DateTime.UtcNow - lastIconPoll).TotalSeconds < 1) return;
        var screens = desktop.Screens.ToArray();
        if (screens.Length == 0) return;
        lock (gate)
        {
            if (lastIconSuccess != DateTime.MinValue && (DateTime.UtcNow - lastIconSuccess).TotalSeconds > 10)
                iconBodies = new Dictionary<string, IReadOnlyList<Body>>(StringComparer.OrdinalIgnoreCase);
            if (iconPoll is { IsCompleted: false }) return;
            lastIconPoll = DateTime.UtcNow;
            var generation = iconGeneration;
            iconPoll = Task.Run(() => ExplorerIconGeometry.Read(screens)).ContinueWith(task =>
            {
                if (task.Status != TaskStatus.RanToCompletion || task.Result is null) return;
                lock (gate)
                {
                    if (!includeDesktopIcons || generation != iconGeneration) return;
                    iconBodies = task.Result;
                    lastIconSuccess = DateTime.UtcNow;
                }
            }, TaskScheduler.Default);
        }
    }

    public void Clear(string screenId)
    {
        EnsureLoaded();
        lock (gate)
        {
            var hadPrevious = scenes.Remove(screenId, out var previous);
            try { Persist(); }
            catch
            {
                if (hadPrevious) scenes[screenId] = previous!;
                throw;
            }
            lightRuntimes.Remove(screenId);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private IReadOnlyList<Body> GetHostBodies(DesktopScreen screen) =>
        host?.GetBodies(screen) ?? Array.Empty<Body>();

    private IReadOnlyList<Body> BuildBodies(DesktopScreen screen, IReadOnlyList<Body> hostBodies)
    {
        var scene = Scene(screen.Id);
        var taskbar = IsBottomTaskbar(hostBodies, screen);
        var bodies = new List<Body>(scene.Props.Count * 3);
        foreach (var item in scene.Props)
        {
            var piece = catalog.Find(item.AssetId);
            if (piece is null) continue;
            var scale = PixelScale * Math.Clamp(item.Scale, .65, 1.6);
            var height = (float)(piece.Height * scale);
            var x = (float)(Math.Clamp(item.X, 0, 1) * DipWidth(screen) - piece.Width * scale / 2);
            var y = item.Support == DecorationSupport.TaskbarTop && taskbar is { } bar
                ? (float)bar.Top
                : (float)DipHeight(screen);
            var bands = catalog.ColliderBands(item.AssetId);
            for (var index = 0; index < bands.Count; index++)
            {
                var band = bands[index];
                var bodyId = StableBodyId(item.Id, index);
                bodies.Add(new Body(bodyId,
                    new Vector2(x + band.X * (float)scale, y - height + band.Y * (float)scale),
                    new Vector2(Math.Max(8, band.Width * (float)scale), Math.Max(8, band.Height * (float)scale)), BodyKind.Decoration, 1));
            }
        }
        return bodies;
    }

    private void PublishBodies(DesktopScreen screen, IReadOnlyList<Body> bodies)
    {
        host?.SetDecorationBodies(screen, bodies);
    }

    private void RenderProps(DrawingContext drawing, DesktopScreen screen, IReadOnlyList<Body> hostBodies,
        IReadOnlyList<PlacedDecoration> props)
    {
        var taskbar = IsBottomTaskbar(hostBodies, screen);
        foreach (var item in props)
        {
            var piece = catalog.Find(item.AssetId);
            if (piece is null) continue;
            var scale = PixelScale * Math.Clamp(item.Scale, .65, 1.6);
            var size = new Size(piece.Width * scale, piece.Height * scale);
            var centerX = Math.Clamp(item.X, 0, 1) * DipWidth(screen);
            var top = item.Support == DecorationSupport.TaskbarTop && taskbar is { } bar
                ? bar.Top - size.Height
                : DipHeight(screen) - size.Height;
            drawing.DrawImage(catalog.Image(item.AssetId), new Rect(centerX - size.Width / 2, top, size.Width, size.Height));
        }
    }

    private LightRuntime GetLightRuntime(string screenId, IReadOnlyList<HangingLight> lights, DesktopScreen screen)
    {
        lock (gate)
        {
            if (!lightRuntimes.TryGetValue(screenId, out var runtime))
                lightRuntimes[screenId] = runtime = new LightRuntime();
            runtime.Configure(lights, screen);
            return runtime;
        }
    }

    private static void RenderLights(DrawingContext drawing, LightRuntime runtime)
    {
        var palettes = new Dictionary<LightPalette, Color[]>
        {
            [LightPalette.Classic] = [Color.FromRgb(255, 89, 105), Color.FromRgb(255, 215, 120), Color.FromRgb(103, 227, 172), Color.FromRgb(104, 183, 255), Color.FromRgb(222, 149, 255)],
            [LightPalette.WarmWhite] = [Color.FromRgb(255, 235, 194), Color.FromRgb(255, 215, 136), Color.FromRgb(255, 244, 223)],
            [LightPalette.Peppermint] = [Color.FromRgb(255, 83, 103), Color.FromRgb(255, 244, 220), Color.FromRgb(255, 131, 138)],
            [LightPalette.Frost] = [Color.FromRgb(128, 201, 255), Color.FromRgb(215, 246, 255), Color.FromRgb(158, 176, 255), Color.FromRgb(238, 247, 255)]
        };
        foreach (var line in runtime.Lines)
        {
            if (line.Points.Count < 2) continue;
            var geometry = new StreamGeometry();
            using (var path = geometry.Open())
            {
                path.BeginFigure(new Point(line.Points[0].X, line.Points[0].Y), false, false);
                path.PolyLineTo(line.Points.Skip(1).Select(point => new Point(point.X, point.Y)).ToArray(), true, false);
            }
            geometry.Freeze();
            drawing.DrawGeometry(null, new Pen(new SolidColorBrush(Color.FromRgb(36, 49, 66)), 2.5), geometry);
            var palette = palettes[line.Palette];
            for (var index = 0; index < line.Bulbs.Count; index++)
            {
                var point = line.Bulbs[index];
                var color = palette[index % palette.Length];
                var radius = 3.2;
                drawing.DrawEllipse(new SolidColorBrush(Color.FromArgb(40, color.R, color.G, color.B)), null, new Point(point.X, point.Y), radius * 2, radius * 2);
                drawing.DrawEllipse(new SolidColorBrush(color), null, new Point(point.X, point.Y + 2.0), radius * .7, radius * 1.1);
                drawing.DrawEllipse(new SolidColorBrush(Colors.White), null, new Point(point.X - 1, point.Y + 1), 0.8, 1.1);
            }
        }
    }

    private static Body? IsBottomTaskbar(IReadOnlyList<Body> bodies, DesktopScreen screen) =>
        bodies.Where(body => body.Kind == BodyKind.Taskbar && body.Left <= 1 && body.Right >= DipWidth(screen) - 1 && body.Top > DipHeight(screen) * .6)
            .OrderBy(body => body.Top).Select(body => (Body?)body).FirstOrDefault();

    internal static LightAnchor SnapAnchor(Point point, DesktopScreen screen, IReadOnlyList<Body> bodies)
    {
        var best = point;
        long? bodyId = null;
        AnchorEdge? bestEdge = null;
        var fraction = 0.0;
        var shortest = 30.0;
        foreach (var body in bodies)
        {
            foreach (var edge in Enum.GetValues<AnchorEdge>())
            {
                var candidate = SnapToEdge(point, body.Left, body.Top, body.Right, body.Bottom, edge, out var edgeFraction);
                var distance = (candidate - point).Length;
                if (distance < shortest) shortest = distance; else continue;
                best = candidate;
                bodyId = body.Id;
                bestEdge = edge;
                fraction = edgeFraction;
            }
        }
        foreach (var edge in new[] { AnchorEdge.Top, AnchorEdge.Left, AnchorEdge.Right })
        {
            var candidate = SnapToEdge(point, 0, 0, DipWidth(screen), DipHeight(screen), edge, out var edgeFraction);
            var distance = (candidate - point).Length;
            if (distance < shortest) { shortest = distance; best = candidate; bodyId = null; bestEdge = edge; fraction = edgeFraction; }
        }
        return new LightAnchor(best.X / Math.Max(1, DipWidth(screen)), best.Y / Math.Max(1, DipHeight(screen)),
            bodyId, bestEdge, fraction);
    }

    internal static double DipWidth(DesktopScreen screen) => screen.Width / Math.Max(.25, screen.Scale);
    internal static double DipHeight(DesktopScreen screen) => screen.Height / Math.Max(.25, screen.Scale);

    private static Point SnapToEdge(Point point, double left, double top, double right, double bottom,
        AnchorEdge edge, out double fraction)
    {
        if (edge is AnchorEdge.Top or AnchorEdge.Bottom)
        {
            fraction = Math.Clamp((point.X - left) / Math.Max(1, right - left), 0, 1);
            return new Point(left + fraction * (right - left), edge == AnchorEdge.Top ? top : bottom);
        }
        fraction = Math.Clamp((point.Y - top) / Math.Max(1, bottom - top), 0, 1);
        return new Point(edge == AnchorEdge.Left ? left : right, top + fraction * (bottom - top));
    }

    private void EnsureLoaded()
    {
        lock (gate)
        {
            if (loaded) return;
            loaded = true;
            try
            {
                var path = Path.Combine(dataDirectory, "scenes.json");
                var directoryInfo = new DirectoryInfo(dataDirectory);
                if (!directoryInfo.Exists || directoryInfo.Attributes.HasFlag(FileAttributes.ReparsePoint)) return;
                var info = new FileInfo(path);
                if (!info.Exists || info.Length is < 2 or > DecorationJson.MaximumBytes) return;
                if (info.Attributes.HasFlag(FileAttributes.ReparsePoint)) return;
                var json = File.ReadAllBytes(path);
                var doc = JsonSerializer.Deserialize<DecorationDocument>(json, DecorationJson.Options);
                if (doc?.Version != 1 || doc.Scenes is null || doc.Scenes.Count > 32) return;
                includeDesktopIcons = doc.IncludeDesktopIcons;
                foreach (var (screenId, scene) in doc.Scenes)
                    if (screenId is { Length: > 0 and <= 128 } && scene is not null)
                    {
                        var bounded = scene.Bounded(catalog.Ids);
                        // Shell window handles can be recycled after restart. Keep their saved position,
                        // but resolve them as free endpoints until the user attaches them again.
                        bounded = bounded with
                        {
                            Lights = bounded.Lights.Select(light => light with
                            {
                                Anchors = light.Anchors.Select(anchor => anchor.BodyId is null or < 0
                                    ? anchor : anchor with { BodyId = null, Edge = null }).ToList()
                            }).ToList()
                        };
                        scenes[screenId] = bounded;
                    }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException or NotSupportedException)
            {
                // Keep a malformed or inaccessible old scene from preventing Snowy from starting.
            }
        }
    }

    private void Persist()
    {
        try
        {
            Directory.CreateDirectory(dataDirectory);
            var directoryInfo = new DirectoryInfo(dataDirectory);
            if (directoryInfo.Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new IOException("The Snowy scenes folder cannot be a link.");
            var path = Path.Combine(dataDirectory, "scenes.json");
            var existing = new FileInfo(path);
            if (existing.Exists && existing.Attributes.HasFlag(FileAttributes.ReparsePoint))
                throw new IOException("The Snowy scene file cannot be a link.");
            var bytes = JsonSerializer.SerializeToUtf8Bytes(new DecorationDocument(1, scenes, includeDesktopIcons), DecorationJson.Options);
            if (bytes.Length > DecorationJson.MaximumBytes) throw new InvalidDataException("The decoration scene file exceeded its size limit.");
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            try
            {
                using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                           8192, FileOptions.WriteThrough))
                {
                    stream.Write(bytes);
                    stream.Flush(true);
                }
                File.Move(temp, path, true);
            }
            finally { try { File.Delete(temp); } catch (IOException) { } }
        }
        catch (IOException) { throw; }
        catch (UnauthorizedAccessException) { throw; }
    }

    private static long StableBodyId(Guid id, int band)
    {
        Span<byte> bytes = stackalloc byte[20];
        id.TryWriteBytes(bytes);
        BitConverter.TryWriteBytes(bytes[16..], band);
        var hash = SHA256.HashData(bytes);
        var value = BitConverter.ToInt64(hash, 0) & long.MaxValue;
        return value == 0 ? 1 : value;
    }

    private sealed class LightRuntime
    {
        private readonly Dictionary<Guid, RuntimeLine> lines = [];
        public IReadOnlyList<RuntimeLine> Lines => lines.Values.ToList();

        public void Configure(IReadOnlyList<HangingLight> strings, DesktopScreen screen)
        {
            var wanted = strings.Select(light => light.Id).ToHashSet();
            foreach (var id in lines.Keys.Where(id => !wanted.Contains(id)).ToArray()) lines.Remove(id);
            foreach (var light in strings)
            {
                if (!lines.TryGetValue(light.Id, out var line) || line.Model != light)
                    lines[light.Id] = line = new RuntimeLine(light, screen);
                line.Screen = screen;
            }
        }

        public IReadOnlyList<HangingLight> Advance(IReadOnlyList<HangingLight> strings, DesktopScreen screen, IReadOnlyList<Body> bodies,
            Vector2 wind, Vector2? pointer, float elapsed, bool reducedMotion)
        {
            var detached = new List<HangingLight>();
            foreach (var light in strings)
            {
                if (!lines.TryGetValue(light.Id, out var line)) continue;
                if (line.Step(screen, bodies, wind, pointer, elapsed, reducedMotion)) detached.Add(line.Model);
            }
            return detached;
        }
    }

    private sealed class RuntimeLine
    {
        private const float Gravity = 140;
        public HangingLight Model { get; private set; }
        public List<Vector2> Points { get; }
        public List<Vector2> Previous { get; }
        public List<Vector2> Bulbs { get; } = [];
        public LightPalette Palette => Model.Palette;
        public DesktopScreen Screen { get; set; }
        private readonly List<int> Pins = [];
        private readonly List<bool> Held = [];
        private readonly List<float> LinkLengths = [];

        public RuntimeLine(HangingLight model, DesktopScreen screen)
        {
            Model = model;
            Screen = screen;
            Points = BuildPoints(model, screen);
            Previous = Points.ToList();
            Pins.Add(0);
            Held.Add(IsAttached(model.Anchors[0]));
            var node = 0;
            for (var span = 0; span < model.Anchors.Count - 1; span++)
            {
                var start = ResolveAnchor(model.Anchors[span], screen, []);
                var end = ResolveAnchor(model.Anchors[span + 1], screen, []);
                var count = Math.Max(6, Math.Min(24, (int)(Vector2.Distance(ToVector(start), ToVector(end)) / 24) + 1));
                node += count - 1;
                Pins.Add(node);
                Held.Add(IsAttached(model.Anchors[span + 1]));
            }
            for (var index = 1; index < Points.Count; index++)
                LinkLengths.Add(Vector2.Distance(Points[index - 1], Points[index]));
            RebuildBulbs();
        }

        public bool Step(DesktopScreen screen, IReadOnlyList<Body> bodies, Vector2 wind, Vector2? cursor,
            float elapsed, bool reducedMotion)
        {
            Screen = screen;
            if (Points.Count < 2) return false;
            var dt = Math.Clamp(float.IsFinite(elapsed) ? elapsed : 1f / 30, 1f / 120, 1f / 24);
            var anchors = Model.Anchors.Select(anchor => ToVector(ResolveAnchor(anchor, screen, bodies))).ToArray();
            var changed = false;
            for (var index = 0; index < Model.Anchors.Count && index < Pins.Count; index++)
            {
                var anchor = Model.Anchors[index];
                if (anchor.BodyId is { } targetId && !bodies.Any(body => body.Id == targetId))
                {
                    var oldPosition = Points[Pins[index]];
                    Model = ReplaceAnchor(Model, index, FreeAnchor(oldPosition, screen));
                    Held[index] = false;
                    changed = true;
                }
            }
            for (var index = 0; index + 1 < Pins.Count && index + 1 < anchors.Length; index++)
            {
                var from = Pins[index];
                var to = Pins[index + 1];
                if (!Held[index] || !Held[index + 1]) continue;
                var reach = 0f;
                for (var link = from; link < to && link < LinkLengths.Count; link++) reach += LinkLengths[link];
                var distance = Vector2.Distance(anchors[index], anchors[index + 1]);
                if (distance <= reach * 1.22f + 9) continue;
                var movable = new[] { index, index + 1 }.Where(joint =>
                    Model.Anchors[joint].BodyId is not null &&
                    Vector2.Distance(anchors[joint], Points[Pins[joint]]) > .25f).ToArray();
                if (movable.Length == 0) continue;
                var detach = movable.MaxBy(joint => Vector2.DistanceSquared(anchors[joint], Points[Pins[joint]]));
                Model = ReplaceAnchor(Model, detach, FreeAnchor(Points[Pins[detach]], screen));
                Held[detach] = false;
                changed = true;
            }
            for (var i = 0; i < Pins.Count && i < anchors.Length; i++)
            {
                var pin = Pins[i];
                if (Held[i] && pin < Points.Count) { Points[pin] = anchors[i]; Previous[pin] = anchors[i]; }
            }
            for (var i = 0; i < Points.Count; i++)
            {
                if (IsPinned(i)) continue;
                var current = Points[i];
                var velocity = (current - Previous[i]) * .985f;
                Previous[i] = current;
                if (!reducedMotion)
                {
                    var gust = wind * (48 + 24 * MathF.Sin((float)(Environment.TickCount64 / 600.0) + i * .4f));
                    Points[i] = current + velocity + (new Vector2(0, Gravity) + gust) * dt * dt;
                    if (cursor is { } mouse && Vector2.DistanceSquared(mouse, current) < 26 * 26)
                        Points[i] += Vector2.Normalize(current - mouse + new Vector2(.001f, 0)) * (10 * dt);
                }
                else Points[i] = current - velocity * .08f;
            }
            for (var pass = 0; pass < 4; pass++)
            {
                for (var i = 0; i < LinkLengths.Count && i + 1 < Points.Count; i++)
                {
                    var delta = Points[i + 1] - Points[i];
                    var distance = MathF.Max(.001f, delta.Length());
                    var correction = delta * ((distance - LinkLengths[i]) / distance * .5f);
                    if (!IsPinned(i)) Points[i] += correction;
                    if (!IsPinned(i + 1)) Points[i + 1] -= correction;
                }
            }
            RebuildBulbs();
            return changed;
        }

        private bool IsPinned(int node)
        {
            for (var index = 0; index < Pins.Count; index++)
                if (Held[index] && Pins[index] == node) return true;
            return false;
        }

        private static bool IsAttached(LightAnchor anchor) => anchor.BodyId is not null || anchor.Edge is not null;

        private static HangingLight ReplaceAnchor(HangingLight light, int index, LightAnchor anchor)
        {
            var anchors = light.Anchors.ToList();
            anchors[index] = anchor;
            return light with { Anchors = anchors };
        }

        private static LightAnchor FreeAnchor(Vector2 point, DesktopScreen screen) =>
            new(Math.Clamp(point.X / Math.Max(1, (float)DipWidth(screen)), 0, 1),
                Math.Clamp(point.Y / Math.Max(1, (float)DipHeight(screen)), 0, 1));

        private void RebuildBulbs()
        {
            Bulbs.Clear();
            var length = 0f;
            for (var i = 1; i < Points.Count; i++) length += Vector2.Distance(Points[i - 1], Points[i]);
            var spacing = MathF.Max(15, length / 95);
            var distanceAlong = spacing * .5f;
            var traveled = 0f;
            for (var i = 1; i < Points.Count && Bulbs.Count < 120; i++)
            {
                var segment = Vector2.Distance(Points[i - 1], Points[i]);
                while (distanceAlong <= traveled + segment && Bulbs.Count < 120)
                {
                    var fraction = (distanceAlong - traveled) / MathF.Max(.001f, segment);
                    Bulbs.Add(Vector2.Lerp(Points[i - 1], Points[i], fraction));
                    distanceAlong += spacing;
                }
                traveled += segment;
            }
        }

        private static List<Vector2> BuildPoints(HangingLight model, DesktopScreen screen)
        {
            var points = new List<Vector2>();
            for (var span = 0; span < model.Anchors.Count - 1; span++)
            {
                var start = ToVector(ResolveAnchor(model.Anchors[span], screen, []));
                var end = ToVector(ResolveAnchor(model.Anchors[span + 1], screen, []));
                var count = Math.Clamp((int)(Vector2.Distance(start, end) / 24) + 1, 6, 24);
                var sag = Vector2.Distance(start, end) * (float)Math.Clamp(model.Slack, .04, .65) * .65f;
                for (var index = span == 0 ? 0 : 1; index < count; index++)
                {
                    var t = (float)index / (count - 1);
                    points.Add(Vector2.Lerp(start, end, t) + new Vector2(0, 4 * t * (1 - t) * sag));
                }
            }
            return points;
        }
    }

    internal static Point ResolveAnchor(LightAnchor anchor, DesktopScreen screen, IReadOnlyList<Body> bodies)
    {
        if (anchor.BodyId is { } id && anchor.Edge is { } edge)
        {
            var body = bodies.FirstOrDefault(item => item.Id == id);
            if (body.IsValid)
                return edge switch
                {
                    AnchorEdge.Top => new Point(body.Left + body.Size.X * anchor.Fraction, body.Top),
                    AnchorEdge.Right => new Point(body.Right, body.Top + body.Size.Y * anchor.Fraction),
                    AnchorEdge.Bottom => new Point(body.Left + body.Size.X * anchor.Fraction, body.Bottom),
                    _ => new Point(body.Left, body.Top + body.Size.Y * anchor.Fraction)
                };
        }
        return new Point(anchor.X * DipWidth(screen), anchor.Y * DipHeight(screen));
    }

    private static Vector2 ToVector(Point point) => new((float)point.X, (float)point.Y);
}
