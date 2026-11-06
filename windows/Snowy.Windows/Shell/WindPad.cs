using Vector2 = System.Numerics.Vector2;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Snowy.Windows.Shell;

internal sealed class WindPad : FrameworkElement
{
    private const double Radius = 84;
    private readonly Action<Vector2> change;
    private readonly Action commit;
    private readonly DispatcherTimer animation;
    private Vector2 current;
    private Vector shown;
    private Vector velocity;

    public WindPad(Vector2 wind, Action<Vector2> change, Action commit)
    {
        this.change = change;
        this.commit = commit;
        current = wind;
        shown = new Vector(wind.X, wind.Y);
        Width = Height = 196;
        Focusable = true;
        Cursor = Cursors.Cross;
        AutomationProperties.SetName(this, "Wind direction and strength. Use arrow keys to adjust, Home to clear.");
        animation = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(16) };
        animation.Tick += (_, _) => Animate();
        Unloaded += (_, _) =>
        {
            animation.Stop();
            commit();
        };
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        Focus();
        CaptureMouse();
        Drag(e.GetPosition(this));
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (IsMouseCaptured && e.LeftButton == MouseButtonState.Pressed) Drag(e.GetPosition(this));
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (!IsMouseCaptured) return;
        Drag(e.GetPosition(this));
        ReleaseMouseCapture();
        e.Handled = true;
    }

    protected override void OnLostMouseCapture(MouseEventArgs e) => commit();

    protected override void OnKeyDown(KeyEventArgs e)
    {
        var delta = e.Key switch
        {
            Key.Left => new Vector2(-0.08f, 0),
            Key.Right => new Vector2(0.08f, 0),
            Key.Up => new Vector2(0, -0.08f),
            Key.Down => new Vector2(0, 0.08f),
            _ => Vector2.Zero
        };
        if (delta == Vector2.Zero && e.Key != Key.Home) return;
        var value = e.Key == Key.Home ? Vector2.Zero : current + delta;
        Update(value, new Vector(value.X, value.Y));
        commit();
        e.Handled = true;
    }

    private Point Center => new(ActualWidth / 2, ActualHeight / 2);

    private void Drag(Point point)
    {
        var delta = (point - Center) / Radius;
        Update(new Vector2((float)delta.X, (float)delta.Y), delta);
    }

    private Vector target;

    private void Update(Vector2 value, Vector visual)
    {
        current = value.LengthSquared() <= 1 ? value : Vector2.Normalize(value);
        target = IsMouseCaptured && visual.Length > 1
            ? visual / visual.Length * (1 + Math.Min(0.07, (visual.Length - 1) * 0.11))
            : new Vector(current.X, current.Y);
        change(current);
        if (SystemParameters.ClientAreaAnimation)
        {
            animation.Start();
        }
        else
        {
            shown = target;
            InvalidateVisual();
        }
    }

    private void Animate()
    {
        if (!IsMouseCaptured) target = new Vector(current.X, current.Y);
        velocity = (velocity + (target - shown) * 0.26) * 0.66;
        shown += velocity;
        if ((target - shown).LengthSquared < 0.000025 && velocity.LengthSquared < 0.000025)
        {
            shown = target;
            animation.Stop();
        }
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        var center = Center;
        dc.DrawEllipse(SystemColors.ControlBrush, new Pen(SystemColors.ControlDarkBrush, 1), center, Radius, Radius);
        for (int y = -3; y <= 3; y++)
        for (int x = -3; x <= 3; x++)
            if (x * x + y * y <= 12)
                dc.DrawEllipse(SystemColors.ControlDarkBrush, null, center + new Vector(x * 23, y * 23), 1.6, 1.6);
        var accent = SystemParameters.HighContrast ? SystemColors.HighlightBrush :
            new SolidColorBrush(Color.FromRgb(34, 116, 198));
        dc.DrawEllipse(accent, null, center, 4, 4);
        DrawArrow(dc, center, shown * (Radius - 5), new Pen(accent, 4));
    }

    internal static void DrawArrow(DrawingContext dc, Point center, Vector shaft, Pen pen)
    {
        if (shaft.Length < 4) return;
        pen.StartLineCap = pen.EndLineCap = PenLineCap.Round;
        var direction = shaft / shaft.Length;
        var perpendicular = new Vector(-direction.Y, direction.X);
        var tip = center + shaft;
        var head = Math.Min(13, shaft.Length * 0.42);
        dc.DrawLine(pen, center, tip);
        dc.DrawLine(pen, tip, tip - direction * head + perpendicular * (head * 0.59));
        dc.DrawLine(pen, tip, tip - direction * head - perpendicular * (head * 0.59));
    }
}
