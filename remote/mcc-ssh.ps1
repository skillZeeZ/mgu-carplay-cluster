<#
.SYNOPSIS
  Copy mgu-carplay-cluster to a rooted iDrive 7 head unit and run mcc.sh over SSH.

.DESCRIPTION
  Convenience wrapper for Windows (matches the MGU installer's SSH style:
  identity key + source-address bind). It never touches carplay/aapd; it only
  runs bin/mcc.sh on the unit. Read-only 'diagnose' is the safe default.

  The .sh files are LF-only; scp transfers them byte-for-byte, so they run
  under the unit's BusyBox sh.

.PARAMETER HeadUnit
  SSH host of the head unit (the SSH IP, which is often NOT the ENET coding IP).

.PARAMETER Key
  Path to the SSH identity (private key). Keep its NTFS perms tight, or SSH
  refuses it ("UNPROTECTED PRIVATE KEY"):
    icacls <key> /inheritance:r /grant:r "$($env:USERNAME):R"

.PARAMETER Bind
  Local source address to bind (disambiguates many 169.254.* interfaces).
  Maps to the installer's ssh_bind. Optional.

.PARAMETER Port
  SSH port (22 locally; your remote_ssh_port, e.g. 2222, over Tailscale).

.PARAMETER Command
  mcc.sh command: diagnose | 'full-map on' | 'full-map off' | 'full-map status'
  | 'eta check' | 'eta update' | revert

.EXAMPLE
  # Read-only check (the test car from the installer config):
  .\mcc-ssh.ps1 -HeadUnit 169.254.68.60 -Bind 169.254.140.211 `
      -Key C:\MGU\ssh\data\enrollments\<VIN>\id_rsa -Command diagnose

.EXAMPLE
  .\mcc-ssh.ps1 -HeadUnit 169.254.68.60 -Bind 169.254.140.211 -Key <key> -Command 'full-map on'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $HeadUnit,
    [Parameter(Mandatory = $true)] [string] $Key,
    [string] $Bind = "",
    [int]    $Port = 22,
    [string] $Command = "diagnose",
    [string] $RemoteDir = "/tmp/mcc"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $Key)) { throw "SSH key not found: $Key" }
$repo = Split-Path -Parent $PSScriptRoot   # repo root (parent of remote/)
$binDir    = Join-Path $repo "bin"
$configDir = Join-Path $repo "config"
foreach ($d in @($binDir, $configDir)) {
    if (-not (Test-Path $d)) { throw "missing repo folder: $d" }
}

# Common SSH/SCP options. ssh uses -p, scp uses -P. Bind maps to BindAddress.
$common = @("-i", $Key, "-o", "StrictHostKeyChecking=accept-new")
if ($Bind) { $common += @("-o", "BindAddress=$Bind") }

$sshArgs = $common + @("-p", "$Port", "root@$HeadUnit")
$scpArgs = $common + @("-P", "$Port", "-r")

Write-Host "[mcc] ensuring $RemoteDir on $HeadUnit ..."
& ssh @sshArgs "mkdir -p $RemoteDir"
if ($LASTEXITCODE -ne 0) { throw "ssh mkdir failed (exit $LASTEXITCODE)" }

Write-Host "[mcc] copying bin/ and config/ ..."
& scp @scpArgs $binDir $configDir "root@${HeadUnit}:$RemoteDir/"
if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }

Write-Host "[mcc] running: mcc.sh $Command"
# $Command may contain a subcommand with a space (e.g. 'full-map on'); pass it
# through to the remote shell as written.
& ssh @sshArgs "sh $RemoteDir/bin/mcc.sh $Command"
$code = $LASTEXITCODE
Write-Host "[mcc] remote exit code: $code"
exit $code
