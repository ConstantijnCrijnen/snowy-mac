using System.Numerics;

namespace Snowy.Core;

public enum BodyKind { Window, Taskbar, Search, Decoration }
public enum Snowfall { Light, Steady, Flurry }
public enum SnowTool { Glove, Shovel }

/// <summary>Desktop collision rectangle in monitor-local DIPs, with a rounded upper outline.</summary>
public readonly record struct Body(
    long Id,
    Vector2 Position,
    Vector2 Size,
    BodyKind Kind = BodyKind.Window,
    float CornerRadius = 8)
{
    public float Left => Position.X;
    public float Top => Position.Y;
    public float Right => Position.X + Size.X;
    public float Bottom => Position.Y + Size.Y;
    public bool IsValid => float.IsFinite(Left) && float.IsFinite(Top) &&
        float.IsFinite(Size.X) && float.IsFinite(Size.Y) &&
        Size.X >= 8 && Size.Y >= 8 && Size.X <= 32768 && Size.Y <= 32768 &&
        MathF.Abs(Left) < 32768 && MathF.Abs(Top) < 32768;

    public float SurfaceY(float x)
    {
        var radius = Math.Clamp(CornerRadius, 0, MathF.Min(Size.X, Size.Y) * 0.5f);
        var edge = MathF.Min(x - Left, Right - x);
        if (radius <= 0 || edge >= radius) return Top;
        var inset = radius - edge;
        return Top + radius - MathF.Sqrt(MathF.Max(0, radius * radius - inset * inset));
    }

    public bool Contains(Vector2 point, float padding = 0)
    {
        padding = MathF.Max(0, float.IsFinite(padding) ? padding : 0);
        if (point.X < Left - padding || point.X > Right + padding ||
            point.Y < Top - padding || point.Y > Bottom + padding) return false;
        var corner = Math.Clamp(CornerRadius, 0, MathF.Min(Size.X, Size.Y) * 0.5f);
        var radius = corner + padding;
        var cx = Math.Clamp(point.X, Left + corner, Right - corner);
        var cy = Math.Clamp(point.Y, Top + corner, Bottom - corner);
        var dx = point.X - cx;
        var dy = point.Y - cy;
        return dx * dx + dy * dy <= radius * radius;
    }
}

public readonly record struct Flake(Vector2 Position, float Radius, float Opacity);

/// <summary>A bounded uniform-grid sample of connected loose snow for contour rendering.</summary>
public readonly record struct SnowCell(Vector2 Center, Vector2 Size, float Fill);

/// <summary>Height samples are measured upward from the body's rounded top edge, in DIPs.</summary>
public sealed record SnowProfile(float X, float Y, float Spacing, float[] Heights)
{
    public long Id { get; init; }
    public float Width => Spacing * Math.Max(0, Heights.Length - 1);
}
