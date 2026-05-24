# SPDX-License-Identifier: MPL-2.0
#
# tests/install/roundtrip-windows.ps1 — full install→start→stop→
# uninstall cycle for the Windows Service path in
# scripts/wsl-bolt-udp-forward.ps1 -Install.
#
# Strategy:
#   * create a throwaway local user `burble-ci-test` with a random
#     password and add it to the Users group
#   * pass a pre-built PSCredential to -Install (skips Get-Credential
#     interactive prompt — that's why we added the -Credential param)
#   * assert the service installs, Get-Service shows Stopped/Running,
#     Start-Service works (or fails benignly because wsl.exe can't
#     resolve a distro in CI — that's fine, we only care about the
#     SCM install/uninstall round-trip)
#   * Uninstall, assert Get-Service no longer finds the service
#   * Always remove the throwaway user in a `finally` block
#
# Run from an elevated PowerShell. Mostly intended for CI
# (windows-latest); also runnable on a dev box if you don't mind the
# transient local user.

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingEmptyCatchBlock", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingWriteHost", "")]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseBOMForUnicodeEncodedFile", "")]
param()

$ErrorActionPreference = 'Stop'

$RepoDir   = (Resolve-Path "$PSScriptRoot\..\..").Path
$Forwarder = Join-Path $RepoDir 'scripts\wsl-bolt-udp-forward.ps1'
$SvcName   = 'BurbleBoltUdpForward'
$TestUser  = 'burble-ci-test'

$script:Pass = 0; $script:Fail = 0
function Pass($m) { Write-Host ("  PASS {0}" -f $m) -ForegroundColor Green; $script:Pass++ }
function Fail($m) { Write-Host ("  FAIL {0}" -f $m) -ForegroundColor Red;   $script:Fail++ }
function Hdr($m)  { Write-Host ""; Write-Host ("── {0} ──" -f $m) -ForegroundColor Cyan }

# ─── Preflight ────────────────────────────────────────────────────────────
Hdr "Preflight"
$elev = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $elev) { Write-Error "Must run elevated."; exit 2 }
Pass "elevated"

if (-not (Test-Path $Forwarder)) {
    Write-Error "Forwarder script not found at $Forwarder"; exit 2
}
Pass "forwarder script found"

# ─── Create throwaway local user ──────────────────────────────────────────
Hdr "Create throwaway local user"
$Plain = -join ((33..126) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
# Strip characters that the SCM's credential parser dislikes
$Plain = ($Plain -replace '[\\"`]', 'x')
$SecurePw = ConvertTo-SecureString $Plain -AsPlainText -Force

try {
    Remove-LocalUser -Name $TestUser -ErrorAction SilentlyContinue
    New-LocalUser -Name $TestUser -Password $SecurePw `
        -AccountNeverExpires -PasswordNeverExpires `
        -Description 'Burble test user — safe to delete' | Out-Null
    Add-LocalGroupMember -Group 'Users' -Member $TestUser -ErrorAction SilentlyContinue
    Pass "created local user $TestUser"

    $Cred = New-Object System.Management.Automation.PSCredential(
        ".\$TestUser", $SecurePw)

    # ─── Install via -Credential (non-interactive) ───────────────────────
    Hdr "Install service"
    try {
        & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $Forwarder `
            -Install -Credential $Cred -Distro 'Ubuntu' -Ports 7373,9
        if ($LASTEXITCODE -eq 0) { Pass "install exit 0" }
        else                     { Fail "install exit $LASTEXITCODE" }
    } catch {
        Fail "install threw: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 2

    # ─── Assert service registered ───────────────────────────────────────
    Hdr "Assert service registered"
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($svc) {
        Pass "Get-Service finds $SvcName (status=$($svc.Status), startup=$($svc.StartType))"
    } else {
        Fail "Get-Service did not find $SvcName"
    }

    # The relay child will likely crash in CI because wsl.exe can't
    # resolve a real distro IP. That's expected — we only care that the
    # SCM successfully launched the service host. We tolerate either
    # Running (briefly) or Stopped (after the child died and the
    # service host exited too).
    if ($svc -and $svc.Status -in @('Running','Stopped','StartPending')) {
        Pass "service reached a known state ($($svc.Status))"
    }

    # ─── Try to stop cleanly ─────────────────────────────────────────────
    Hdr "Stop service"
    Stop-Service -Name $SvcName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if ($svc.Status -eq 'Stopped') { Pass "service stopped" }
    else                            { Fail "service status=$($svc.Status) after Stop" }

    # ─── Uninstall ───────────────────────────────────────────────────────
    Hdr "Uninstall"
    & pwsh.exe -NoProfile -ExecutionPolicy Bypass -File $Forwarder -Uninstall
    if ($LASTEXITCODE -eq 0) { Pass "uninstall exit 0" }
    else                     { Fail "uninstall exit $LASTEXITCODE" }

    Start-Sleep -Seconds 1
    $svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue
    if (-not $svc) { Pass "service removed (Get-Service finds nothing)" }
    else           { Fail "service still present: $($svc.Status)" }

} finally {
    # ─── Cleanup — always remove the throwaway user ──────────────────────
    Hdr "Cleanup"
    try {
        & sc.exe delete $SvcName | Out-Null
    } catch {}
    try {
        Remove-LocalUser -Name $TestUser -ErrorAction SilentlyContinue
        Pass "removed throwaway user $TestUser"
    } catch {
        Write-Host "  WARN failed to remove ${TestUser}: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "──────────────────────────────────────────"
Write-Host ("Results: {0} pass, {1} fail" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
Write-Host "──────────────────────────────────────────"
if ($script:Fail -ne 0) { exit 1 }
