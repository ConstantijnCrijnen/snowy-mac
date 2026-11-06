using System.Numerics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Snowy.Core;
using Snowy.Windows.Desktop;

namespace Snowy.Windows.Shell;

internal sealed class WeatherSettings
{
    public bool Enabled { get; set; } = true;
    public bool SawWalkthrough { get; set; }
    public Snowfall Snowfall { get; set; } = Snowfall.Steady;
    public SnowTool Tool { get; set; } = SnowTool.Glove;
    public float WindX { get; set; }
    public float WindY { get; set; }

    [JsonIgnore] public Vector2 Wind => new(WindX, WindY);
    [JsonIgnore] public DesktopOptions Desktop => new(Enabled, Snowfall, Wind, Tool);

    public void SetWind(Vector2 wind)
    {
        WindX = wind.X;
        WindY = wind.Y;
    }

    public static WeatherSettings Load(string directory)
    {
        try
        {
            if (Directory.Exists(directory) && File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint))
                return new WeatherSettings();
            var file = new FileInfo(Path.Combine(directory, "settings.json"));
            if (file.Exists && file.Length <= 16_384 && !file.Attributes.HasFlag(FileAttributes.ReparsePoint))
            {
                using var stream = file.OpenRead();
                var settings = JsonSerializer.Deserialize<WeatherSettings>(stream);
                if (settings is not null)
                {
                    if (!Enum.IsDefined(settings.Snowfall)) settings.Snowfall = Snowfall.Steady;
                    if (!Enum.IsDefined(settings.Tool)) settings.Tool = SnowTool.Glove;
                    var wind = settings.Wind;
                    if (!float.IsFinite(wind.LengthSquared())) wind = Vector2.Zero;
                    if (wind.LengthSquared() > 1) wind = Vector2.Normalize(wind);
                    settings.SetWind(wind);
                    return settings;
                }
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { }
        return new WeatherSettings();
    }

    public void Save(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            if (File.GetAttributes(directory).HasFlag(FileAttributes.ReparsePoint)) return;
            var temporary = Path.Combine(directory, $"{Guid.NewGuid():N}.tmp");
            try
            {
                using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write))
                    JsonSerializer.Serialize(stream, this);
                File.Move(temporary, Path.Combine(directory, "settings.json"), true);
            }
            finally
            {
                File.Delete(temporary);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }
}
