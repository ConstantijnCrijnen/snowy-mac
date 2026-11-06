param(
    [ValidatePattern('^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$')]
    [string] $Version = "0.1.0.0",
    [ValidatePattern('^([0-9A-Fa-f]{40})?$')]
    [string] $CertificateThumbprint = ""
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

$kits = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
$kit = Get-ChildItem -Directory $kits | Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName "x64\MakeAppx.exe") } | Select-Object -First 1
if (-not $kit) { throw "Install the Windows SDK with the MSIX packaging tools." }
$makeAppx = Join-Path $kit.FullName "x64\MakeAppx.exe"
$signTool = Join-Path $kit.FullName "x64\SignTool.exe"
$project = Join-Path $PSScriptRoot "../Snowy.Windows/Snowy.Windows.csproj"
$publisher = "CN=Snowy Development"
if ($CertificateThumbprint) {
    $certificate = Get-Item "Cert:\CurrentUser\My\$CertificateThumbprint"
    if (-not $certificate.HasPrivateKey) { throw "The signing certificate has no accessible private key." }
    $publisher = $certificate.Subject
}
$root = Join-Path $PSScriptRoot "../../build/windows/$Version-$([Guid]::NewGuid().ToString('N'))"
$root = (New-Item -Type Directory $root -Force).FullName
$packages = (New-Item -Type Directory (Join-Path $root "packages")).FullName
Push-Location (Join-Path $PSScriptRoot "..")
try {
    foreach ($architecture in @("x64", "arm64")) {
        $staging = Join-Path $root "stage-$architecture"
        Invoke-Checked dotnet @("publish", $project, "-c", "Release", "-r", "win-$architecture",
            "--self-contained", "true", "-o", $staging, "-p:Version=$Version", "-p:DebugType=none")
        Copy-Item (Join-Path $PSScriptRoot "../../LICENSE") (Join-Path $staging "LICENSE.txt")
        Compress-Archive -Path (Join-Path $staging "*") -DestinationPath (Join-Path $root "Snowy-Windows-$architecture.zip")
        $assets = (New-Item -Type Directory (Join-Path $staging "PackageAssets")).FullName
        Copy-Item (Join-Path $PSScriptRoot "Snowy*.png") $assets
        [xml]$manifest = Get-Content -Raw (Join-Path $PSScriptRoot "AppxManifest.xml")
        $manifest.Package.Identity.Publisher = $publisher
        $manifest.Package.Identity.Version = $Version
        $manifest.Package.Identity.ProcessorArchitecture = $architecture
        $manifest.Save((Join-Path $staging "AppxManifest.xml"))
        Invoke-Checked $makeAppx @("pack", "/no", "/d", $staging, "/p", (Join-Path $packages "Snowy-$architecture.msix"))
    }
    $bundle = Join-Path $root "Snowy-Windows.msixbundle"
    Invoke-Checked $makeAppx @("bundle", "/no", "/bv", $Version, "/d", $packages, "/p", $bundle)
    if ($CertificateThumbprint) {
        Invoke-Checked $signTool @("sign", "/sha1", $CertificateThumbprint, "/fd", "SHA256",
            "/tr", "https://timestamp.digicert.com", "/td", "SHA256", $bundle)
        Invoke-Checked $signTool @("verify", "/pa", $bundle)
        $publisherXml = [Security.SecurityElement]::Escape($publisher)
        @"
<?xml version="1.0" encoding="utf-8"?>
<AppInstaller xmlns="http://schemas.microsoft.com/appx/appinstaller/2018"
              Uri="https://snowy.aauburn.com/windows/Snowy.appinstaller" Version="$Version">
  <MainBundle Name="ArchieAuburn.Snowy" Publisher="$publisherXml" Version="$Version"
              Uri="https://github.com/soloiaros/snowy-mac/releases/download/windows-v$Version/Snowy-Windows.msixbundle" />
</AppInstaller>
"@ | Set-Content -Encoding utf8 (Join-Path $root "Snowy.appinstaller")
    }
    Write-Host "Windows artifacts: $root"
}
finally { Pop-Location }
