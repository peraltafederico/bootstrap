<#
keysync.ps1: Windows port of keysync. Mirrors the SSH public keys published on GitHub
into the OpenSSH authorized keys file. Run it from an elevated PowerShell.

  keysync.ps1            sync now
  keysync.ps1 -Install   copy to C:\ProgramData\keysync, schedule every 15 minutes as SYSTEM, sync now

Admin accounts log in with C:\ProgramData\ssh\administrators_authorized_keys, so that is the
default file. Only the block between the keysync markers is managed; keys added by hand are kept.
#>
param(
  [switch]$Install,
  [string]$GitHubUser = $(if ($env:KEYSYNC_GITHUB_USER) { $env:KEYSYNC_GITHUB_USER } else { 'peraltafederico' }),
  [string]$AuthorizedKeys = 'C:\ProgramData\ssh\administrators_authorized_keys'
)
$ErrorActionPreference = 'Stop'

$KeysUrl = "https://github.com/$GitHubUser.keys"
$BeginMark = "# >>> keysync: $KeysUrl >>>"
$EndMark = '# <<< keysync <<<'
# Anything that is not one of these key types means GitHub sent something unexpected.
$KeyLine = '^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) '
$InstallDir = 'C:\ProgramData\keysync'
$TaskName = 'keysync'

function Write-Log([string]$Message) { [Console]::Error.WriteLine("keysync: $Message") }

function Sync-Keys {
  try {
    $response = Invoke-RestMethod -Uri $KeysUrl -TimeoutSec 20 -UseBasicParsing
  } catch {
    Write-Log "could not fetch $KeysUrl, keeping current keys"
    return $false
  }
  [string[]]$keys = @("$response" -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  # An empty or malformed response must never replace working keys, or an outage locks us out.
  $responseInvalid = $keys.Count -eq 0 -or @($keys | Where-Object { $_ -notmatch $KeyLine }).Count -gt 0
  if ($responseInvalid) {
    Write-Log "unexpected response from $KeysUrl, keeping current keys"
    return $false
  }

  [string[]]$current = @()
  if (Test-Path $AuthorizedKeys) { $current = @(Get-Content -LiteralPath $AuthorizedKeys) }
  $kept = New-Object System.Collections.Generic.List[string]
  $skip = $false
  foreach ($line in $current) {
    if ($line -eq $BeginMark) { $skip = $true; continue }
    if ($line -eq $EndMark) { $skip = $false; continue }
    if (-not $skip) { $kept.Add($line) }
  }
  $desired = (@($kept) + $BeginMark + $keys + $EndMark) -join "`n"
  $desired += "`n"

  $unchanged = (Test-Path $AuthorizedKeys) -and ([IO.File]::ReadAllText($AuthorizedKeys) -eq $desired)
  if ($unchanged) {
    Write-Log "up to date ($($keys.Count) keys)"
    return $true
  }
  $dir = Split-Path -Parent $AuthorizedKeys
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $tmp = "$AuthorizedKeys.tmp"
  [IO.File]::WriteAllText($tmp, $desired, (New-Object Text.UTF8Encoding $false))
  Move-Item -Force -LiteralPath $tmp -Destination $AuthorizedKeys
  # sshd ignores administrators_authorized_keys unless only Administrators and SYSTEM can access it.
  icacls $AuthorizedKeys /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
  Write-Log "updated ($($keys.Count) keys)"
  return $true
}

function Install-Keysync {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $target = Join-Path $InstallDir 'keysync.ps1'
  if ($PSCommandPath -ne $target) { Copy-Item -Force -LiteralPath $PSCommandPath -Destination $target }

  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$target`" -GitHubUser $GitHubUser -AuthorizedKeys `"$AuthorizedKeys`""
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
    -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
  Write-Log "installed $target, scheduled every 15 minutes (Task Scheduler: $TaskName)"
}

if ($Install) { Install-Keysync }
if (-not (Sync-Keys)) { exit 1 }
