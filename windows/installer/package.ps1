param(
    [ValidatePattern('^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$')]
    [string] $Version = "0.1.4.0",
    [ValidatePattern('^([0-9A-Fa-f]{40})?$')]
    [string] $CertificateThumbprint = "",
    [ValidatePattern('^([0-9A-Fa-f]{40})?$')]
    [string] $PreviewCertificateThumbprint = "",
    [string] $ArtifactSigningDlib = "",
    [string] $ArtifactSigningMetadata = "",
    [string] $Publisher = "",
    [switch] $UpdateDefenderSignatures,
    [switch] $AllowDefenderUnavailable
)

$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "Run this script in PowerShell 7 on Windows." }
if (($Version.Split('.') | Where-Object { [int]$_ -gt 65535 }).Count -gt 0) {
    throw "Each package version component must fit in 16 bits."
}
$Version = ([version]$Version).ToString()

function Invoke-Checked {
    param([string] $Executable, [string[]] $Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable exited with code $LASTEXITCODE." }
}

$preview = [bool]$PreviewCertificateThumbprint
$cloudSigning = [bool]($ArtifactSigningDlib -or $ArtifactSigningMetadata -or $Publisher)
if (@($preview, $cloudSigning, [bool]$CertificateThumbprint).Where({ $_ }).Count -gt 1) {
    throw "Choose one signing method."
}
$release = $cloudSigning -or [bool]$CertificateThumbprint
if ($AllowDefenderUnavailable -and $release) {
    throw "A release requires a successful Defender scan."
}

$kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$kit = Get-ChildItem -Directory $kits | Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName "x64\MakeAppx.exe") } | Select-Object -First 1
if (-not $kit) { throw "Install the Windows SDK with the MSIX packaging tools." }
$makeAppx = Join-Path $kit.FullName "x64\MakeAppx.exe"
$signTool = Join-Path $kit.FullName "x64\SignTool.exe"
$project = Join-Path $PSScriptRoot "../Snowy.Windows/Snowy.Windows.csproj"
$packageName = "ArchieAuburn.Snowy"
$bundleName = "Snowy-Windows.msixbundle"
$signArguments = @()
if ($cloudSigning) {
    if (-not $Publisher -or -not $ArtifactSigningDlib -or -not $ArtifactSigningMetadata) {
        throw "Artifact Signing requires its installed dlib, a metadata file, and the verified publisher subject."
    }
    $ArtifactSigningDlib = (Get-Item -LiteralPath $ArtifactSigningDlib).FullName
    $ArtifactSigningMetadata = (Get-Item -LiteralPath $ArtifactSigningMetadata).FullName
    $signArguments = @("/dlib", $ArtifactSigningDlib, "/dmdf", $ArtifactSigningMetadata,
        "/tr", "https://timestamp.acs.microsoft.com", "/td", "SHA256")
} elseif ($release -or $preview) {
    $thumbprint = if ($preview) { $PreviewCertificateThumbprint } else { $CertificateThumbprint }
    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint"
    if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date)) {
        throw "The signing certificate must be current and have an accessible private key."
    }
    if ($release -and $certificate.Subject -eq $certificate.Issuer) {
        throw "Release signing requires a certificate issued by a trusted provider."
    }
    $Publisher = $certificate.Subject
    $signArguments = @("/sha1", $thumbprint)
    if ($release) {
        $signArguments += @("/tr", "https://timestamp.digicert.com", "/td", "SHA256")
    } else {
        $packageName += ".Preview"
        $bundleName = "Snowy-Windows-preview.msixbundle"
    }
} else {
    $Publisher = "CN=Snowy Development"
    $bundleName = "Snowy-Windows-unsigned.msixbundle"
}

function Sign-Artifact([string] $Path) {
    Invoke-Checked $signTool (@("sign", "/fd", "SHA256") + $signArguments + $Path)
    $verify = @("verify", "/pa")
    if ($release) { $verify += "/tw" }
    Invoke-Checked $signTool ($verify + $Path)
}

$root = Join-Path $PSScriptRoot "../../build/windows/$Version-$([Guid]::NewGuid().ToString('N'))"
$root = (New-Item -Type Directory $root -Force).FullName
$packages = (New-Item -Type Directory (Join-Path $root "packages")).FullName
$candidateDirectory = (New-Item -Type Directory (Join-Path $root "candidate")).FullName
$armPreview = Join-Path $candidateDirectory "Snowy-Windows-arm64-preview.msix"
$scanPaths = @()
Push-Location (Join-Path $PSScriptRoot "..")
try {
    foreach ($architecture in @("x64", "arm64")) {
        $staging = Join-Path $root "stage-$architecture"
        Invoke-Checked dotnet @("publish", $project, "-c", "Release", "-r", "win-$architecture",
            "--self-contained", "true", "-o", $staging, "-p:Version=$Version", "-p:DebugType=none")
        Copy-Item (Join-Path $PSScriptRoot "../../LICENSE") (Join-Path $staging "LICENSE.txt")
        if ($signArguments.Count) {
            foreach ($binary in @("Snowy.exe", "Snowy.dll", "Snowy.Core.dll")) {
                Sign-Artifact (Join-Path $staging $binary)
            }
        }

        $assets = (New-Item -Type Directory (Join-Path $staging "PackageAssets")).FullName
        Copy-Item (Join-Path $PSScriptRoot "Snowy*.png") $assets
        [xml]$manifest = Get-Content -Raw (Join-Path $PSScriptRoot "AppxManifest.xml")
        $manifest.Package.Identity.Name = $packageName
        $manifest.Package.Identity.Publisher = $Publisher
        $manifest.Package.Identity.Version = $Version
        $manifest.Package.Identity.ProcessorArchitecture = $architecture
        if ($preview) {
            $manifest.Package.Properties.DisplayName = "Snowy Preview"
            $manifest.Package.Applications.Application.VisualElements.DisplayName = "Snowy Preview"
        }
        $manifest.Save((Join-Path $staging "AppxManifest.xml"))
        if ($preview -and $architecture -eq "arm64") {
            # Use the standard App Installer screen for the standalone VM preview.
            Invoke-Checked $makeAppx @("pack", "/no", "/d", $staging, "/p", $armPreview)
            Sign-Artifact $armPreview
            $scanPaths += $armPreview
        }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "Msix.AppInstaller.Data") -Destination $staging -Recurse
        $package = Join-Path $packages "Snowy-$architecture.msix"
        Invoke-Checked $makeAppx @("pack", "/no", "/d", $staging, "/p", $package)
        $archive = [IO.Compression.ZipFile]::OpenRead($package)
        try {
            $entries = $archive.Entries.FullName.Replace('\', '/')
            foreach ($required in @("Msix.AppInstaller.Data/MSIXAppInstallerData.xml", "PackageAssets/Snowy150.png")) {
                if ($required -cnotin $entries) { throw "The $architecture package is missing $required." }
            }
        } finally { $archive.Dispose() }
        $scanPaths += $staging
    }

    $candidate = Join-Path $candidateDirectory $bundleName
    Invoke-Checked $makeAppx @("bundle", "/no", "/bv", $Version, "/d", $packages, "/p", $candidate)
    if ($signArguments.Count) { Sign-Artifact $candidate }

    if ($release -or $preview) {
        $scanPaths += $candidate
        & (Join-Path $PSScriptRoot "scan-defender.ps1") -Path $scanPaths -UpdateSignatures:$UpdateDefenderSignatures
        if ($LASTEXITCODE -eq 2 -and $AllowDefenderUnavailable) {
            Write-Warning "Defender is unavailable. This preview has no Defender scan result."
        } elseif ($LASTEXITCODE -ne 0) {
            throw "The Windows Defender gate failed (exit $LASTEXITCODE)."
        }
    }
    $installers = if ($preview) { @($candidate, $armPreview) } else { @($candidate) }
    foreach ($installer in $installers) {
        $name = Split-Path -Leaf $installer
        $final = Join-Path $root $name
        Move-Item -LiteralPath $installer -Destination $final
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $final).Hash.ToLowerInvariant()
        "$hash  $name" | Set-Content -Encoding ascii "$final.sha256"
    }

    if ($preview) {
        Export-Certificate -Cert $certificate -FilePath (Join-Path $root "Snowy-Preview.cer") | Out-Null
        Write-Host "Preview certificate SHA-1 thumbprint: $($certificate.Thumbprint)"
    }
    if ($release) {
        $publisherXml = [Security.SecurityElement]::Escape($Publisher)
        @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2018"
              Uri="https://snowy.aauburn.com/windows/Snowy.appinstaller" Version="$Version">
  <MainBundle Name="$packageName" Publisher="$publisherXml" Version="$Version"
              Uri="https://github.com/soloiaros/snowy-mac/releases/download/windows-v$Version/$bundleName" />
</AppInstaller>
"@ | Set-Content -Encoding utf8 (Join-Path $root "Snowy.appinstaller")
    }
    Write-Host "Windows artifacts: $root"
}
finally { Pop-Location }
