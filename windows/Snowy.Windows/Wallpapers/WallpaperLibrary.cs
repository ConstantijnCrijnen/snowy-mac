using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Wallpapers;

internal sealed record Wallpaper(string Title, string FileName, bool BuiltIn)
{
    public static readonly Wallpaper[] Originals =
    [
        new("Blue Hour", "blue-hour.jpg", true),
        new("Alpenglow", "alpenglow.jpg", true)
    ];
}

internal sealed class WallpaperLibrary(string dataDirectory)
{
    private const int Limit = 60;
    private const int MaxBytes = 64 * 1024 * 1024;
    private const long MaxPixels = 80_000_000;
    private const int MaxEdge = 5120;
    private readonly string directory = Path.Combine(dataDirectory, "Wallpapers");

    public IReadOnlyList<Wallpaper> List()
    {
        var wallpapers = new List<Wallpaper>(Wallpaper.Originals);
        if (!Directory.Exists(directory)) return wallpapers;
        VerifyDirectory();
        wallpapers.AddRange(Directory.EnumerateFiles(directory, "*.jpg")
            .Take(Limit * 4)
            .Select(path => new FileInfo(path))
            .Where(file => IsRegular(file) && file.Name.Length > 37 &&
                Guid.TryParseExact(file.Name[..32], "N", out _) && file.Name[32] == '-')
            .OrderBy(file => file.Name[33..], StringComparer.CurrentCultureIgnoreCase)
            .Take(Limit)
            .Select(file => new Wallpaper(file.Name[33..^4], file.Name, false)));
        return wallpapers;
    }

    public (int Added, int Skipped) Import(IReadOnlyList<string> paths)
    {
        VerifyDirectory();
        int available = Limit + Wallpaper.Originals.Length - List().Count;
        int added = 0;
        foreach (var path in paths.Take(available))
        {
            try
            {
                using var stream = OpenRegular(path);
                var decoder = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None);
                if (decoder is not (JpegBitmapDecoder or PngBitmapDecoder or TiffBitmapDecoder or
                    BmpBitmapDecoder or WmpBitmapDecoder) &&
                    decoder.CodecInfo.ContainerFormat is var format &&
                    format != new Guid("e094b0e2-67f2-45b3-b0ea-115337ca7cf3") && // WebP
                    format != new Guid("e1e62521-6787-405b-a339-500715b5763f")) // HEIF
                    continue;
                var frame = decoder.Frames[0];
                if (frame.PixelWidth <= 0 || frame.PixelHeight <= 0 ||
                    (long)frame.PixelWidth * frame.PixelHeight > MaxPixels) continue;
                var (angle, flip) = Orientation(frame);
                stream.Position = 0;
                BitmapSource bitmap = Decode(stream, Math.Min(MaxEdge, Math.Max(frame.PixelWidth, frame.PixelHeight)),
                    frame.PixelWidth >= frame.PixelHeight);
                if (angle != 0 || flip)
                {
                    var transform = new TransformGroup();
                    if (flip) transform.Children.Add(new ScaleTransform(-1, 1));
                    if (angle != 0) transform.Children.Add(new RotateTransform(angle));
                    bitmap = new TransformedBitmap(bitmap, transform);
                }
                // Normalize the pixels and strip source metadata before storing the copy.
                var pixels = new FormatConvertedBitmap(bitmap, PixelFormats.Bgr24, null, 0);
                int stride = checked(pixels.PixelWidth * 3);
                var bytes = new byte[checked(stride * pixels.PixelHeight)];
                pixels.CopyPixels(bytes, stride, 0);
                var clean = BitmapSource.Create(pixels.PixelWidth, pixels.PixelHeight, 96, 96,
                    PixelFormats.Bgr24, null, bytes, stride);
                var title = new string(Path.GetFileNameWithoutExtension(path)
                    .Where(c => !char.IsControl(c) && !Path.GetInvalidFileNameChars().Contains(c))
                    .Take(48).ToArray()).Trim(' ', '.');
                var name = $"{Guid.NewGuid():N}-{(title.Length > 0 ? title : "Wallpaper")}.jpg";
                WriteNew(name, output =>
                {
                    var encoder = new JpegBitmapEncoder { QualityLevel = 92 };
                    encoder.Frames.Add(BitmapFrame.Create(clean));
                    encoder.Save(output);
                });
                added++;
            }
            catch (Exception error) when (IsImageError(error)) { }
        }
        return (added, paths.Count - added);
    }

    public BitmapSource Preview(Wallpaper wallpaper)
    {
        using var stream = wallpaper.BuiltIn ? Original(wallpaper) : OpenRegular(PathFor(wallpaper));
        if (wallpaper.BuiltIn) return Decode(stream, 320, true);
        var frame = BitmapDecoder.Create(stream, BitmapCreateOptions.DelayCreation, BitmapCacheOption.None).Frames[0];
        if ((long)frame.PixelWidth * frame.PixelHeight > MaxPixels) throw new IOException("The image is too large.");
        stream.Position = 0;
        return Decode(stream, 320, frame.PixelWidth >= frame.PixelHeight);
    }

    public void Apply(Wallpaper wallpaper, DesktopScreen? screen)
    {
        var path = PathFor(wallpaper);
        VerifyDirectory();
        if (wallpaper.BuiltIn && !File.Exists(path))
        {
            using var source = Original(wallpaper);
            WriteNew(Path.GetFileName(path), source.CopyTo);
        }
        using var validated = OpenRegular(path);
        DesktopWallpaper.Set(path, screen);
    }

    private static Stream Original(Wallpaper wallpaper) =>
        Application.GetResourceStream(new Uri($"pack://application:,,,/Assets/{wallpaper.FileName}")).Stream;

    private string PathFor(Wallpaper wallpaper) =>
        Path.Combine(directory, wallpaper.BuiltIn ? $"built-in-{wallpaper.FileName}" : wallpaper.FileName);

    private void VerifyDirectory()
    {
        Directory.CreateDirectory(dataDirectory);
        if (File.GetAttributes(dataDirectory).HasFlag(FileAttributes.ReparsePoint))
            throw new IOException("The wallpaper library is redirected.");
        Directory.CreateDirectory(directory);
        if (File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint))
            throw new IOException("The wallpaper library is redirected.");
    }

    private void WriteNew(string name, Action<Stream> write)
    {
        var temporary = Path.Combine(directory, $"{Guid.NewGuid():N}.tmp");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
                write(output);
            File.Move(temporary, Path.Combine(directory, name));
        }
        finally
        {
            File.Delete(temporary);
        }
    }

    private static bool IsRegular(FileInfo file) => file.Exists &&
        (file.Attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint | FileAttributes.Device)) == 0 &&
        file.Length is > 0 and <= MaxBytes;

    private static FileStream OpenRegular(string path)
    {
        if (!IsRegular(new FileInfo(path))) throw new IOException("The image is unavailable.");
        var stream = File.OpenRead(path);
        if (stream.Length is > 0 and <= MaxBytes) return stream;
        stream.Dispose();
        throw new IOException("The image is too large.");
    }

    private static BitmapSource Decode(Stream stream, int edge, bool width)
    {
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.StreamSource = stream;
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        if (width) bitmap.DecodePixelWidth = edge;
        else bitmap.DecodePixelHeight = edge;
        bitmap.EndInit();
        bitmap.Freeze();
        return bitmap;
    }

    private static (int Angle, bool Flip) Orientation(BitmapFrame frame)
    {
        try
        {
            if (frame.Metadata is not BitmapMetadata metadata) return (0, false);
            object? value = metadata.GetQuery("/app1/ifd/{ushort=274}") ?? metadata.GetQuery("/ifd/{ushort=274}");
            return value switch
            {
                (ushort)2 => (0, true),
                (ushort)3 => (180, false),
                (ushort)4 => (180, true),
                (ushort)5 => (270, true),
                (ushort)6 => (90, false),
                (ushort)7 => (90, true),
                (ushort)8 => (270, false),
                _ => (0, false)
            };
        }
        catch (Exception error) when (error is NotSupportedException or COMException)
        {
            return (0, false);
        }
    }

    internal static bool IsImageError(Exception error) => error is IOException or UnauthorizedAccessException
        or NotSupportedException or ArgumentException or COMException or InvalidOperationException or FormatException;
}
