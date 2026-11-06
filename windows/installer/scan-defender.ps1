<#
.SYNOPSIS
    Scans exact Windows Snowy release payload paths with Microsoft Defender Antivirus.
.DESCRIPTION
    Uses a Defender custom scan with remediation disabled. It never changes Defender
    settings, exclusions, services, or policies. Signature updates require the explicit
    -UpdateSignatures switch. Requires PowerShell 7 and an elevated session.

    Exit codes: 0 clean, 1 detection or scan error, 2 Defender absent/passive, 3 setup error.
    MpCmdRun returns 2 for both a detection and a scan error, so both fail closed as 1.
.EXAMPLE
    & ./windows/installer/scan-defender.ps1 -Path @('./build/Snowy.exe', './publish/Snowy')
.NOTES
    https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus
    https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-antivirus-compatibility
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateCount(1, 16)]
    [string[]] $Path,
    [switch] $UpdateSignatures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Finish([int] $Code, [string] $Outcome, [string] $Reason, $Status = $null) {
    $result = [ordered]@{ type = 'summary'; outcome = $Outcome; reason = $Reason; exitCode = $Code }
    if ($null -ne $Status) { $result['defender'] = $Status }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $result -Depth 6 -Compress))
    exit $Code
}

function Get-DefenderStatus {
    if (-not (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue)) {
        Import-Module Defender -ErrorAction Stop
    }
    $value = Get-MpComputerStatus -ErrorAction Stop
    [pscustomobject]@{
        Available = $true
        Mode = [string]$value.AMRunningMode
        ServiceEnabled = [bool]$value.AMServiceEnabled
        AntivirusEnabled = [bool]$value.AntivirusEnabled
        SignatureVersion = [string]$value.AntivirusSignatureVersion
        SignatureLastUpdated = if ($value.AntivirusSignatureLastUpdated) { $value.AntivirusSignatureLastUpdated.ToString('o') } else { '' }
        SignatureAgeDays = if ($null -ne $value.PSObject.Properties['AntivirusSignatureAge'] -and $null -ne $value.AntivirusSignatureAge) { [long]$value.AntivirusSignatureAge } else { $null }
        Architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
}

function Find-MpCmdRun {
    $locations = @()
    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path -LiteralPath $platform -PathType Container) {
        $locations += Get-ChildItem -LiteralPath $platform -Directory | Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' }
    }
    if ($env:ProgramFiles) { $locations += Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe' }
    foreach ($location in $locations) {
        if (-not (Test-Path -LiteralPath $location -PathType Leaf)) { continue }
        $signature = Get-AuthenticodeSignature -LiteralPath $location
        if ($signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'O=Microsoft Corporation') {
            return $location
        }
    }
    return $null
}

function Resolve-ExactTarget([string] $InputPath) {
    if ([string]::IsNullOrWhiteSpace($InputPath) -or $InputPath.IndexOfAny([char[]]'*?') -ge 0) {
        throw 'Provide an exact filesystem path without wildcards.'
    }
    $item = Get-Item -LiteralPath $InputPath -Force -ErrorAction Stop
    if (-not ($item -is [IO.FileInfo] -or $item -is [IO.DirectoryInfo])) { throw "Not a file or directory: $InputPath" }
    $full = [IO.Path]::GetFullPath($item.FullName)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.TrimEnd('\') -eq $root.TrimEnd('\')) { throw "Refusing to scan a filesystem root: $full" }

    $cursor = $item
    while ($null -ne $cursor) {
        $cursor.Refresh()
        if (($cursor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse path: $($cursor.FullName)" }
        if ($cursor.FullName -eq $root) { break }
        $cursor = [IO.Directory]::GetParent($cursor.FullName)
    }
    if ($item -is [IO.DirectoryInfo]) {
        foreach ($child in Get-ChildItem -LiteralPath $full -Force -ErrorAction Stop) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing a reparse path: $($child.FullName)" }
        }
    }
    return $full
}

function Invoke-MpCmdRun([string] $Executable, [string[]] $Arguments) {
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Executable
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'MpCmdRun did not start.' }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(1800000)) {
        try { $process.Kill($true) } catch { }
        return [pscustomobject]@{ ExitCode = -1; Output = 'MpCmdRun exceeded the 30 minute limit.' }
    }
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = (($stdout.GetAwaiter().GetResult() + "`n" + $stderr.GetAwaiter().GetResult()).Trim())
    }
}

if ($env:OS -ne 'Windows_NT') { Finish 3 'unsupported-host' 'This scan requires Windows.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Finish 3 'setup-error' 'Run this scan from an elevated PowerShell session.'
}

try {
    $targets = @($Path | ForEach-Object { Resolve-ExactTarget $_ })
    if (@($targets | Select-Object -Unique).Count -ne $targets.Count) { throw 'Duplicate scan targets are not allowed.' }
    foreach ($target in $targets) {
        foreach ($other in $targets) {
            if ($target -ne $other -and $target.StartsWith($other.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Overlapping scan targets are not allowed: $target and $other"
            }
        }
    }
}
catch { Finish 3 'invalid-scan-target' $_.Exception.Message }

try { $defender = Get-DefenderStatus }
catch { Finish 2 'defender-unavailable' 'Defender status is unavailable on this runner.' }
if (-not $defender.ServiceEnabled -or -not $defender.AntivirusEnabled -or $defender.Mode -ne 'Normal') {
    Finish 2 'defender-not-active' "Defender is not active (mode '$($defender.Mode)'). No clean result is reported." $defender
}

$mpCmdRun = Find-MpCmdRun
if (-not $mpCmdRun) { Finish 3 'setup-error' 'Defender reports active, but a valid Microsoft-signed MpCmdRun.exe was not found.' $defender }

if ($UpdateSignatures) {
    $update = Invoke-MpCmdRun $mpCmdRun @('-SignatureUpdate')
    if ($update.ExitCode -ne 0) { Finish 1 'signature-update-failed' $update.Output $defender }
    try { $defender = Get-DefenderStatus }
    catch { Finish 1 'signature-update-unverified' 'Could not verify Defender status after the requested update.' }
}
if (-not $defender.SignatureVersion) { Finish 1 'signatures-unverified' 'Defender reported no signature version.' $defender }
if ($null -ne $defender.SignatureAgeDays -and $defender.SignatureAgeDays -gt 7) {
    Finish 1 'stale-signatures' "Defender signatures are $($defender.SignatureAgeDays) days old. Rerun with -UpdateSignatures." $defender
}

$failed = $false
foreach ($target in $targets) {
    try {
        $scan = Invoke-MpCmdRun $mpCmdRun @('-Scan', '-ScanType', '3', '-File', $target, '-DisableRemediation', '-Timeout', '1')
        $clean = $scan.ExitCode -eq 0
        if (-not $clean) { $failed = $true }
        $line = [ordered]@{ type = 'scan'; path = $target; outcome = if ($clean) { 'clean' } else { 'detection-or-scan-error' }; exitCode = $scan.ExitCode; output = $scan.Output }
    }
    catch {
        $failed = $true
        $line = [ordered]@{ type = 'scan'; path = $target; outcome = 'scan-invocation-error'; exitCode = $null; output = $_.Exception.Message }
    }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $line -Depth 6 -Compress))
}
if ($failed) { Finish 1 'scan-failed' 'A target was detected or a scan failed. Review the MpCmdRun output.' $defender }
Finish 0 'clean' 'Every exact target completed with MpCmdRun exit code 0 and remediation disabled.' $defender
