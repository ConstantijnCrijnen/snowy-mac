using System.Text.Json;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Snowy.Windows.Desktop;

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
        var tops = Enumerable.Repeat(converted.PixelHeight, converted.PixelWidth).ToArray();
        var bottoms = new int[converted.PixelWidth];
        for (var y = 0; y < converted.PixelHeight; y++)
        for (var x = 0; x < converted.PixelWidth; x++)
        {
            if (pixels[(y * converted.PixelWidth + x) * 4 + 3] == 0) continue;
            tops[x] = Math.Min(tops[x], y);
            bottoms[x] = y + 1;
        }
        var bands = new List<(int X, int Y, int Width, int Height)>();
        var bandCount = Math.Min(6, Math.Max(1, converted.PixelWidth / 4));
        for (var band = 0; band < bandCount; band++)
        {
            var left = converted.PixelWidth * band / bandCount;
            var right = converted.PixelWidth * (band + 1) / bandCount;
            while (left < right && bottoms[left] == 0) left++;
            while (right > left && bottoms[right - 1] == 0) right--;
            if (left >= right) continue;
            var top = tops[left..right].Max();
            var bottom = bottoms[left..right].Min();
            if (bottom > top) bands.Add((left, top, right - left, bottom - top));
        }
        return bands.OrderByDescending(band => band.Width).ThenBy(band => band.Y).ToList();
    }

    public DecorationScene CreatePreset(DecorationPreset preset, DesktopScreen screen, IReadOnlyList<Snowy.Core.Body> bodies)
    {
        var pieces = ForPreset(preset);
        var taskbarAtBottom = DecorationPlacement.BottomTaskbar(bodies).HasValue;
        var support = taskbarAtBottom ? DecorationSupport.TaskbarTop : DecorationSupport.DesktopEdge;
        var rail = DecorationPlacement.RailFor(support, screen, bodies);
        var screenScale = float.IsFinite(screen.Scale) ? Math.Clamp(screen.Scale, .5, 8) : 1;
        var pixelScale = DecorationPlacement.PixelScale(screen);
        var gap = 11 / screenScale;
        var nativeWidth = pieces.Sum(item => item.Width * pixelScale) + Math.Max(0, pieces.Count - 1) * gap;
        var left = rail.Left + Math.Max(0, (rail.Right - rail.Left - nativeWidth) / 2);
        var props = new List<PlacedDecoration>();
        foreach (var (piece, index) in pieces.Select((piece, index) => (piece, index)))
        {
            var size = piece.Width * pixelScale;
            var prop = new PlacedDecoration(Guid.NewGuid(), piece.Id,
                Math.Clamp((left + size / 2) / Math.Max(1, DecorationService.DipWidth(screen)), 0, 1),
                Pushes: piece.PushesByDefault, Support: support);
            var frame = DecorationPlacement.Frame(prop, piece, screen, bodies);
            props.Add(prop with { X = frame.CenterX / Math.Max(1, DecorationService.DipWidth(screen)) });
            left += size + gap;
        }
        return new DecorationScene(props, []);
    }

}
