# SPDX-License-Identifier: MPL-2.0
#
# wsl-bolt-udp-forward.ps1 - forward inbound Bolt UDP from the Windows host
# into a WSL2 distro running the Burble server, WITHOUT WSL2 mirrored
# networking.
#
# Why this exists:
#   Under WSL2's default NAT mode the distro sits behind an internal
#   vEthernet adapter, so inbound UDP arriving on the Windows host LAN IP
#   never reaches Burble.Bolt.Listener (udp/7373, plus udp/9 WoL-compat).
#   The historical fix was networkingMode=mirrored, but mirrored mode plus
#   its companions (dnsTunneling/autoProxy/hostAddressLoopback) causes
#   recurring Wsl/Service/E_UNEXPECTED catastrophic failures and vNIC flap
#   on Windows 11 24H2 / Insider builds. This forwarder removes the need
#   for mirrored mode entirely: keep WSL on default NAT and relay the two
#   Bolt UDP ports at the host. netsh portproxy is TCP-only and cannot be
#   used for this; this is a real userspace UDP relay.
#
# It is a bidirectional relay (per-client ephemeral upstream socket, idle
# expiry) so QUIC/ack return datagrams route back to the original sender,
# not just fire-and-forget cold pokes. The WSL NAT IP changes per boot, so
# the target is re-resolved periodically and sockets rebuilt on change.
#
# Usage:
#   .\wsl-bolt-udp-forward.ps1 -Run          # run the relay (foreground, console)
#   .\wsl-bolt-udp-forward.ps1 -Tray         # run hidden + show a system-tray icon
#   .\wsl-bolt-udp-forward.ps1 -Install      # register a logon scheduled task that
#                                            # launches the relay WINDOWLESS via a
#                                            # VBS shim (no console pops up at logon)
#   .\wsl-bolt-udp-forward.ps1 -Uninstall    # remove scheduled task + VBS shim
#   .\wsl-bolt-udp-forward.ps1 -Status       # show resolved IP + task state
#
# Options:
#   -Distro <name>   WSL distro (default: the WSL default distribution)
#   -Ports <list>    UDP ports to relay (default: 7373,9)
#   -Firewall        With -Install, also add inbound Defender allow rules
#                    (requires an elevated shell; skipped with a warning if
#                    not elevated)
#   -WithTray        With -Install, the scheduled task launches the tray-icon
#                    variant instead of the headless relay. Off by default —
#                    most users want a true background service with no UI.
#
# Exit:
#   0  - clean shutdown (Ctrl-C) / action completed
#   1  - bad arguments
#   2  - a listen socket could not bind (port already in use?)
#   3  - WSL distro never became resolvable

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]      [switch]$Run,
    [Parameter(ParameterSetName = 'Tray')]     [switch]$Tray,
    [Parameter(ParameterSetName = 'Install')]  [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Status')]   [switch]$Status,
    [string]$Distro,
    [int[]]$Ports = @(7373, 9),
    [switch]$Firewall,
    [switch]$WithTray
)

$ErrorActionPreference = 'Stop'
$script:TaskName = 'BurbleBoltUdpForward'
$script:VbsShim   = Join-Path $PSScriptRoot 'wsl-bolt-udp-forward.vbs'
$script:LogDir    = Join-Path $env:LOCALAPPDATA 'BurbleBoltFwd'
$script:LogFile   = Join-Path $script:LogDir 'relay.log'

function Resolve-WslIp {
    param([string]$Distro)
    $wslArgs = @()
    if ($Distro) { $wslArgs += @('-d', $Distro) }
    $wslArgs += @('--', 'hostname', '-I')
    try {
        $out = (& wsl.exe @wslArgs) 2>$null
    } catch { return $null }
    if (-not $out) { return $null }
    foreach ($tok in ($out -split '\s+')) {
        # First IPv4 that is not loopback.
        if ($tok -match '^\d{1,3}(\.\d{1,3}){3}$' -and $tok -ne '127.0.0.1') {
            return $tok
        }
    }
    return $null
}

function Write-Relay {
    # Console + persistent log. The scheduled-task launch path is windowless
    # (no console attached), so Write-Host alone is dropped. Append to a log
    # file so the relay still leaves a trace and -Status can point at it.
    param([string]$Message)
    $stamp = "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $Message"
    try {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
        Add-Content -Path $script:LogFile -Value $stamp
    } catch {}
    try { Write-Host $stamp } catch {}
}

function Wait-WslIp {
    param([string]$Distro, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $ip = Resolve-WslIp -Distro $Distro
        if ($ip) { return $ip }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Invoke-Relay {
    param([string]$Distro, [int[]]$Ports)

    Add-Type -AssemblyName System.Net | Out-Null
    $wslIp = Wait-WslIp -Distro $Distro
    if (-not $wslIp) {
        Write-Relay "ERROR: WSL distro never became resolvable (hostname -I empty)."
        exit 3
    }
    Write-Relay "WSL target: $wslIp ; relaying udp/$($Ports -join ',')"

    $listeners = @{}   # port -> Socket bound on 0.0.0.0:port
    foreach ($p in $Ports) {
        $s = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        try {
            $s.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $p)))
        } catch {
            Write-Relay "ERROR: Could not bind udp/${p}: $($_.Exception.Message)"
            exit 2
        }
        $listeners[$p] = $s
    }

    # Per (port + client) ephemeral upstream socket toward WSL.
    # key = "port|clientIp:clientPort" -> @{ Sock; Client; Port; Last }
    $ups = @{}
    $buf = New-Object byte[] 65535
    $lastResolve = Get-Date

    Write-Relay "running. Ctrl-C to stop."
    while ($true) {
        # Re-resolve the WSL IP every 15s; rebuild upstreams on change.
        if (((Get-Date) - $lastResolve).TotalSeconds -ge 15) {
            $lastResolve = Get-Date
            $cur = Resolve-WslIp -Distro $Distro
            if ($cur -and $cur -ne $wslIp) {
                Write-Relay "WSL IP changed $wslIp -> $cur ; resetting upstreams"
                $wslIp = $cur
                foreach ($u in $ups.Values) { $u.Sock.Close() }
                $ups.Clear()
            }
        }

        $readable = New-Object System.Collections.ArrayList
        foreach ($s in $listeners.Values) { [void]$readable.Add($s) }
        foreach ($u in $ups.Values)       { [void]$readable.Add($u.Sock) }
        [System.Net.Sockets.Socket]::Select($readable, $null, $null, 500000) # 0.5s

        foreach ($sock in $readable) {
            $remote = [System.Net.EndPoint](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0))
            try { $n = $sock.ReceiveFrom($buf, [ref]$remote) } catch { continue }
            if ($n -le 0) { continue }
            $payload = $buf[0..($n - 1)]

            $listenPort = $null
            foreach ($kv in $listeners.GetEnumerator()) {
                if ($kv.Value -eq $sock) { $listenPort = $kv.Key; break }
            }

            if ($null -ne $listenPort) {
                # Inbound from a LAN client -> forward to WSL:listenPort.
                $key = "$listenPort|$($remote.ToString())"
                $u = $ups[$key]
                if (-not $u) {
                    $usock = New-Object System.Net.Sockets.Socket(
                        [System.Net.Sockets.AddressFamily]::InterNetwork,
                        [System.Net.Sockets.SocketType]::Dgram,
                        [System.Net.Sockets.ProtocolType]::Udp)
                    $usock.Connect($wslIp, $listenPort)
                    $u = @{ Sock = $usock; Client = $remote; LPort = $listenPort; Last = (Get-Date) }
                    $ups[$key] = $u
                }
                $u.Last = Get-Date
                [void]$u.Sock.Send($payload, $n, [System.Net.Sockets.SocketFlags]::None)
            } else {
                # Reply from WSL on an upstream socket -> back to its client.
                foreach ($kv in $ups.GetEnumerator()) {
                    if ($kv.Value.Sock -eq $sock) {
                        $u = $kv.Value
                        [void]$listeners[$u.LPort].SendTo(
                            $payload, $n, [System.Net.Sockets.SocketFlags]::None, $u.Client)
                        $u.Last = Get-Date
                        break
                    }
                }
            }
        }

        # Idle-expire upstream sockets (> 30s silent).
        $dead = @()
        foreach ($kv in $ups.GetEnumerator()) {
            if (((Get-Date) - $kv.Value.Last).TotalSeconds -gt 30) { $dead += $kv.Key }
        }
        foreach ($k in $dead) { $ups[$k].Sock.Close(); $ups.Remove($k) }
    }
}

function Write-VbsShim {
    # VBScript launcher: WshShell.Run "...", 0, False truly creates no console
    # window. powershell.exe -WindowStyle Hidden still flashes a console for ~1
    # frame on scheduled-task launch, which is the visible window users see at
    # logon. wscript.exe + this shim avoids it entirely.
    param([string]$PowerShellInvocation)
    New-Item -ItemType Directory -Path (Split-Path $script:VbsShim) -Force | Out-Null
    $escaped = $PowerShellInvocation.Replace('"', '""')
    @"
' GENERATED by wsl-bolt-udp-forward.ps1 -Install. Do not edit.
' Launches the Burble Bolt UDP forwarder without ever showing a console.
Set sh = CreateObject("WScript.Shell")
sh.Run "$escaped", 0, False
"@ | Set-Content -Encoding ASCII -Path $script:VbsShim
}

function Install-Task {
    param([string]$Distro, [int[]]$Ports, [switch]$Firewall, [switch]$WithTray)
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = $PSCommandPath }

    # Build the actual relay command the VBS shim will fire-and-forget. Use
    # -Command (not -File) so `-Ports 7373,9` parses as [int[]] rather than
    # the literal string "7373,9".
    $mode = if ($WithTray) { '-Tray' } else { '-Run' }
    $inner = "& '$self' $mode"
    if ($Distro) { $inner += " -Distro '$Distro'" }
    if ($Ports)  { $inner += " -Ports $($Ports -join ',')" }
    $psInvocation = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$inner`""

    Write-VbsShim -PowerShellInvocation $psInvocation
    Write-Host "[bolt-fwd] wrote VBS shim: $($script:VbsShim)"

    $action  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$($script:VbsShim)`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
                 -Hidden
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Settings $set -Description 'Burble Bolt UDP forwarder (WSL2 NAT, windowless background service)' -Force | Out-Null
    Write-Host "[bolt-fwd] scheduled task '$($script:TaskName)' registered (runs at logon, no window)."
    if ($WithTray) {
        Write-Host "[bolt-fwd] tray-icon mode enabled — look for the Burble Bolt icon in your system tray after next logon."
    } else {
        Write-Host "[bolt-fwd] running as a headless background service. Log: $($script:LogFile)"
    }

    if ($Firewall) {
        $elevated = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltinRole]::Administrator)
        if (-not $elevated) {
            Write-Warning "-Firewall needs an elevated shell; skipping firewall rules. Re-run elevated or add them manually."
        } else {
            foreach ($p in $Ports) {
                New-NetFirewallRule -DisplayName "Burble Bolt (WSL2 NAT fwd) udp/$p" `
                    -Direction Inbound -Protocol UDP -LocalPort $p -Action Allow `
                    -Profile Private,Domain -ErrorAction SilentlyContinue | Out-Null
            }
            Write-Host "[bolt-fwd] firewall allow rules added for udp/$($Ports -join ',')."
        }
    }
}

function Invoke-Tray {
    # Tray-icon mode: spawn the relay as a hidden child process and host a
    # NotifyIcon for visibility/control. Right-click menu: Status / Open log /
    # Restart / Exit. The relay itself logs to $script:LogFile.
    param([string]$Distro, [int[]]$Ports)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    $self = $PSCommandPath

    # The child relay uses Write-Relay (-> $script:LogFile) for its own
    # output, so we don't need to tail its stdout from here.
    $script:RelayProc = $null
    function Start-Relay {
        $argInner = "& '$self' -Run"
        if ($Distro) { $argInner += " -Distro '$Distro'" }
        if ($Ports)  { $argInner += " -Ports $($Ports -join ',')" }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName        = 'powershell.exe'
        $psi.Arguments       = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$argInner`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $script:RelayProc = [System.Diagnostics.Process]::Start($psi)
    }
    Start-Relay

    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon    = [System.Drawing.SystemIcons]::Information
    $icon.Text    = "Burble Bolt UDP forwarder (udp/$($Ports -join ',') -> WSL)"
    $icon.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add("Status",         $null, {
        $ip = Resolve-WslIp -Distro $Distro
        $msg = "WSL target  : $(if ($ip) { $ip } else { '(unresolved)' })`r`nRelayed     : udp/$($Ports -join ',')`r`nRelay PID   : $($script:RelayProc.Id)"
        [System.Windows.Forms.MessageBox]::Show($msg, 'Burble Bolt forwarder')
    })
    [void]$menu.Items.Add("Open log folder",$null, { Start-Process explorer.exe $script:LogDir })
    [void]$menu.Items.Add("Restart relay",  $null, {
        try { $script:RelayProc.Kill() } catch {}
        Start-Relay
        $icon.ShowBalloonTip(2000, 'Burble Bolt', 'Relay restarted', 'Info')
    })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add("Exit",           $null, {
        try { $script:RelayProc.Kill() } catch {}
        $icon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $icon.ContextMenuStrip = $menu
    $icon.ShowBalloonTip(2000, 'Burble Bolt forwarder', "Listening on udp/$($Ports -join ',')", 'Info')

    [System.Windows.Forms.Application]::Run()
}

function Uninstall-Task {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if (Test-Path $script:VbsShim) { Remove-Item -Force $script:VbsShim }
    Write-Host "[bolt-fwd] scheduled task + VBS shim removed."
}

switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-Task -Distro $Distro -Ports $Ports -Firewall:$Firewall -WithTray:$WithTray }
    'Uninstall' { Uninstall-Task }
    'Tray'      { Invoke-Tray -Distro $Distro -Ports $Ports }
    'Status' {
        $ip = Resolve-WslIp -Distro $Distro
        Write-Host "WSL target IP : $(if ($ip) { $ip } else { '(unresolved - is the distro running?)' })"
        $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        Write-Host "Scheduled task: $(if ($t) { $t.State } else { 'not installed' })"
        Write-Host "VBS shim      : $(if (Test-Path $script:VbsShim) { $script:VbsShim } else { '(not installed)' })"
        Write-Host "Relayed ports : udp/$($Ports -join ',')"
        Write-Host "Log file      : $script:LogFile"
    }
    default { Invoke-Relay -Distro $Distro -Ports $Ports }
}
