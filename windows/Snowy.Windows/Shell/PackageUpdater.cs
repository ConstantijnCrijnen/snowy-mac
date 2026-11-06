using System.Runtime.InteropServices;
using Windows.ApplicationModel;
using Windows.Management.Deployment;

namespace Snowy.Windows.Shell;

internal sealed class PackageUpdater
{
    private static readonly Uri Feed = new("https://snowy.aauburn.com/windows/Snowy.appinstaller");
    private const string PackageName = "ArchieAuburn.Snowy";
    private bool checking;
    public bool Available { get; private set; }
    public bool Installing { get; private set; }

    public async Task Check()
    {
        if (checking || Installing) return;
        checking = true;
        try
        {
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

    public async Task<bool> Install()
    {
        if (!Available || Installing) return false;
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int RegisterApplicationRestart(string? commandLine, uint flags);
}
