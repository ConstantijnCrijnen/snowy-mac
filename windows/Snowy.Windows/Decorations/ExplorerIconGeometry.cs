using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Automation;
using Snowy.Core;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Decorations;

/// <summary>
/// Optional read-only UI Automation bounds for desktop shortcuts. Queries only the shell's
/// accessible list items and returns a small, sanitized geometry snapshot.
/// </summary>
internal static class ExplorerIconGeometry
{
    private const int MaximumItemsPerDisplay = 96;

    public static IReadOnlyDictionary<string, IReadOnlyList<Body>>? Read(IReadOnlyList<DesktopScreen> screens)
    {
        var result = screens.ToDictionary(screen => screen.Id, _ => (IReadOnlyList<Body>)Array.Empty<Body>());
        try
        {
            var window = Native.FindWindow("Progman", null);
            var view = window == IntPtr.Zero ? IntPtr.Zero : Native.FindWindowEx(window, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (view == IntPtr.Zero)
            {
                foreach (var candidate in Native.TopLevelWindows())
                {
                    view = Native.FindWindowEx(candidate, IntPtr.Zero, "SHELLDLL_DefView", null);
                    if (view != IntPtr.Zero) break;
                }
            }
            if (view == IntPtr.Zero) return null;

            var root = AutomationElement.FromHandle(view);
            var items = root.FindAll(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem));
            var grouped = screens.ToDictionary(screen => screen.Id, _ => new List<(string Name, Rect Bounds)>());
            for (var index = 0; index < Math.Min(items.Count, MaximumItemsPerDisplay * Math.Max(1, screens.Count)); index++)
            {
                var item = items[index];
                var name = item.Current.Name;
                var bounds = item.Current.BoundingRectangle;
                if (string.IsNullOrWhiteSpace(name) || name.Length > 160 || bounds.IsEmpty || bounds.Width < 1 || bounds.Height < 1) continue;
                var screen = screens.FirstOrDefault(candidate =>
                    bounds.Left >= candidate.Left && bounds.Left < candidate.Left + candidate.Width &&
                    bounds.Top >= candidate.Top && bounds.Top < candidate.Top + candidate.Height);
                if (string.IsNullOrEmpty(screen.Id)) continue;
                var list = grouped[screen.Id];
                if (list.Count >= MaximumItemsPerDisplay) continue;
                list.Add((name.Trim(), bounds));
            }

            foreach (var screen in screens)
            {
                var ordered = grouped[screen.Id].OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase)
                    .ThenBy(item => item.Bounds.Top).ThenBy(item => item.Bounds.Left).ToArray();
                var occurrences = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
                var bodies = new List<Body>(ordered.Length);
                foreach (var item in ordered)
                {
                    var occurrence = occurrences.GetValueOrDefault(item.Name);
                    occurrences[item.Name] = occurrence + 1;
                    var id = StableId(screen.Id, item.Name, occurrence);
                    var scale = Math.Max(.25, screen.Scale);
                    var left = (float)((item.Bounds.Left - screen.Left) / scale);
                    var top = (float)((item.Bounds.Top - screen.Top) / scale);
                    var width = (float)(item.Bounds.Width / scale);
                    var height = (float)(item.Bounds.Height / scale);
                    var body = new Body(id, new System.Numerics.Vector2(left, top),
                        new System.Numerics.Vector2(width, height), BodyKind.Decoration, 2);
                    if (body.IsValid) bodies.Add(body);
                }
                result[screen.Id] = bodies;
            }
        }
        catch (ElementNotAvailableException) { return null; }
        catch (InvalidOperationException) { return null; }
        catch (System.Runtime.InteropServices.COMException) { return null; }
        return result;
    }

    private static long StableId(string screenId, string name, int duplicateIndex)
    {
        var source = Encoding.UTF8.GetBytes($"{screenId}\n{name.ToUpperInvariant()}\n{duplicateIndex}");
        var digest = SHA256.HashData(source);
        var id = BitConverter.ToInt64(digest, 0) & long.MaxValue;
        return id == 0 ? -1 : -id;
    }

    private static class Native
    {
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        internal static extern IntPtr FindWindow(string? className, string? windowName);
        [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        internal static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string? className, string? windowName);
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
        private delegate bool EnumWindowsProc(IntPtr handle, IntPtr state);

        internal static IReadOnlyList<IntPtr> TopLevelWindows()
        {
            var result = new List<IntPtr>(64);
            EnumWindows((handle, _) => { result.Add(handle); return result.Count < 512; }, IntPtr.Zero);
            return result;
        }
    }
}
