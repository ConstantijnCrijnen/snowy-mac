[CmdletBinding()]
param(
    [ValidatePattern('^\d{1,5}\.\d{1,5}\.\d{1,5}\.\d{1,5}$')]
    [string] $Version = '0.1.4.0',
    [ValidateSet('arm64', 'x64')]
    [string[]] $Architectures = @('arm64', 'x64'),
    [string] $MakeNsis = '',
    [switch] $UpdateDefenderSignatures,
    [switch] $AllowDefenderUnavailable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) { throw 'Run this script in PowerShell 7 on Windows.' }
if (@($Version.Split('.') | Where-Object { [int]$_ -gt 65535 }).Count -gt 0) {
    throw 'Each version component must fit in 16 bits.'
}
$Version = ([version]$Version).ToString()
if ($Architectures.Count -eq 0) { throw 'Choose at least one architecture.' }
if (@($Architectures | Select-Object -Unique).Count -ne $Architectures.Count) {
    throw 'Duplicate architectures are not allowed.'
}

function Get-MakensisPath {
    if ($MakeNsis) {
        if (Test-Path -LiteralPath $MakeNsis -PathType Leaf) {
            return (Get-Item -LiteralPath $MakeNsis).FullName
        }
        $command = Get-Command $MakeNsis -CommandType Application -ErrorAction Stop
        return $command.Source
    }

    $command = Get-Command 'makensis.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command 'makensis' -CommandType Application -ErrorAction SilentlyContinue }
    if (-not $command) { throw 'NSIS 3.13 makensis was not found. Install it or pass -MakeNsis <path>.' }
    return $command.Source
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string] $Executable,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable exited with code $LASTEXITCODE." }
}

function Write-UninstallInclude {
    param(
        [Parameter(Mandatory = $true)][string] $PayloadDirectory,
        [Parameter(Mandatory = $true)][string] $IncludePath
    )

    $files = @(Get-ChildItem -LiteralPath $PayloadDirectory -File -Recurse -Force)
    if ($files.Count -eq 0) { throw 'The published payload is empty.' }
    $directories = @(Get-ChildItem -LiteralPath $PayloadDirectory -Directory -Recurse -Force)
    foreach ($item in @($files) + @($directories)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The installer payload contains a reparse point: $($item.FullName)"
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('; Generated from this exact publish payload. Do not edit by hand.')
    foreach ($file in $files | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($PayloadDirectory, $file.FullName).Replace('/', '\')
        if ($relative -match '(^|\\)\.\.?($|\\)' -or $relative.Contains('"')) {
            throw "Unsafe payload file name for an NSIS uninstall entry: $relative"
        }
        $relative = $relative.Replace('$', '$$')
        $lines.Add(('Delete "$INSTDIR\{0}"' -f $relative))
    }

    $directoryEntries = foreach ($directory in $directories) {
        $relative = [IO.Path]::GetRelativePath($PayloadDirectory, $directory.FullName).Replace('/', '\')
        if ($relative -match '(^|\\)\.\.?($|\\)' -or $relative.Contains('"')) {
            throw "Unsafe payload directory name for an NSIS uninstall entry: $relative"
        }
        [pscustomobject]@{ Relative = $relative; Depth = $relative.Split('\').Count }
    }
    foreach ($directory in $directoryEntries | Sort-Object @{ Expression = 'Depth'; Descending = $true }, @{ Expression = 'Relative'; Descending = $true }) {
        $relative = $directory.Relative.Replace('$', '$$')
        $lines.Add(('RMDir "$INSTDIR\{0}"' -f $relative))
    }

    $encoding = [System.Text.UTF8Encoding]::new($true)
    [IO.File]::WriteAllLines($IncludePath, $lines, $encoding)
}

function Invoke-DefenderScan {
    param([Parameter(Mandatory = $true)][string[]] $Targets)

    $scanScript = Join-Path $PSScriptRoot 'scan-defender.ps1'
    if (-not (Test-Path -LiteralPath $scanScript -PathType Leaf)) { throw "Missing Defender scanner: $scanScript" }

    & $scanScript -Path $Targets -UpdateSignatures:$UpdateDefenderSignatures
    $scanExitCode = $LASTEXITCODE
    if ($scanExitCode -eq 2 -and $AllowDefenderUnavailable) {
        Write-Warning 'Defender is unavailable. This unsigned setup preview has no clean scan result.'
        return
    }
    if ($scanExitCode -ne 0) { throw "The Defender scan gate failed with exit code $scanExitCode." }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this build from an elevated PowerShell 7 session so the Defender gate can scan the staged files.'
}

$compiler = Get-MakensisPath
$setupScript = Join-Path $PSScriptRoot 'SnowySetup.nsi'
if (-not (Test-Path -LiteralPath $setupScript -PathType Leaf)) { throw "Missing NSIS script: $setupScript" }
$compilerLicense = Join-Path (Split-Path -Parent $compiler) 'COPYING'
if (-not (Test-Path -LiteralPath $compilerLicense -PathType Leaf)) {
    throw "The NSIS compiler's COPYING file must sit beside makensis.exe: $compilerLicense"
}
$project = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Snowy.Windows/Snowy.Windows.csproj'))
$license = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../LICENSE'))
if (-not (Test-Path -LiteralPath $license -PathType Leaf)) { throw "Missing license file: $license" }

$setupRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../build/windows-setup'))
$null = New-Item -ItemType Directory -Path $setupRoot -Force
$buildRoot = Join-Path $setupRoot "$Version-$([Guid]::NewGuid().ToString('N'))"
$buildRoot = [IO.Path]::GetFullPath((New-Item -ItemType Directory -Path $buildRoot).FullName)
$stagedTargets = [System.Collections.Generic.List[string]]::new()
$finalCandidates = [System.Collections.Generic.List[object]]::new()

Push-Location (Join-Path $PSScriptRoot '..')
try {
    foreach ($architecture in $Architectures) {
        $candidateDirectory = Join-Path $buildRoot "candidate-$architecture"
        $payloadDirectory = Join-Path $candidateDirectory 'payload'
        $null = New-Item -ItemType Directory -Path $payloadDirectory -Force
        $payloadDirectory = [IO.Path]::GetFullPath($payloadDirectory)
        $includePath = [IO.Path]::GetFullPath((Join-Path $candidateDirectory 'UninstallInclude.nsh'))
        $candidateInstaller = [IO.Path]::GetFullPath((Join-Path $candidateDirectory "Snowy-Setup-$architecture.exe"))
        $finalInstaller = Join-Path $buildRoot "Snowy-Setup-$architecture.exe"

        Invoke-Checked 'dotnet' @('publish', $project, '-c', 'Release', '-r', "win-$architecture",
            '--self-contained', 'true', '-o', $payloadDirectory, "-p:Version=$Version", '-p:DebugType=none')
        Copy-Item -LiteralPath $license -Destination (Join-Path $payloadDirectory 'LICENSE.txt')
        Copy-Item -LiteralPath $compilerLicense -Destination (Join-Path $payloadDirectory 'NSIS-LICENSE.txt')

        Write-UninstallInclude -PayloadDirectory $payloadDirectory -IncludePath $includePath
        $arguments = @(
            "/DPayloadDir=$payloadDirectory",
            "/DOutputPath=$candidateInstaller",
            "/DAppVersion=$Version",
            "/DArchitecture=$architecture",
            "/DUninstallInclude=$includePath",
            $setupScript
        )
        Invoke-Checked $compiler $arguments
        if (-not (Test-Path -LiteralPath $candidateInstaller -PathType Leaf)) {
            throw "NSIS did not create the expected installer: $candidateInstaller"
        }

        $stagedTargets.Add($payloadDirectory)
        $stagedTargets.Add($candidateInstaller)
        $finalCandidates.Add([pscustomobject]@{ Source = $candidateInstaller; Destination = $finalInstaller })
    }

    Invoke-DefenderScan -Targets $stagedTargets.ToArray()

    foreach ($candidate in $finalCandidates) {
        Move-Item -LiteralPath $candidate.Source -Destination $candidate.Destination
        $name = Split-Path -Leaf $candidate.Destination
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate.Destination).Hash.ToLowerInvariant()
        "$hash  $name" | Set-Content -Encoding ascii "$($candidate.Destination).sha256"
    }

    Write-Host "Windows setup artifacts: $buildRoot"
}
finally {
    Pop-Location
}
