# SPDX-License-Identifier: PMPL-1.0-or-later
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
#   .\wsl-bolt-udp-forward.ps1 -Run          # run the relay (foreground)
#   .\wsl-bolt-udp-forward.ps1 -Install      # register a logon scheduled task
#   .\wsl-bolt-udp-forward.ps1 -Uninstall    # remove the scheduled task
#   .\wsl-bolt-udp-forward.ps1 -Status       # show resolved IP + task state
#
# Options:
#   -Distro <name>   WSL distro (default: the WSL default distribution)
#   -Ports <list>    UDP ports to relay (default: 7373,9)
#   -Firewall        With -Install, also add inbound Defender allow rules
#                    (requires an elevated shell; skipped with a warning if
#                    not elevated)
#
# Exit:
#   0  - clean shutdown (Ctrl-C) / action completed
#   1  - bad arguments
#   2  - a listen socket could not bind (port already in use?)
#   3  - WSL distro never became resolvable

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]      [switch]$Run,
    [Parameter(ParameterSetName = 'Install')]  [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Status')]   [switch]$Status,
    [string]$Distro,
    [int[]]$Ports = @(7373, 9),
    [switch]$Firewall
)

$ErrorActionPreference = 'Stop'
$script:TaskName = 'BurbleBoltUdpForward'

function Resolve-WslIp {
    param([string]$Distro)
    $args = @()
    if ($Distro) { $args += @('-d', $Distro) }
    $args += @('--', 'hostname', '-I')
    try {
        $out = (& wsl.exe @args) 2>$null
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
        Write-Error "WSL distro never became resolvable (hostname -I empty)."
        exit 3
    }
    Write-Host "[bolt-fwd] WSL target: $wslIp ; relaying udp/$($Ports -join ',')"

    $listeners = @{}   # port -> Socket bound on 0.0.0.0:port
    foreach ($p in $Ports) {
        $s = New-Object System.Net.Sockets.Socket(
            [System.Net.Sockets.AddressFamily]::InterNetwork,
            [System.Net.Sockets.SocketType]::Dgram,
            [System.Net.Sockets.ProtocolType]::Udp)
        try {
            $s.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $p)))
        } catch {
            Write-Error "Could not bind udp/${p}: $($_.Exception.Message)"
            exit 2
        }
        $listeners[$p] = $s
    }

    # Per (port + client) ephemeral upstream socket toward WSL.
    # key = "port|clientIp:clientPort" -> @{ Sock; Client; Port; Last }
    $ups = @{}
    $buf = New-Object byte[] 65535
    $lastResolve = Get-Date

    Write-Host "[bolt-fwd] running. Ctrl-C to stop."
    while ($true) {
        # Re-resolve the WSL IP every 15s; rebuild upstreams on change.
        if (((Get-Date) - $lastResolve).TotalSeconds -ge 15) {
            $lastResolve = Get-Date
            $cur = Resolve-WslIp -Distro $Distro
            if ($cur -and $cur -ne $wslIp) {
                Write-Host "[bolt-fwd] WSL IP changed $wslIp -> $cur ; resetting upstreams"
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

function Install-Task {
    param([string]$Distro, [int[]]$Ports, [switch]$Firewall)
    $self = $MyInvocation.MyCommand.Path
    if (-not $self) { $self = $PSCommandPath }
    $argline = "-NoProfile -ExecutionPolicy Bypass -File `"$self`" -Run"
    if ($Distro) { $argline += " -Distro `"$Distro`"" }
    if ($Ports)  { $argline += " -Ports $($Ports -join ',')" }

    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argline
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                 -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
        -Settings $set -Description 'Burble Bolt UDP forwarder (WSL2 NAT, no mirrored networking)' -Force | Out-Null
    Write-Host "[bolt-fwd] scheduled task '$($script:TaskName)' registered (runs at logon)."

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

switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-Task -Distro $Distro -Ports $Ports -Firewall:$Firewall }
    'Uninstall' {
        Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "[bolt-fwd] scheduled task removed."
    }
    'Status' {
        $ip = Resolve-WslIp -Distro $Distro
        Write-Host "WSL target IP : $(if ($ip) { $ip } else { '(unresolved - is the distro running?)' })"
        $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        Write-Host "Scheduled task: $(if ($t) { $t.State } else { 'not installed' })"
        Write-Host "Relayed ports : udp/$($Ports -join ',')"
    }
    default { Invoke-Relay -Distro $Distro -Ports $Ports }
}
