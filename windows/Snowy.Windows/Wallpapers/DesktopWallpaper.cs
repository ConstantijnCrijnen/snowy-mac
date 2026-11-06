using System.Runtime.InteropServices;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Wallpapers;

internal static class DesktopWallpaper
{
    private static readonly Guid DesktopWallpaperClass = new("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD");

    public static void Set(string path, DesktopScreen? screen)
    {
        var desktop = (IDesktopWallpaper)Activator.CreateInstance(
            Type.GetTypeFromCLSID(DesktopWallpaperClass, throwOnError: true)!)!;
        try
        {
            string? monitor = null;
            if (screen is { } target)
            {
                uint count = desktop.GetMonitorDevicePathCount();
                for (uint i = 0; i < count; i++)
                {
                    var candidate = desktop.GetMonitorDevicePathAt(i);
                    var rect = desktop.GetMonitorRECT(candidate);
                    if (rect.Left != target.Left || rect.Top != target.Top ||
                        rect.Right - rect.Left != target.Width || rect.Bottom - rect.Top != target.Height) continue;
                    monitor = candidate;
                    break;
                }
                if (monitor is null) throw new IOException("The selected display is unavailable.");
            }

            desktop.SetWallpaper(monitor, path);
        }
        finally
        {
            Marshal.FinalReleaseComObject(desktop);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDesktopWallpaper
    {
        void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string? monitor, [MarshalAs(UnmanagedType.LPWStr)] string path);
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string? monitor);
        [return: MarshalAs(UnmanagedType.LPWStr)]
        string GetMonitorDevicePathAt(uint index);
        uint GetMonitorDevicePathCount();
        Rect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitor);
    }
}
