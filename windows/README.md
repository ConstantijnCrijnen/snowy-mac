# Snowy for Windows

A separate Windows 11 app for the same interactive desktop snow. Click the snowflake near the clock to change the snowfall, choose Glove or Shovel, open Wind, or pause and clear the snow. Choose **Open Snowy…** from that menu for Wallpapers, Decorations, and the Guide. If the snowflake is hidden, look under the up arrow in the system tray.

Snow rests on visible window tops and the bottom taskbar. Windows Search and Start can collect snow when the shell exposes a distinct visible window. The Widgets board and Snap previews can cover the effect while visible without becoming surfaces. Snow and props use a click-through layer with app windows masked out. Windows that are minimized or cloaked on another virtual desktop are ignored.

The same two original wallpapers, four decoration presets, and pixel art are included. Apply wallpaper to one display or all of them, or import your own images. Use **Edit Scene** to arrange individual props and anchor strings of lights. Explorer icon anchors are opt-in and use read-only accessibility bounds and names to identify shortcuts. Names are hashed locally and the editor only saves the resulting IDs. The walkthrough appears on first use and can be replayed from the Guide.

## Build and test

Install the .NET SDK specified in [global.json](global.json) and run these commands from the repository root.

```powershell
cd windows
dotnet run --configuration Release --project Snowy.Core.Tests
dotnet build --configuration Release Snowy.Windows
```

Compilation and the physics checks also work on macOS. Windows 11 is required to run the desktop app. For a portable preview, choose the target that matches your guest or PC.

```powershell
dotnet publish Snowy.Windows -c Release -r win-arm64 --self-contained true -o ../build/windows-preview-arm64
dotnet publish Snowy.Windows -c Release -r win-x64 --self-contained true -o ../build/windows-preview-x64
```

Copy the whole output folder to Windows and run `Snowy.exe` there. For Windows 11 on an M-series Mac in UTM, use `win-arm64`. These commands are for development builds.

## Install the Windows beta

Use the [Windows beta download](https://snowy.aauburn.com/#download-windows) to choose **x64** for Intel and AMD PCs or **ARM64** for Windows on Arm, including UTM on Apple silicon. Open the EXE from Downloads and click **Install**. Snowy appears in Start and in **Settings → Apps → Installed apps**. Checksums are available alongside both installers on GitHub Releases.

Setup installs for the current account. It uses Snowy's Blue Hour artwork, includes the .NET runtime, and preserves your settings and scenes if you reinstall or uninstall it. The preview EXE is unsigned, so SmartScreen or Smart App Control may warn or block it. [Microsoft's SmartScreen guide](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)

To build setup from source, use PowerShell 7 and NSIS 3.13 on Windows. Open an elevated terminal for the build's Defender scan.

```powershell
cd windows
./installer/package-setup.ps1 -MakeNsis 'C:\path\to\makensis.exe' -UpdateDefenderSignatures
```

When a newer desktop beta is available, **Update** appears in the snowflake menu and opens the download chooser. Download the installer, choose **Quit Snowy** from the tray, and run the new setup. Your settings and scenes carry over.

For future beta releases, build and scan both EXEs with **Windows desktop setup**, publish the installers and their checksums under `windows-v<four-part-version>` as a prerelease, then update the release link in `website/index.html`, the installer URLs in `website/src/payments.js`, and the version in `website/windows/update.json` together. The feed only announces a newer version after both installers are available.

## Test the MSIX package

For UTM on Apple Silicon, download `Snowy-Windows-arm64-preview.msix`, its `.sha256` file, and `Snowy-Preview.cer` from the same Windows checks run. For x64, use `Snowy-Windows-preview.msixbundle` and its matching checksum. Copy the files to the Windows guest's local Downloads folder on `C:`. UTM's shared folder is a network drive. Use it to transfer the files, then open the installer from the local copy.

The VM preview has a temporary self-signed certificate and its own package identity. In the VM only, open PowerShell as administrator and trust that exact certificate in **Trusted People**.

```powershell
$installer = '.\Snowy-Windows-arm64-preview.msix'
Get-FileHash -Algorithm SHA256 $installer
Get-FileHash -Algorithm SHA1 .\Snowy-Preview.cer
```

Compare the package hash with its `.sha256` file and the certificate hash with the thumbprint printed in the matching CI log. Once both values match, import the certificate.

```powershell
Import-Certificate -FilePath .\Snowy-Preview.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

Double-click the package and choose **Install**. The standalone ARM64 file uses the standard App Installer screen with Snowy's icon. The combined bundle includes the custom winter-blue theme. The package manages its own uninstall in **Settings → Apps → Installed apps**. The preview certificate expires after 30 days and is for this VM only. Smart App Control on the VM may still require a publicly trusted build. [Microsoft's MSIX signing guide](https://learn.microsoft.com/en-us/windows/msix/package/sign-msix-package-guide)

If App Installer still says it cannot open the package, open **Windows PowerShell** in the same local folder and run `Add-AppxPackage -Path (Resolve-Path -LiteralPath '.\Snowy-Windows-arm64-preview.msix').Path`. If deployment fails, keep the `0x…` error code and Activity ID. [Microsoft's App Installer troubleshooting guide](https://learn.microsoft.com/en-us/windows/msix/app-installer/troubleshoot-appinstaller-issues)

## Distribution and updates

Run `./installer/package.ps1` from PowerShell 7 on Windows with the Windows SDK packaging tools installed. Without signing arguments, it creates an unsigned bundle for layout checks. For direct distribution, pass `-CertificateThumbprint` for a trusted provider's certificate in the current user's `My` store, or use `-ArtifactSigningDlib`, `-ArtifactSigningMetadata` and `-Publisher` with Microsoft's Artifact Signing tools. Use a monotonically increasing four-part `-Version` and keep the package name and verified publisher subject stable across releases.

The release build Authenticode-signs Snowy's own EXE and DLLs, signs the dual-architecture MSIX bundle, verifies the signatures and timestamps, and checks the payloads and final bundle with Defender Antivirus. Run the release build elevated on a Windows build machine with active Defender. `-UpdateDefenderSignatures` updates the scan definitions first. Windows enforces package integrity at launch. The build emits the update feed and SHA-256 only after these checks pass.

When releasing, attach the signed bundle to a GitHub release tagged `windows-v<four-part-version>` with `--latest=false` so the macOS download continues to resolve to the latest Mac release. Serve `Snowy.appinstaller` at `https://snowy.aauburn.com/windows/Snowy.appinstaller` with content type `application/appinstaller`. Link to the file directly so users can download and double-click it. Install through that feed to enable the blue **Update** tray item. Windows checks the installed package's update association and verifies the publisher before installation. Keep purchase or entitlement checks separate from this update channel. [App Installer hosting](https://learn.microsoft.com/en-us/windows/msix/app-installer/app-installer-file-overview)

## Defender and SmartScreen

Check the exact release download in a clean Windows 11 VM with the default protections enabled. If Defender Antivirus quarantines a file, record its detection name, Snowy version, and SHA-256, then submit that exact file as a software developer for Microsoft to review. A SmartScreen warning about an unrecognized app is a separate reputation check. Use the same trusted signing identity for each release. Microsoft Store distribution is the path that avoids SmartScreen download warnings. [Microsoft file submission](https://www.microsoft.com/en-us/wdsi/filesubmission/) · [SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)

## Desktop checks

Use a Windows 11 session to check click-through, window dragging and snapping, taskbar auto-hide, Search and Start dismissal, scaling across displays, and scene editor gestures. Verify the installer and update restart with signed packages. The build and physics checks do not measure desktop rendering, energy use, or compositor behavior.
