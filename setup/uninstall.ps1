<#
.SYNOPSIS
    Uninstalls EDAMAME for OpenClaw on Windows.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$UserProfile = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$OpenClawDir = Join-Path $UserProfile ".openclaw"
$AgentIdFile = Join-Path $UserProfile ".edamame_openclaw_agent_instance_id"

$OpenClawCli = Get-Command openclaw -ErrorAction SilentlyContinue
if ($OpenClawCli) {
    try { & openclaw plugins disable edamame 2>$null } catch {}
}

foreach ($PathToRemove in @(
    (Join-Path $OpenClawDir "extensions\edamame"),
    (Join-Path $OpenClawDir "skills\edamame-extrapolator"),
    (Join-Path $OpenClawDir "skills\edamame-posture"),
    (Join-Path $OpenClawDir "edamame-openclaw")
)) {
    if (Test-Path $PathToRemove) {
        Remove-Item -Recurse -Force $PathToRemove
    }
}

if (Test-Path $AgentIdFile) {
    Remove-Item -Force $AgentIdFile
}

Write-Host @"
Uninstalled EDAMAME for OpenClaw from:
  $OpenClawDir
"@
