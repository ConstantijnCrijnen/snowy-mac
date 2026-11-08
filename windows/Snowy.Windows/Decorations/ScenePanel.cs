using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Decorations;

/// <summary>Desktop personalization page exposed inside the main Snowy window.</summary>
public sealed class ScenePanel : UserControl
{
    private readonly DecorationService decorations;
    private readonly DesktopHost desktop;
    private readonly ComboBox displays = new() { MinWidth = 170 };
    private readonly TextBlock message = new() { VerticalAlignment = VerticalAlignment.Center, Foreground = SystemColors.GrayTextBrush };

    public ScenePanel(DecorationService decorations, DesktopHost desktop)
    {
        this.decorations = decorations;
        this.desktop = desktop;
        decorations.Attach(desktop);
        Margin = new Thickness(24);

        var stack = new StackPanel();
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 16) };
        header.Children.Add(Text("Decorations", 26, true));
        DockPanel.SetDock(header.Children[0], Dock.Left);
        displays.ItemsSource = desktop.Screens.Select(screen => new ScreenOption(screen.Id, screen.Name)).ToList();
        displays.DisplayMemberPath = nameof(ScreenOption.Name);
        displays.SelectedIndex = 0;
        DockPanel.SetDock(displays, Dock.Right);
        header.Children.Add(displays);
        stack.Children.Add(header);
        stack.Children.Add(Text("Choose a winter scene, then make it your own with props and hanging lights.", 14));

        var grid = new UniformGrid { Columns = 2, Margin = new Thickness(0, 16, 0, 14) };
        foreach (var (id, title, description) in DecorationPresets.All)
        {
            var button = new Button
            {
                Content = Card(title, description),
                Tag = id,
                Padding = new Thickness(14),
                Margin = new Thickness(0, 0, 10, 10),
                HorizontalContentAlignment = HorizontalAlignment.Left,
                VerticalContentAlignment = VerticalAlignment.Center
            };
            button.Click += (_, _) =>
            {
                if (SelectedScreen() is { } screen)
                {
                    try
                    {
                        decorations.SelectPreset(screen.Id, id, screen);
                        message.Text = id == DecorationPreset.None ? "Just snow." : $"{title} scene applied.";
                    }
                    catch (Exception error) when (error is IOException or UnauthorizedAccessException) { message.Text = "The scene could not be saved. Check the Snowy folder under AppData."; }
                }
            };
            grid.Children.Add(button);
        }
        stack.Children.Add(grid);

        var actions = new WrapPanel { Margin = new Thickness(0, 2, 0, 12) };
        actions.Children.Add(Button("Customize Scene…", (_, _) => decorations.OpenEditor(desktop), true));
        actions.Children.Add(Button("Clear Scene", (_, _) =>
        {
            if (SelectedScreen() is { } screen)
            {
                try { decorations.Clear(screen.Id); message.Text = "The scene is clear."; }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException) { message.Text = "The scene could not be saved. Check the Snowy folder under AppData."; }
            }
        }));
        stack.Children.Add(actions);
        stack.Children.Add(message);

        Content = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private DesktopScreen? SelectedScreen()
    {
        if (displays.SelectedItem is ScreenOption option)
            return desktop.Screens.FirstOrDefault(screen => screen.Id == option.Id);
        return desktop.Screens.FirstOrDefault();
    }

    private static Border Card(string name, string detail)
    {
        var content = new StackPanel();
        content.Children.Add(Text(name, 16, true));
        content.Children.Add(Text(detail, 12));
        return new Border { Child = content };
    }

    private static TextBlock Text(string text, double size = 14, bool bold = false) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(0, 0, 8, 6)
    };

    private static Button Button(string title, RoutedEventHandler action, bool primary = false)
    {
        var button = new Button { Content = title, Padding = new Thickness(13, 7, 13, 7), Margin = new Thickness(0, 0, 9, 0) };
        button.Click += action;
        return button;
    }

    private sealed record ScreenOption(string Id, string Name);
}

internal sealed class SceneEditorWindow : Window
{
    public SceneEditorWindow(DecorationService service, DesktopHost host, DecorationCatalog catalog)
    {
        Title = "Snowy Scene Editor";
        Width = 1100;
        Height = 760;
        MinWidth = 840;
        MinHeight = 600;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Content = new SceneEditor(service, host, catalog);
    }
}

internal sealed class SceneEditor : UserControl
{
    private readonly DecorationService service;
    private readonly DesktopHost host;
    private readonly DecorationCatalog catalog;
    private readonly ComboBox displays = new() { MinWidth = 160 };
    private readonly Canvas canvas = new() { ClipToBounds = true, AllowDrop = true, Background = new SolidColorBrush(Color.FromRgb(22, 38, 60)) };
    private readonly StackPanel inspector = new();
    private readonly TextBlock status = new() { Foreground = SystemColors.GrayTextBrush, VerticalAlignment = VerticalAlignment.Center };
    private Image? dragGhost;
    private DecorationScene scene = DecorationScene.Empty;
    private Guid? selectedProp;
    private Guid? selectedLight;
    private int selectedAnchor;
    private bool draggingSelection;
    private Point? libraryPointerStart;
    private string? suppressClickForAsset;
    private double propGrabOffsetX;
    private double canvasScale = 1;

    private DesktopScreen? Screen => displays.SelectedItem is ScreenOption option
        ? host.Screens.FirstOrDefault(screen => screen.Id == option.Id)
        : host.Screens.FirstOrDefault();

    public SceneEditor(DecorationService service, DesktopHost host, DecorationCatalog catalog)
    {
        this.service = service;
        this.host = host;
        this.catalog = catalog;
        var root = new DockPanel();
        var header = new DockPanel { Margin = new Thickness(18, 14, 18, 10) };
        var heading = Text("Desktop Layout", 21, true);
        DockPanel.SetDock(heading, Dock.Left);
        header.Children.Add(heading);
        displays.ItemsSource = host.Screens.Select(screen => new ScreenOption(screen.Id, screen.Name)).ToList();
        displays.DisplayMemberPath = nameof(ScreenOption.Name);
        displays.SelectedIndex = 0;
        displays.SelectionChanged += (_, _) => LoadScene();
        DockPanel.SetDock(displays, Dock.Right);
        header.Children.Add(displays);
        var iconAnchors = new CheckBox
        {
            Content = "Snap lights to desktop icons",
            IsChecked = service.IncludeDesktopIcons,
            ToolTip = "Reads icon names and visible bounds through Windows Accessibility, only after you enable this option.",
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 14, 4)
        };
        iconAnchors.Checked += (_, _) => ToggleIconAnchors(iconAnchors, true);
        iconAnchors.Unchecked += (_, _) => ToggleIconAnchors(iconAnchors, false);
        DockPanel.SetDock(iconAnchors, Dock.Right);
        header.Children.Add(iconAnchors);
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);

        var footer = new DockPanel { Margin = new Thickness(18, 10, 18, 14) };
        status.Text = "Drag a decoration card onto the desktop. Drag a light joint to snap it to an edge.";
        DockPanel.SetDock(status, Dock.Left);
        footer.Children.Add(status);
        var save = new Button { Content = "Apply Scene", Padding = new Thickness(14, 7, 14, 7), HorizontalAlignment = HorizontalAlignment.Right };
        save.Click += (_, _) => SaveScene();
        DockPanel.SetDock(save, Dock.Right);
        footer.Children.Add(save);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);

        var library = BuildLibrary();
        library.Width = 236;
        library.Margin = new Thickness(10, 4, 0, 4);
        DockPanel.SetDock(library, Dock.Left);
        root.Children.Add(library);

        var properties = new ScrollViewer { Width = 235, Content = inspector, Margin = new Thickness(0, 4, 14, 4) };
        DockPanel.SetDock(properties, Dock.Right);
        root.Children.Add(properties);

        canvas.AllowDrop = true;
        canvas.DragEnter += UpdateDragGhost;
        canvas.DragOver += UpdateDragGhost;
        canvas.DragLeave += (_, _) => RemoveDragGhost();
        canvas.Drop += DropOnCanvas;
        canvas.SizeChanged += (_, _) => { FitCanvas(); DrawScene(); };
        canvas.PreviewMouseMove += MoveSelected;
        canvas.MouseLeftButtonUp += (_, _) =>
        {
            draggingSelection = false;
            canvas.ReleaseMouseCapture();
        };
        canvas.LostMouseCapture += (_, _) => draggingSelection = false;
        canvas.MouseLeftButtonDown += (_, e) =>
        {
            if (e.OriginalSource == canvas) { selectedProp = null; selectedLight = null; UpdateInspector(); }
        };
        root.Children.Add(new Border { BorderBrush = SystemColors.ControlDarkBrush, BorderThickness = new Thickness(1), Margin = new Thickness(8, 4, 8, 4), Child = canvas });
        Content = root;
        LoadScene();
    }

    private ScrollViewer BuildLibrary()
    {
        var stack = new StackPanel();
        stack.Children.Add(Text("Decoration Library", 16, true));
        var lights = new Button { Content = "✦  String Lights", Padding = new Thickness(8), Margin = new Thickness(0, 4, 0, 8) };
        lights.Click += (_, _) => AddLights();
        stack.Children.Add(lights);
        var grid = new UniformGrid { Columns = 2 };
        foreach (var piece in catalog.Pieces)
        {
            var panel = new StackPanel();
            var image = new Image { Source = catalog.Image(piece.Id), Width = 70, Height = 58, Stretch = Stretch.Uniform, SnapsToDevicePixels = true };
            RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
            panel.Children.Add(new Border
            {
                Height = 76,
                Child = image,
                Background = new SolidColorBrush(Color.FromRgb(39, 61, 88)),
                CornerRadius = new CornerRadius(5)
            });
            panel.Children.Add(new TextBlock { Text = piece.Id, FontSize = 10, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, Margin = new Thickness(2, 4, 2, 3), MinHeight = 28 });
            var card = new Button { Content = panel, Padding = new Thickness(4), Margin = new Thickness(3), Tag = piece.Id, ToolTip = "Drag onto the desktop" };
            card.PreviewMouseLeftButtonDown += (_, e) =>
            {
                suppressClickForAsset = null;
                libraryPointerStart = e.GetPosition(null);
            };
            card.PreviewMouseLeftButtonUp += (_, _) => libraryPointerStart = null;
            card.PreviewKeyDown += (_, _) => suppressClickForAsset = null;
            card.PreviewMouseMove += BeginLibraryDrag;
            card.Click += (_, _) =>
            {
                if (suppressClickForAsset == piece.Id)
                {
                    suppressClickForAsset = null;
                    return;
                }
                if (Screen is { } screen)
                    AddProp(piece.Id, new Point(DipWidth(screen) / 2, DipHeight(screen)), DecorationSupport.DesktopEdge);
            };
            grid.Children.Add(card);
        }
        stack.Children.Add(grid);
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private void BeginLibraryDrag(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (sender is not Button { Tag: string id } button || e.LeftButton != System.Windows.Input.MouseButtonState.Pressed ||
            libraryPointerStart is not { } start) return;
        if (scene.Props.Count >= DecorationScene.MaxProps)
        {
            status.Text = "A scene can hold up to 16 decorations.";
            libraryPointerStart = null;
            return;
        }
        var current = e.GetPosition(null);
        if (Math.Abs(current.X - start.X) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(current.Y - start.Y) < SystemParameters.MinimumVerticalDragDistance) return;

        libraryPointerStart = null;
        var data = new DataObject("Snowy.DecorationAsset", id);
        DragDrop.DoDragDrop(button, data, DragDropEffects.Copy);
    }

    private void DropOnCanvas(object sender, DragEventArgs e)
    {
        RemoveDragGhost();
        if (e.Data.GetData("Snowy.DecorationAsset") is not string id || Screen is not { } screen || catalog.Find(id) is not { })
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        if (!CanvasPointToDesktop(e.GetPosition(canvas), screen, out var point))
        {
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        AddProp(id, point);
        suppressClickForAsset = id;
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
    }

    private void UpdateDragGhost(object sender, DragEventArgs e)
    {
        if (e.Data.GetData("Snowy.DecorationAsset") is not string id || catalog.Find(id) is not { } piece ||
            scene.Props.Count >= DecorationScene.MaxProps)
        {
            RemoveDragGhost();
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            if (scene.Props.Count >= DecorationScene.MaxProps) status.Text = "A scene can hold up to 16 decorations.";
            return;
        }
        if (Screen is not { } screen || !CanvasPointToDesktop(e.GetPosition(canvas), screen, out var point))
        {
            RemoveDragGhost();
            e.Effects = DragDropEffects.None;
            e.Handled = true;
            return;
        }
        e.Effects = DragDropEffects.Copy;
        e.Handled = true;
        if (dragGhost is null)
        {
            dragGhost = new Image { Source = catalog.Image(id), Opacity = .58, IsHitTestVisible = false,
                Width = piece.Width * DecorationPlacement.PixelScale(screen) * canvasScale,
                Height = piece.Height * DecorationPlacement.PixelScale(screen) * canvasScale };
            RenderOptions.SetBitmapScalingMode(dragGhost, BitmapScalingMode.NearestNeighbor);
            canvas.Children.Add(dragGhost);
        }
        var support = DecorationPlacement.SupportAt(point, screen, HostBodies());
        var placement = new PlacedDecoration(Guid.Empty, id, point.X / Math.Max(1, DipWidth(screen)), Support: support);
        var frame = DecorationPlacement.Frame(placement, piece, screen, HostBodies());
        var origin = CanvasOrigin(screen);
        dragGhost.Width = frame.Width * canvasScale;
        dragGhost.Height = frame.Height * canvasScale;
        Canvas.SetLeft(dragGhost, origin.X + frame.Left * canvasScale);
        Canvas.SetTop(dragGhost, origin.Y + frame.Top * canvasScale);
    }

    private bool CanvasPointToDesktop(Point point, DesktopScreen screen, out Point desktopPoint)
    {
        var origin = CanvasOrigin(screen);
        var x = (point.X - origin.X) / canvasScale;
        var y = (point.Y - origin.Y) / canvasScale;
        var width = DipWidth(screen);
        var height = DipHeight(screen);
        desktopPoint = new Point(Math.Clamp(x, 0, width), Math.Clamp(y, 0, height));
        return x >= 0 && x <= width && y >= 0 && y <= height;
    }

    private Point CanvasOrigin(DesktopScreen screen) => new(
        Math.Max(10, (canvas.ActualWidth - DipWidth(screen) * canvasScale) / 2),
        Math.Max(10, (canvas.ActualHeight - DipHeight(screen) * canvasScale) / 2));

    private void RemoveDragGhost()
    {
        if (dragGhost is null) return;
        canvas.Children.Remove(dragGhost);
        dragGhost = null;
    }

    private void LoadScene()
    {
        if (Screen is not { } screen) return;
        scene = service.Scene(screen.Id);
        selectedProp = null;
        selectedLight = null;
        FitCanvas();
        DrawScene();
        UpdateInspector();
    }

    private void SaveScene()
    {
        if (Screen is not { } screen) return;
        try
        {
            service.Save(screen.Id, scene);
            status.Text = "Scene saved to this Windows account.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { status.Text = "The scene could not be saved. Check the Snowy folder under AppData."; }
    }

    private void ToggleIconAnchors(CheckBox checkbox, bool enabled)
    {
        if (service.IncludeDesktopIcons == enabled) return;
        try
        {
            service.SetDesktopIconAnchors(enabled);
            status.Text = enabled ? "Shortcut edges are available as light anchors." : "Shortcut anchors are hidden.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            checkbox.IsChecked = service.IncludeDesktopIcons;
            status.Text = "The setting could not be saved. Check the Snowy folder under AppData.";
        }
        DrawScene();
    }

    private void AddProp(string id, Point point, DecorationSupport? supportOverride = null)
    {
        if (scene.Props.Count >= DecorationScene.MaxProps) { status.Text = "A scene can hold up to 16 decorations."; return; }
        if (Screen is not { } screen || catalog.Find(id) is not { } piece) return;
        var bodies = HostBodies();
        var support = supportOverride ?? DecorationPlacement.SupportAt(point, screen, bodies);
        var item = new PlacedDecoration(Guid.NewGuid(), id, DecorationPlacement.NormalizeCenter(point.X, support, piece, 1, screen, bodies),
            Pushes: piece.PushesByDefault, Support: support);
        scene = scene with { Props = [.. scene.Props, item] };
        selectedProp = item.Id;
        selectedLight = null;
        DrawScene();
        UpdateInspector();
    }

    private void AddLights()
    {
        if (scene.Lights.Count >= DecorationScene.MaxLights || Screen is not { } screen) return;
        var width = DipWidth(screen);
        var height = DipHeight(screen);
        var center = width * .5;
        var radius = Math.Min(width * .25, 250);
        var candidates = new[] { new Point(center - radius, 60), new Point(center, Math.Min(160, height * .35)), new Point(center + radius, 60) };
        var anchors = candidates.Select(point => DecorationService.SnapAnchor(point, screen, HostBodies())).ToList();
        var lights = new HangingLight(Guid.NewGuid(), anchors);
        scene = scene with { Lights = [.. scene.Lights, lights] };
        selectedLight = lights.Id;
        selectedProp = null;
        selectedAnchor = 1;
        DrawScene();
        UpdateInspector();
    }

    private void FitCanvas()
    {
        if (Screen is not { } screen || canvas.ActualWidth <= 0 || canvas.ActualHeight <= 0) return;
        canvasScale = Math.Min((canvas.ActualWidth - 22) / DipWidth(screen), (canvas.ActualHeight - 22) / DipHeight(screen));
    }

    private void DrawScene()
    {
        if (canvas.ActualWidth < 10 || Screen is not { } screen) return;
        FitCanvas();
        RemoveDragGhost();
        canvas.Children.Clear();
        var width = DipWidth(screen);
        var height = DipHeight(screen);
        var origin = CanvasOrigin(screen);
        var originX = origin.X;
        var originY = origin.Y;
        canvas.Children.Add(new Border
        {
            Width = width * canvasScale,
            Height = height * canvasScale,
            Background = new LinearGradientBrush(Color.FromRgb(30, 59, 90), Color.FromRgb(65, 91, 119), 90),
            BorderBrush = new SolidColorBrush(Color.FromRgb(129, 155, 180)), BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(5),
            IsHitTestVisible = false
        });
        Canvas.SetLeft(canvas.Children[^1], originX);
        Canvas.SetTop(canvas.Children[^1], originY);
        foreach (var body in HostBodies())
        {
            if (body.Id < 0)
            {
                var outline = new Border { Width = body.Size.X * canvasScale, Height = body.Size.Y * canvasScale,
                    BorderBrush = new SolidColorBrush(Color.FromArgb(160, 181, 209, 238)), BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(2), Background = Brushes.Transparent, IsHitTestVisible = false,
                    ToolTip = "Desktop shortcut edge. The name and icon image stay inside Explorer." };
                canvas.Children.Add(outline);
                Canvas.SetLeft(outline, originX + body.Left * canvasScale);
                Canvas.SetTop(outline, originY + body.Top * canvasScale);
                continue;
            }
            var shade = body.Kind switch
            {
                Snowy.Core.BodyKind.Taskbar => Color.FromRgb(36, 42, 52),
                Snowy.Core.BodyKind.Search => Color.FromRgb(83, 91, 108),
                _ => Color.FromArgb(135, 40, 46, 55)
            };
            var block = new Border { Width = body.Size.X * canvasScale, Height = body.Size.Y * canvasScale,
                Background = new SolidColorBrush(shade), CornerRadius = new CornerRadius(body.CornerRadius * canvasScale), IsHitTestVisible = false };
            canvas.Children.Add(block);
            Canvas.SetLeft(block, originX + body.Left * canvasScale);
            Canvas.SetTop(block, originY + body.Top * canvasScale);
        }
        foreach (var light in scene.Lights) DrawLight(light, screen, originX, originY);
        foreach (var prop in scene.Props) DrawProp(prop, screen, originX, originY);
    }

    private void DrawProp(PlacedDecoration prop, DesktopScreen screen, double originX, double originY)
    {
        var piece = catalog.Find(prop.AssetId);
        if (piece is null) return;
        var frame = DecorationPlacement.Frame(prop, piece, screen, HostBodies());
        var image = new Image { Source = catalog.Image(prop.AssetId), Width = frame.Width * canvasScale, Height = frame.Height * canvasScale,
            Stretch = Stretch.Fill, SnapsToDevicePixels = true, Tag = prop.Id,
            ToolTip = prop.AssetId, Cursor = System.Windows.Input.Cursors.SizeAll };
        RenderOptions.SetBitmapScalingMode(image, BitmapScalingMode.NearestNeighbor);
        image.MouseLeftButtonDown += (_, e) =>
        {
            selectedProp = prop.Id;
            selectedLight = null;
            var point = CanvasPointToDesktop(e.GetPosition(canvas), screen, out var desktopPoint) ? desktopPoint : new Point(frame.CenterX, frame.Top);
            propGrabOffsetX = point.X - frame.CenterX;
            draggingSelection = canvas.CaptureMouse();
            UpdateInspector();
            e.Handled = true;
        };
        Canvas.SetLeft(image, originX + frame.Left * canvasScale);
        Canvas.SetTop(image, originY + frame.Top * canvasScale);
        canvas.Children.Add(image);
    }

    private void DrawLight(HangingLight light, DesktopScreen screen, double originX, double originY)
    {
        var positions = LightPolyline(light, screen);
        if (positions.Count >= 2)
        {
            var path = new System.Windows.Shapes.Polyline
            {
                Points = new PointCollection(positions.Select(point => new Point(originX + point.X * canvasScale, originY + point.Y * canvasScale))),
                Stroke = new SolidColorBrush(Color.FromRgb(28, 40, 55)), StrokeThickness = 2.2, IsHitTestVisible = false
            };
            canvas.Children.Add(path);
            for (var i = 2; i < positions.Count - 1; i += 3)
            {
                var point = positions[i];
                var color = PaletteColors(light.Palette)[i % PaletteColors(light.Palette).Length];
                var bulb = new System.Windows.Shapes.Ellipse { Width = 5 * canvasScale, Height = 6 * canvasScale,
                    Fill = new SolidColorBrush(color), IsHitTestVisible = false };
                Canvas.SetLeft(bulb, originX + point.X * canvasScale - bulb.Width / 2);
                Canvas.SetTop(bulb, originY + point.Y * canvasScale - bulb.Height / 2);
                canvas.Children.Add(bulb);
            }
        }
        for (var i = 0; i < light.Anchors.Count; i++)
        {
            var anchorIndex = i;
            var point = DecorationService.ResolveAnchor(light.Anchors[anchorIndex], screen, HostBodies());
            var handle = new System.Windows.Shapes.Ellipse
            {
                Width = 12, Height = 12, Fill = Brushes.White,
                Stroke = new SolidColorBrush(Color.FromRgb(50, 121, 193)), StrokeThickness = 2,
                Tag = (light.Id, i), Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = $"Light joint {i + 1}"
            };
            handle.MouseLeftButtonDown += (_, e) =>
            {
                selectedLight = light.Id;
                selectedProp = null;
                selectedAnchor = anchorIndex;
                draggingSelection = canvas.CaptureMouse();
                UpdateInspector();
                e.Handled = true;
            };
            Canvas.SetLeft(handle, originX + point.X * canvasScale - 6);
            Canvas.SetTop(handle, originY + point.Y * canvasScale - 6);
            Panel.SetZIndex(handle, 20);
            canvas.Children.Add(handle);
        }
    }

    private void MoveSelected(object sender, System.Windows.Input.MouseEventArgs e)
    {
        if (!draggingSelection || Screen is not { } screen ||
            (selectedProp is null && selectedLight is null)) return;
        if (!CanvasPointToDesktop(e.GetPosition(canvas), screen, out var point)) return;
        var width = DipWidth(screen);
        if (selectedProp is { } propId)
        {
            var oldProp = scene.Props.FirstOrDefault(item => item.Id == propId);
            if (oldProp is null || catalog.Find(oldProp.AssetId) is not { } piece) return;
            var targetPoint = new Point(Math.Clamp(point.X - propGrabOffsetX, 0, width), point.Y);
            var bodies = HostBodies();
            var support = DecorationPlacement.SupportAt(targetPoint, screen, bodies);
            var updatedProp = oldProp with
            {
                Support = support,
                X = DecorationPlacement.NormalizeCenter(Math.Clamp(targetPoint.X, 0, width), support, piece,
                    oldProp.Scale, screen, bodies)
            };
            var props = scene.Props.Select(item => item.Id == propId ? updatedProp : item).ToList();
            scene = scene with { Props = props };
            DrawScene();
            e.Handled = true;
        }
        else if (selectedLight is { } lightId)
        {
            var lights = scene.Lights.Select(item =>
            {
                if (item.Id != lightId || selectedAnchor >= item.Anchors.Count) return item;
                var anchors = item.Anchors.ToList();
                anchors[selectedAnchor] = DecorationService.SnapAnchor(point, screen, HostBodies());
                return item with { Anchors = anchors };
            }).ToList();
            scene = scene with { Lights = lights };
            DrawScene();
            e.Handled = true;
        }
    }

    private void UpdateInspector()
    {
        inspector.Children.Clear();
        inspector.Margin = new Thickness(10);
        inspector.Children.Add(Text("Selected Item", 16, true));
        if (selectedProp is { } propId && scene.Props.FirstOrDefault(item => item.Id == propId) is { } prop)
        {
            var piece = catalog.Find(prop.AssetId);
            inspector.Children.Add(Text(prop.AssetId, 14, true));
            inspector.Children.Add(Text("Size", 12));
            var scale = new Slider { Minimum = .65, Maximum = 1.6, Value = prop.Scale, TickFrequency = .05, IsSnapToTickEnabled = false };
            scale.ValueChanged += (_, _) => UpdateProp(propId, item => item with { Scale = scale.Value });
            inspector.Children.Add(scale);
            var push = new CheckBox { Content = "Push with cursor", IsChecked = prop.Pushes, Margin = new Thickness(0, 7, 0, 8) };
            push.Checked += (_, _) => UpdateProp(propId, item => item with { Pushes = true });
            push.Unchecked += (_, _) => UpdateProp(propId, item => item with { Pushes = false });
            inspector.Children.Add(push);
            var support = new ComboBox { ItemsSource = Enum.GetValues<DecorationSupport>(), SelectedItem = prop.Support, Margin = new Thickness(0, 4, 0, 9) };
            support.SelectionChanged += (_, _) => { if (support.SelectedItem is DecorationSupport selected) UpdateProp(propId, item => item with { Support = selected }); };
            inspector.Children.Add(Text("Resting surface", 12));
            inspector.Children.Add(support);
            inspector.Children.Add(ActionButton("Remove Decoration", () => RemoveProp(propId)));
        }
        else if (selectedLight is { } lightId && scene.Lights.FirstOrDefault(item => item.Id == lightId) is { } light)
        {
            inspector.Children.Add(Text("String Lights", 14, true));
            inspector.Children.Add(Text("Color palette", 12));
            var palette = new ComboBox { ItemsSource = Enum.GetValues<LightPalette>(), SelectedItem = light.Palette };
            palette.SelectionChanged += (_, _) =>
            {
                if (palette.SelectedItem is LightPalette selected)
                    scene = scene with { Lights = scene.Lights.Select(item => item.Id == lightId ? item with { Palette = selected } : item).ToList() };
                DrawScene();
            };
            inspector.Children.Add(palette);
            inspector.Children.Add(Text("Rope slack", 12));
            var slack = new Slider { Minimum = .04, Maximum = .65, Value = light.Slack, Margin = new Thickness(0, 4, 0, 8) };
            slack.ValueChanged += (_, _) =>
            {
                scene = scene with { Lights = scene.Lights.Select(item => item.Id == lightId ? item with { Slack = slack.Value } : item).ToList() };
                DrawScene();
            };
            inspector.Children.Add(slack);
            inspector.Children.Add(Text($"Joint {selectedAnchor + 1} of {light.Anchors.Count} · drag the white handles to edit", 11));
            var row = new WrapPanel();
            row.Children.Add(ActionButton("Add Joint", () => AddAnchor(lightId)));
            row.Children.Add(ActionButton("Remove Light", () => RemoveLight(lightId)));
            inspector.Children.Add(row);
        }
        else inspector.Children.Add(Text("Select a prop or string of lights to edit its properties.", 12));
    }

    private void AddAnchor(Guid lightId)
    {
        if (Screen is not { } screen) return;
        var light = scene.Lights.FirstOrDefault(item => item.Id == lightId);
        if (light is null || light.Anchors.Count >= DecorationScene.MaxAnchors) { status.Text = "Each string can have at most six joints."; return; }
        var before = light.Anchors[Math.Max(0, selectedAnchor)];
        var point = DecorationService.ResolveAnchor(before, screen, HostBodies());
        var next = DecorationService.SnapAnchor(new Point(point.X + 35, point.Y + 25), screen, HostBodies());
        scene = scene with { Lights = scene.Lights.Select(item => item.Id == lightId ? item with { Anchors = [.. item.Anchors, next] } : item).ToList() };
        selectedAnchor = light.Anchors.Count;
        DrawScene(); UpdateInspector();
    }

    private void RemoveProp(Guid id)
    {
        scene = scene with { Props = scene.Props.Where(item => item.Id != id).ToList() };
        selectedProp = null; DrawScene(); UpdateInspector();
    }

    private void RemoveLight(Guid id)
    {
        scene = scene with { Lights = scene.Lights.Where(item => item.Id != id).ToList() };
        selectedLight = null; DrawScene(); UpdateInspector();
    }

    private void UpdateProp(Guid id, Func<PlacedDecoration, PlacedDecoration> update)
    {
        if (Screen is not { } screen) return;
        var bodies = HostBodies();
        scene = scene with { Props = scene.Props.Select(item =>
        {
            if (item.Id != id) return item;
            var updated = update(item);
            if (catalog.Find(updated.AssetId) is { } piece)
                updated = updated with { X = DecorationPlacement.Frame(updated, piece, screen, bodies).CenterX / Math.Max(1, DipWidth(screen)) };
            return updated;
        }).ToList() };
        DrawScene();
    }

    private IReadOnlyList<Snowy.Core.Body> HostBodies()
    {
        if (Screen is not { } screen) return [];
        var bodies = service.GetAnchorBodies(screen, allowRefresh: true);
        var owner = Window.GetWindow(this);
        var editorHandle = owner is null ? IntPtr.Zero : new WindowInteropHelper(owner).Handle;
        return editorHandle == IntPtr.Zero ? bodies : bodies.Where(body => body.Id != editorHandle.ToInt64()).ToArray();
    }

    private IReadOnlyList<Point> LightPolyline(HangingLight light, DesktopScreen screen)
    {
        var result = new List<Point>();
        var bodies = HostBodies();
        var anchors = light.Anchors.Select(anchor => DecorationService.ResolveAnchor(anchor, screen, bodies)).ToArray();
        for (var i = 0; i + 1 < anchors.Length; i++)
        {
            var start = anchors[i];
            var end = anchors[i + 1];
            var count = Math.Clamp((int)((end - start).Length / 10) + 1, 8, 44);
            var sag = (end - start).Length * light.Slack * .65;
            for (var j = i == 0 ? 0 : 1; j < count; j++)
            {
                var t = (double)j / (count - 1);
                result.Add(new Point(start.X + (end.X - start.X) * t, start.Y + (end.Y - start.Y) * t + 4 * t * (1 - t) * sag));
            }
        }
        return result;
    }

    private static Color[] PaletteColors(LightPalette palette) => palette switch
    {
        LightPalette.WarmWhite => [Color.FromRgb(255, 235, 194), Color.FromRgb(255, 215, 136), Color.FromRgb(255, 244, 223)],
        LightPalette.Peppermint => [Color.FromRgb(255, 83, 103), Color.FromRgb(255, 244, 220), Color.FromRgb(255, 131, 138)],
        LightPalette.Frost => [Color.FromRgb(128, 201, 255), Color.FromRgb(215, 246, 255), Color.FromRgb(158, 176, 255), Color.FromRgb(238, 247, 255)],
        _ => [Color.FromRgb(255, 89, 105), Color.FromRgb(255, 215, 120), Color.FromRgb(103, 227, 172), Color.FromRgb(104, 183, 255), Color.FromRgb(222, 149, 255)]
    };

    private static double DipWidth(DesktopScreen screen) => DecorationService.DipWidth(screen);
    private static double DipHeight(DesktopScreen screen) => DecorationService.DipHeight(screen);

    private static Border Text(string text, double size = 14, bool bold = false)
    {
        var block = new TextBlock { Text = text, FontSize = size, FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 7, 7) };
        return new Border { Child = block };
    }

    private static Button ActionButton(string text, Action action)
    {
        var button = new Button { Content = text, Padding = new Thickness(9, 5, 9, 5), Margin = new Thickness(0, 0, 5, 5) };
        button.Click += (_, _) => action();
        return button;
    }

    private sealed record ScreenOption(string Id, string Name);
}
