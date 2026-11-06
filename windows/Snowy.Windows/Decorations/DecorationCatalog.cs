using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Snowy.Windows.Decorations;

public sealed class DecorationCatalog
{
    private static readonly string[][] PresetNames =
    [
        [],
        ["Red present", "Decorated fir", "Blue present"],
        ["Corner streetlamp", "Holiday brownstone", "Red fire hydrant"],
        ["Frosted pine", "Alpine chalet", "Snowman"],
        ["Cocoa chalkboard", "Cocoa stall", "Cocoa supplies"]
    ];
    private readonly Dictionary<string, BitmapSource> images;
    private readonly Dictionary<string, DecorationPiece> piecesById;
    private readonly Dictionary<string, IReadOnlyList<(int X, int Y, int Width, int Height)>> colliderCache = new(StringComparer.Ordinal);

    public IReadOnlyList<DecorationPiece> Pieces { get; }
    public IReadOnlySet<string> Ids { get; }

    public DecorationCatalog()
    {
        var jsonUri = new Uri("pack://application:,,,/Snowy;component/Decorations/Assets/catalog.json", UriKind.Absolute);
        var info = Application.GetResourceStream(jsonUri)
                   ?? throw new InvalidOperationException("The decoration catalog resource is missing.");
        using var stream = info.Stream;
        var entries = JsonSerializer.Deserialize<List<DecorationPiece>>(stream, DecorationJson.Options)
                      ?? throw new InvalidDataException("The decoration catalog is empty.");
        if (entries.Count > 64 || entries.Any(entry => entry.Width is < 1 or > 256 || entry.Height is < 1 or > 256))
            throw new InvalidDataException("The decoration catalog exceeds its resource limits.");
        Pieces = entries;
        Ids = entries.Select(item => item.Id).ToHashSet(StringComparer.Ordinal);
        piecesById = entries.ToDictionary(item => item.Id, StringComparer.Ordinal);
        images = new Dictionary<string, BitmapSource>(StringComparer.Ordinal);
        foreach (var piece in entries)
        {
            var bitmap = new BitmapImage();
            bitmap.BeginInit();
            bitmap.CacheOption = BitmapCacheOption.OnLoad;
            bitmap.UriSource = new Uri($"pack://application:,,,/Snowy;component/Decorations/Assets/{piece.Id}.png", UriKind.Absolute);
            bitmap.EndInit();
            bitmap.Freeze();
            images.Add(piece.Id, bitmap);
            colliderCache.Add(piece.Id, CalculateColliderBands(bitmap));
        }
    }

    public BitmapSource Image(string id) => images.TryGetValue(id, out var image)
        ? image
        : throw new KeyNotFoundException("Unknown decoration asset.");

    public IReadOnlyList<DecorationPiece> ForPreset(DecorationPreset preset)
    {
        var index = (int)preset;
        return index is >= 0 and < 5
            ? PresetNames[index].Select(Find).Where(piece => piece is not null).Cast<DecorationPiece>().ToList()
            : [];
    }

    public DecorationPiece? Find(string id) => piecesById.GetValueOrDefault(id);

    public IReadOnlyList<(int X, int Y, int Width, int Height)> ColliderBands(string id) =>
        colliderCache.GetValueOrDefault(id) ?? [];

    private static IReadOnlyList<(int X, int Y, int Width, int Height)> CalculateColliderBands(BitmapSource bitmap)
    {
        var converted = new FormatConvertedBitmap(bitmap, PixelFormats.Pbgra32, null, 0);
        var pixels = new byte[converted.PixelWidth * converted.PixelHeight * 4];
        converted.CopyPixels(pixels, converted.PixelWidth * 4, 0);
        var bands = new List<(int X, int Y, int Width, int Height)>();
        for (var band = 0; band < 3; band++)
        {
            var left = band * converted.PixelWidth / 3;
            var right = (band + 1) * converted.PixelWidth / 3;
            if (band == 2) right = converted.PixelWidth;
            var top = converted.PixelHeight;
            var bottom = -1;
            var minX = right;
            var maxX = left - 1;
            for (var y = 0; y < converted.PixelHeight; y++)
            for (var x = left; x < right; x++)
            {
                if (pixels[(y * converted.PixelWidth + x) * 4 + 3] == 0) continue;
                top = Math.Min(top, y);
                bottom = Math.Max(bottom, y);
                minX = Math.Min(minX, x);
                maxX = Math.Max(maxX, x);
            }
            if (bottom >= top && maxX >= minX)
                bands.Add((minX, top, maxX - minX + 1, bottom - top + 1));
        }
        return bands;
    }

    public DecorationScene CreatePreset(DecorationPreset preset, double screenWidth, bool taskbarAtBottom)
    {
        var pieces = ForPreset(preset);
        var nativeWidth = pieces.Sum(item => item.Width * 3.0) + Math.Max(0, pieces.Count - 1) * 11;
        var left = 18.0;
        if (left + nativeWidth > screenWidth - 18) left = Math.Max(0, (screenWidth - nativeWidth) / 2);
        var props = new List<PlacedDecoration>();
        foreach (var (piece, index) in pieces.Select((piece, index) => (piece, index)))
        {
            var size = piece.Width * 3.0;
            props.Add(new PlacedDecoration(Guid.NewGuid(), piece.Id, Math.Clamp((left + size / 2) / screenWidth, 0, 1),
                Pushes: piece.PushesByDefault,
                Support: taskbarAtBottom ? DecorationSupport.TaskbarTop : DecorationSupport.DesktopEdge));
            left += size + 11;
        }
        return new DecorationScene(props, []);
    }

}
