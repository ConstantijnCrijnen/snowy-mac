# Snowy for Windows

A separate Windows 11 app for the same interactive desktop snow. Snowy lives in the system tray. Right-click the snowflake near the clock to change the snowfall, choose Glove or Shovel, open Wind, or pause and clear the snow. Left-click it for Wallpapers, Decorations, and the Guide.

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

Copy the whole output folder to Windows and run `Snowy.exe` there. For Windows 11 on an M-series Mac in UTM, use `win-arm64`. The native Windows workflow also produces both preview ZIPs as Actions artifacts. Preview builds use the same tray and desktop code as the installer.

## Installer and updates

Run `./installer/package.ps1` from PowerShell 7 on Windows with the Windows SDK packaging tools installed. It builds self-contained ARM64 and x64 previews and an unsigned MSIX bundle for packaging checks.

A distribution build needs a trusted code-signing certificate with its private key accessible in the Windows current-user certificate store. Pass its thumbprint to `-CertificateThumbprint` and use a monotonically increasing four-part `-Version`. The package identity and publisher must remain stable across releases. The script verifies the signed bundle and generates the App Installer feed only when signing succeeds.

When releasing, attach the signed bundle to a GitHub release tagged `windows-v<four-part-version>` with `--latest=false` so the macOS download continues to resolve to the latest Mac release. Serve `Snowy.appinstaller` at `https://snowy.aauburn.com/windows/Snowy.appinstaller` with content type `application/appinstaller`. Install through that feed to enable the blue **Update** tray item. Windows checks the installed package's update association and verifies the publisher before installation. Keep purchase or entitlement checks separate from this update channel.

## Desktop checks

Use a Windows 11 session to check click-through, window dragging and snapping, taskbar auto-hide, Search and Start dismissal, scaling across displays, and scene editor gestures. Verify the installer and update restart with signed packages. The build and physics checks do not measure desktop rendering, energy use, or compositor behavior.
