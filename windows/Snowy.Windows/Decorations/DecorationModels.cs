using System.Numerics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Snowy.Core;

namespace Snowy.Windows.Decorations;

public enum DecorationPreset { None, ChristmasTree, NewYork, AlpineVillage, WinterMarket, Custom }
public enum DecorationSupport { DesktopEdge, TaskbarTop }
public enum LightPalette { Classic, WarmWhite, Peppermint, Frost }
public enum AnchorEdge { Top, Right, Bottom, Left }

public sealed record DecorationPiece(string Id, string Name, int Width, int Height, bool PushesByDefault, int SolidBottom);
public sealed record PlacedDecoration(Guid Id, string AssetId, double X, double Scale = 1,
    bool Pushes = true, DecorationSupport Support = DecorationSupport.DesktopEdge);
public sealed record LightAnchor(double X, double Y, long? BodyId = null, AnchorEdge? Edge = null,
    double Fraction = 0, bool PersistBodyId = false);
public sealed record HangingLight(Guid Id, List<LightAnchor> Anchors, LightPalette Palette = LightPalette.Classic, double Slack = .22);
public sealed record DecorationScene(List<PlacedDecoration> Props, List<HangingLight> Lights)
{
    public const int MaxProps = 16;
    public const int MaxLights = 6;
    public const int MaxAnchors = 6;
    public static DecorationScene Empty => new([], []);

    public DecorationScene Bounded(IReadOnlySet<string> catalog)
    {
        if (Props is null || Lights is null) return Empty;
        var propIds = new HashSet<Guid>();
        var props = Props.Take(MaxProps).Where(item => item is not null &&
                Enum.IsDefined(item.Support) && item.Id != Guid.Empty && propIds.Add(item.Id) && catalog.Contains(item.AssetId) &&
                double.IsFinite(item.X) && double.IsFinite(item.Scale))
            .Select(item => item with { X = Math.Clamp(item.X, 0, 1), Scale = Math.Clamp(item.Scale, .65, 1.6) })
            .ToList();
        var lightIds = new HashSet<Guid>();
        var lights = Lights.Take(MaxLights).Where(item => item is not null && Enum.IsDefined(item.Palette) &&
                item.Id != Guid.Empty && lightIds.Add(item.Id) && item.Anchors is not null && item.Anchors.Count >= 2)
            .Select(item => item with
            {
                Anchors = item.Anchors.Take(MaxAnchors).Where(anchor => anchor is not null && IsValidAnchor(anchor)).ToList(),
                Slack = double.IsFinite(item.Slack) ? Math.Clamp(item.Slack, .04, .65) : .22
            }).Where(item => item.Anchors.Count >= 2).ToList();
        return new DecorationScene(props, lights);
    }

    private static bool IsValidAnchor(LightAnchor anchor) =>
        double.IsFinite(anchor.X) && double.IsFinite(anchor.Y) && double.IsFinite(anchor.Fraction) &&
        anchor.X is >= 0 and <= 1 && anchor.Y is >= 0 and <= 1 && anchor.Fraction is >= 0 and <= 1 &&
        (!anchor.PersistBodyId || anchor.BodyId is > 0) &&
        (anchor.BodyId is null || anchor.Edge is not null && Enum.IsDefined(anchor.Edge.Value)) &&
        (anchor.Edge is null || Enum.IsDefined(anchor.Edge.Value));
}

public sealed record DecorationDocument(int Version, Dictionary<string, DecorationScene> Scenes,
    bool IncludeDesktopIcons = false);

internal static class DecorationJson
{
    internal const int MaximumBytes = 256_000;
    internal static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
        MaxDepth = 24
    };
}

public static class DecorationPresets
{
    public static IReadOnlyList<(DecorationPreset Id, string Name, string Description)> All { get; } =
    [
        (DecorationPreset.None, "Just snow", "A quiet, wintry desktop."),
        (DecorationPreset.ChristmasTree, "Christmas Tree", "A dressed fir and gifts tied with ribbon."),
        (DecorationPreset.NewYork, "New York", "A brownstone, wreath, and corner streetlamp."),
        (DecorationPreset.AlpineVillage, "Alpine Village", "A snug chalet beneath frosted pines."),
        (DecorationPreset.WinterMarket, "Winter Market", "Hot cocoa and warm lights under a striped awning.")
    ];
}
