<#
.SYNOPSIS
    Installs the EDAMAME plugin and skills for OpenClaw on Windows.

.DESCRIPTION
    PowerShell equivalent of setup/install.sh. Installs the EDAMAME plugin,
    skills, and version metadata into the local OpenClaw configuration
    directory (~\.openclaw\).

.EXAMPLE
    .\setup\install.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$SourceRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$OpenClawDir = Join-Path $env:USERPROFILE ".openclaw"

$Dirs = @(
    (Join-Path $OpenClawDir "extensions\edamame"),
    (Join-Path $OpenClawDir "skills\edamame-extrapolator"),
    (Join-Path $OpenClawDir "skills\edamame-posture"),
    (Join-Path $OpenClawDir "edamame-openclaw\state"),
    (Join-Path $OpenClawDir "edamame-openclaw\service")
)
foreach ($d in $Dirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# Step 1: Install MCP plugin
$PluginSrc = Join-Path $SourceRoot "extensions\edamame"
$PluginDst = Join-Path $OpenClawDir "extensions\edamame"
foreach ($f in @("openclaw.plugin.json", "index.ts")) {
    $src = Join-Path $PluginSrc $f
    if (Test-Path $src) {
        Copy-Item -Force $src (Join-Path $PluginDst $f)
        Write-Host "  edamame plugin file installed: $f"
    } else {
        Write-Warning "  Plugin file not found: $src"
    }
}

# Step 2: Install skills
$SkillExSrc = Join-Path $SourceRoot "skill\edamame-extrapolator\SKILL.md"
$SkillExDst = Join-Path $OpenClawDir "skills\edamame-extrapolator\SKILL.md"
if (Test-Path $SkillExSrc) {
    Copy-Item -Force $SkillExSrc $SkillExDst
    Write-Host "  edamame-extrapolator skill installed"
} else {
    Write-Warning "  SKILL.md not found: $SkillExSrc"
}

$SkillPosSrc = Join-Path $SourceRoot "skill\edamame-posture\SKILL.md"
$SkillPosDst = Join-Path $OpenClawDir "skills\edamame-posture\SKILL.md"
if (Test-Path $SkillPosSrc) {
    Copy-Item -Force $SkillPosSrc $SkillPosDst
    Write-Host "  edamame-posture skill installed"
} else {
    Write-Warning "  SKILL.md not found: $SkillPosSrc"
}

# Step 3: Copy package.json for version tracking
$PkgSrc = Join-Path $SourceRoot "package.json"
$PkgDst = Join-Path $OpenClawDir "edamame-openclaw\package.json"
if (Test-Path $PkgSrc) { Copy-Item -Force $PkgSrc $PkgDst }

# Step 3b: Install healthcheck service files
$ServiceSrc = Join-Path $SourceRoot "service"
$ServiceDst = Join-Path $OpenClawDir "edamame-openclaw\service"
foreach ($f in @("healthcheck_cli.mjs", "health.mjs")) {
    $src = Join-Path $ServiceSrc $f
    if (Test-Path $src) {
        Copy-Item -Force $src (Join-Path $ServiceDst $f)
    }
}
Write-Host "  healthcheck service installed to $ServiceDst"

# Step 4: Try to enable plugin via openclaw CLI
$oc = Get-Command openclaw -ErrorAction SilentlyContinue
if ($oc) {
    try { & openclaw plugins enable edamame 2>$null }
    catch {}
    Write-Host "  edamame plugin enabled via openclaw CLI"
} else {
    Write-Host "  openclaw CLI not found; enable the plugin manually or install OpenClaw first"
}

# Read version
$Version = "unknown"
if (Test-Path $PkgSrc) {
    try {
        $pkg = Get-Content -Raw $PkgSrc | ConvertFrom-Json
        $Version = $pkg.version
    } catch {}
}

Write-Host @"

Installed EDAMAME for OpenClaw v$Version to:
  Plugin:  $OpenClawDir\extensions\edamame\
  Skills:  $OpenClawDir\skills\edamame-extrapolator\
           $OpenClawDir\skills\edamame-posture\
  Version: $OpenClawDir\edamame-openclaw\package.json

Next steps:
1. Ensure OpenClaw is installed and configured (~\.openclaw\openclaw.json)
2. Start the EDAMAME MCP server (via EDAMAME app or edamame_posture)
3. Run: openclaw gateway restart  (to load the plugin)
"@
