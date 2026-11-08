using System.Windows;
using Snowy.Core;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Decorations;

internal readonly record struct DecorationRail(double Left, double Right, double SurfaceY);
internal readonly record struct DecorationFrame(double Left, double Top, double Width, double Height)
{
    public double CenterX => Left + Width / 2;
}

/// <summary>Single placement model shared by new drops, saved scenes, physics, and rendering.</summary>
internal static class DecorationPlacement
{
    private const double TargetSourcePixelDensity = 3;

    public static double PixelScale(DesktopScreen screen, double decorationScale = 1)
    {
        var screenScale = ScreenScale(screen);
        var sourcePixels = Math.Clamp(Math.Round(TargetSourcePixelDensity * Math.Clamp(
            double.IsFinite(decorationScale) ? decorationScale : 1, .65, 1.6) * screenScale,
            MidpointRounding.AwayFromZero), 1, 16);
        return sourcePixels / screenScale;
    }

    public static Body? BottomTaskbar(IReadOnlyList<Body> bodies)
    {
        // DesktopHost publishes BodyKind.Taskbar only after applying the shared Win32
        // bottom-taskbar test; use that validated contract rather than re-guessing geometry.
        foreach (var body in bodies)
            if (body.Kind == BodyKind.Taskbar) return body;
        return null;
    }

    public static DecorationSupport SupportAt(Point point, DesktopScreen screen, IReadOnlyList<Body> bodies)
    {
        var taskbar = BottomTaskbar(bodies);
        var floorDistance = Math.Abs(DecorationService.DipHeight(screen) - point.Y);
        var nearFloor = floorDistance <= 24;
        if (taskbar is { } bar)
        {
            var bounds = new Rect(bar.Left, bar.Top, bar.Size.X, bar.Size.Y);
            bounds.Inflate(6, 24);
            if (bounds.Contains(point))
            {
                var taskbarTopDistance = Math.Abs(point.Y - bar.Top);
                return nearFloor && floorDistance <= taskbarTopDistance
                    ? DecorationSupport.DesktopEdge
                    : DecorationSupport.TaskbarTop;
            }
        }
        return DecorationSupport.DesktopEdge;
    }

    public static DecorationRail RailFor(DecorationSupport support, DesktopScreen screen,
        IReadOnlyList<Body> bodies)
    {
        if (support == DecorationSupport.TaskbarTop && BottomTaskbar(bodies) is { } bar)
            return new DecorationRail(bar.Left, bar.Right, bar.Top);
        return new DecorationRail(0, DecorationService.DipWidth(screen), DecorationService.DipHeight(screen));
    }

    public static DecorationFrame Frame(PlacedDecoration prop, DecorationPiece piece, DesktopScreen screen,
        IReadOnlyList<Body> bodies)
    {
        var rail = RailFor(prop.Support, screen, bodies);
        var screenScale = ScreenScale(screen);
        var pixelScale = PixelScale(screen, prop.Scale);
        var railWidth = Math.Max(0, rail.Right - rail.Left);
        pixelScale = Math.Min(pixelScale, railWidth / Math.Max(1, piece.Width));
        pixelScale = Math.Min(pixelScale, rail.SurfaceY / Math.Max(1, piece.SolidBottom));
        var wholePixels = Math.Floor(pixelScale * screenScale + 0.0001);
        if (wholePixels >= 1) pixelScale = wholePixels / screenScale;
        var width = piece.Width * pixelScale;
        var height = piece.Height * pixelScale;
        var requestedCenter = Math.Clamp(double.IsFinite(prop.X) ? prop.X : .5, 0, 1) * DecorationService.DipWidth(screen);
        var leftPixels = Math.Round((requestedCenter - width / 2) * screenScale, MidpointRounding.AwayFromZero);
        var minLeftPixels = Math.Ceiling(rail.Left * screenScale - .0001);
        var maxLeftPixels = Math.Floor((rail.Right - width) * screenScale + .0001);
        leftPixels = Math.Clamp(leftPixels, minLeftPixels, Math.Max(minLeftPixels, maxLeftPixels));
        var left = leftPixels / screenScale;
        var topPixels = Math.Round((rail.SurfaceY - piece.SolidBottom * pixelScale) * screenScale,
            MidpointRounding.AwayFromZero);
        var top = topPixels / screenScale;
        return new DecorationFrame(left, top, width, height);
    }

    public static double NormalizeCenter(double center, DecorationSupport support, DecorationPiece piece,
        double scale, DesktopScreen screen, IReadOnlyList<Body> bodies)
    {
        var temporary = new PlacedDecoration(Guid.Empty, piece.Id,
            center / Math.Max(1, DecorationService.DipWidth(screen)), scale, piece.PushesByDefault, support);
        return Frame(temporary, piece, screen, bodies).CenterX / Math.Max(1, DecorationService.DipWidth(screen));
    }

    private static double ScreenScale(DesktopScreen screen) =>
        float.IsFinite(screen.Scale) ? Math.Clamp(screen.Scale, .5, 8) : 1;

}
