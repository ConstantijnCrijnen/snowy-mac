using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.ApplicationModel;
using Windows.Management.Deployment;

namespace Snowy.Windows.Shell;

internal sealed class PackageUpdater
{
    private static readonly Uri Feed = new("https://snowy.aauburn.com/windows/Snowy.appinstaller");
    private static readonly Uri BetaFeed = new("https://snowy.aauburn.com/windows/update.json");
    public static readonly Uri BetaDownload = new("https://snowy.aauburn.com/#download-windows");
    private static readonly HttpClient BetaClient = new(new HttpClientHandler { AllowAutoRedirect = false })
    {
        Timeout = TimeSpan.FromSeconds(8),
        MaxResponseContentBufferSize = 4096
    };
    private const string PackageName = "ArchieAuburn.Snowy";
    private const int NoPackage = 15700;
    private bool checking;
    public bool UsesBetaInstaller { get; } = IsUnpackaged();
    public bool Available { get; private set; }
    public bool Installing { get; private set; }

    public async Task Check()
    {
        if (checking || Installing) return;
        checking = true;
        try
        {
            if (UsesBetaInstaller)
            {
                Available = await CheckBeta();
                return;
            }
            var package = Package.Current;
            if (package.Id.Name != PackageName || package.GetAppInstallerInfo()?.Uri != Feed)
            {
                Available = false;
                return;
            }
            var result = await package.CheckUpdateAvailabilityAsync();
            Available = result.Availability is PackageUpdateAvailability.Available or PackageUpdateAvailability.Required;
        }
        catch (Exception error) when (error is InvalidOperationException or COMException or UnauthorizedAccessException)
        {
            Available = false;
        }
        finally
        {
            checking = false;
        }
    }

    private static async Task<bool> CheckBeta()
    {
        try
        {
            using var response = await BetaClient.GetAsync(BetaFeed);
            if (!response.IsSuccessStatusCode) return false;
            using var document = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync());
            var feed = document.RootElement;
            if (feed.ValueKind != JsonValueKind.Object || !feed.TryGetProperty("version", out var value) ||
                value.ValueKind != JsonValueKind.String) return false;
            var text = value.GetString();
            return Version.TryParse(text, out var next) && next.Revision >= 0 &&
                next.ToString() == text && next.Major <= 65535 && next.Minor <= 65535 &&
                next.Build <= 65535 && next.Revision <= 65535 &&
                next > typeof(PackageUpdater).Assembly.GetName().Version;
        }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or JsonException)
        {
            return false;
        }
    }

    public async Task<bool> Install()
    {
        if (!Available || Installing || UsesBetaInstaller) return false;
        Installing = true;
        try
        {
            var package = Package.Current;
            if (package.Id.Name != PackageName || package.GetAppInstallerInfo()?.Uri != Feed) return false;
            // Windows verifies the MSIX publisher and package identity before installing.
            const uint noRestartOnCrashHangOrReboot = 1 | 2 | 8;
            if (RegisterApplicationRestart(null, noRestartOnCrashHangOrReboot) != 0) return false;
            var result = await new PackageManager().AddPackageByAppInstallerFileAsync(
                Feed, AddPackageByAppInstallerOptions.ForceTargetAppShutdown, null);
            return result.ExtendedErrorCode is null;
        }
        catch (Exception error) when (error is InvalidOperationException or COMException or UnauthorizedAccessException)
        {
            return false;
        }
        finally
        {
            Installing = false;
        }
    }

    private static bool IsUnpackaged()
    {
        uint length = 0;
        return GetCurrentPackageFullName(ref length, IntPtr.Zero) == NoPackage;
    }

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern int GetCurrentPackageFullName(ref uint length, IntPtr packageFullName);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RegisterApplicationRestart(string? commandLine, uint flags);
}
