# SPDX-License-Identifier: MPL-2.0
#
# setup.ps1 — Burble setup for the Windows host side of a WSL2 deploy.
#
# Run this from an ELEVATED PowerShell. It:
#   1. Checks for the prerequisites (wsl.exe, .NET Framework csc.exe).
#   2. Optionally pre-creates Defender firewall rules for udp/7373+9.
#   3. Installs the Bolt UDP forwarder as a true Windows Service
#      (BurbleBoltUdpForward), running under your account so it can
#      see your per-user WSL distros.
#   4. Prints the next step: install the Linux/WSL side from inside the
#      distro with `bash setup.sh`.
#
# Usage:
#   .\setup.ps1                  # interactive, prompts for confirmation
#   .\setup.ps1 -Distro Ubuntu   # explicit distro
#   .\setup.ps1 -Yes             # non-interactive, accept defaults
#   .\setup.ps1 -SkipFirewall    # don't add Defender rules

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseBOMForUnicodeEncodedFile", "")]
param(
    [string]$Distro,
    [int[]]$Ports = @(7373, 9),
    [switch]$Yes,
    [switch]$SkipFirewall
)

$ErrorActionPreference = 'Stop'

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

Write-Host "═══════════════════════════════════════════════════"
Write-Host "  Burble — Windows host setup"
Write-Host "═══════════════════════════════════════════════════`n"

if (-not (Test-Elevated)) {
    Write-Error @"
This script must run from an elevated PowerShell (Administrator).
Right-click PowerShell → 'Run as administrator', then re-run:
    .\setup.ps1
"@
    exit 1
}

# ─── Preflight ────────────────────────────────────────────────────────────
$problems = @()

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    $problems += "wsl.exe not found — WSL2 must be installed (`wsl --install`)."
}

$cscPaths = @(
    "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)
if (-not ($cscPaths | Where-Object { Test-Path $_ })) {
    $problems += ".NET Framework 4 csc.exe missing — enable 'NET Framework 3.5/4' in Optional Features."
}

if ($problems.Count -gt 0) {
    Write-Host "Preflight FAILED:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  · $_" -ForegroundColor Red }
    exit 1
}
Write-Host "Preflight OK (wsl.exe, csc.exe present)."

# Distro detection
if (-not $Distro) {
    $distros = & wsl.exe -l -q 2>$null | Where-Object { $_ -and $_.Trim() -ne '' } | ForEach-Object { $_.Trim() }
    if ($distros.Count -eq 0) {
        Write-Error "No WSL distros found. Install one first: wsl --install -d Ubuntu"
        exit 1
    }
    $Distro = $distros[0]
    Write-Host "Detected WSL distro: $Distro" -ForegroundColor Cyan
}

# ─── Confirm ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "About to:"
Write-Host "  1. Install Windows Service 'BurbleBoltUdpForward' (relays udp/$($Ports -join ',') -> WSL '$Distro')"
if (-not $SkipFirewall) {
    Write-Host "  2. Add Defender inbound rules for udp/$($Ports -join ',')"
}
Write-Host "  You will be prompted for your account password — the service runs as you so it can see your WSL distros."
Write-Host ""

if (-not $Yes) {
    $ans = Read-Host "Proceed? [Y/n]"
    if ($ans -and $ans -notmatch '^[Yy]') { Write-Host "Aborted."; exit 0 }
}

# ─── Run the forwarder installer ──────────────────────────────────────────
$forwarder = Join-Path $PSScriptRoot 'scripts\wsl-bolt-udp-forward.ps1'
if (-not (Test-Path $forwarder)) {
    Write-Error "Could not find $forwarder. Are you running setup.ps1 from the repo root?"
    exit 1
}

$fwdArgs = @('-Install', '-Distro', $Distro, '-Ports', ($Ports -join ','))
if (-not $SkipFirewall) { $fwdArgs += '-Firewall' }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $forwarder @fwdArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "Forwarder install failed (exit $LASTEXITCODE)."
    exit $LASTEXITCODE
}

# ─── Hand off to the Linux side ──────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════"
Write-Host "  Next: install the Linux/WSL side"
Write-Host "═══════════════════════════════════════════════════"
Write-Host ""
Write-Host "From inside the WSL distro ($Distro), run:" -ForegroundColor Cyan
Write-Host ""
Write-Host "    wsl -d $Distro -- bash -c 'cd ~/burble && ./setup.sh'"
Write-Host ""
Write-Host "or open a WSL shell and just run:  ./setup.sh"
Write-Host ""
Write-Host "Setup complete on the Windows side."
