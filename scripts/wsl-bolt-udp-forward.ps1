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
#   .\wsl-bolt-udp-forward.ps1 -Install      # install as a true Windows Service
#                                            # (sc.exe + a generated C# host).
#                                            # Prompts for your password — the
#                                            # service runs under YOUR account
#                                            # so it can see your WSL distro.
#                                            # MUST run from an elevated shell.
#   .\wsl-bolt-udp-forward.ps1 -Uninstall    # stop + remove the service (elevated)
#   .\wsl-bolt-udp-forward.ps1 -Status       # show resolved IP + service state
#
# Options:
#   -Distro <name>   WSL distro (default: the WSL default distribution)
#   -Ports <list>    UDP ports to relay (default: 7373,9)
#   -Firewall        With -Install, also add inbound Defender allow rules
#
# Why a true service + your account:
#   WSL distros are registered per-user (HKCU\Software\Microsoft\Windows\
#   CurrentVersion\Lxss). A service running as LocalSystem can launch
#   wsl.exe but won't see *your* distros. Running the service under your
#   account fixes this. New-Service -Credential stores the password
#   securely via LSA Secrets; you never see it again.
#
# Exit:
#   0  - clean shutdown / action completed
#   1  - bad arguments / not elevated
#   2  - a listen socket could not bind (port already in use?)
#   3  - WSL distro never became resolvable
#   4  - C# compile / sc.exe install failure

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]      [switch]$Run,
    [Parameter(ParameterSetName = 'Install')]  [switch]$Install,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Status')]   [switch]$Status,
    [string]$Distro,
    [int[]]$Ports = @(7373, 9),
    [switch]$Firewall,
    # Optional: pre-built PSCredential for non-interactive install (CI).
    # When omitted, -Install prompts via Get-Credential as usual.
    [System.Management.Automation.PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'
$script:ServiceName  = 'BurbleBoltUdpForward'
$script:ServiceDisp  = 'Burble Bolt UDP forwarder'
$script:ServiceDesc  = 'Forwards Bolt udp/7373+9 from the Windows host into the WSL2 NAT-mode Burble server (no mirrored networking required).'
$script:InstallDir   = Join-Path $env:ProgramData 'BurbleBoltFwd'
$script:ServiceExe   = Join-Path $script:InstallDir 'BurbleBoltService.exe'
$script:ServiceArgs  = Join-Path $script:InstallDir 'service-args.txt'
$script:LogDir       = $script:InstallDir
$script:LogFile      = Join-Path $script:LogDir 'relay.log'

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

function Assert-Elevated {
    param([string]$Action = 'this operation')
    $elevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
    if (-not $elevated) {
        Write-Error "Elevated shell required for $Action. Re-run PowerShell as Administrator."
        exit 1
    }
}

# C# source for a minimal Windows Service host. Compiled on demand by
# Compile-ServiceHost using the in-box .NET Framework csc.exe (always
# present on every Windows 10/11). The service has no .NET Core / Roslyn /
# NSSM dependency.
$script:ServiceSource = @'
using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;

namespace BurbleBoltForward {
    public class Service : ServiceBase {
        private Process _child;
        public Service() {
            this.ServiceName  = "BurbleBoltUdpForward";
            this.CanStop      = true;
            this.CanShutdown  = true;
            this.AutoLog      = true;
        }
        protected override void OnStart(string[] args) {
            try {
                string dir     = Path.GetDirectoryName(typeof(Service).Assembly.Location);
                string argFile = Path.Combine(dir, "service-args.txt");
                string argLine = File.ReadAllText(argFile).Trim();
                var psi = new ProcessStartInfo {
                    FileName        = "powershell.exe",
                    Arguments       = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command \"" + argLine.Replace("\"", "\\\"") + "\"",
                    UseShellExecute = false,
                    CreateNoWindow  = true,
                };
                _child = Process.Start(psi);
            } catch (Exception ex) {
                try { EventLog.WriteEntry("BurbleBoltUdpForward",
                    "OnStart failed: " + ex.ToString(), EventLogEntryType.Error); } catch {}
                throw;
            }
        }
        protected override void OnStop() {
            try { if (_child != null && !_child.HasExited) {
                _child.Kill(); _child.WaitForExit(5000);
            } } catch {}
        }
        protected override void OnShutdown() { OnStop(); }
        public static void Main(string[] args) { ServiceBase.Run(new Service()); }
    }
}
'@

function Compile-ServiceHost {
    # Use the .NET Framework 4 in-box C# compiler — it's always at this
    # path on a stock Windows install, no extra tooling needed.
    $cscPaths = @(
        "$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $csc = $cscPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) {
        Write-Error "Could not find csc.exe under %WINDIR%\Microsoft.NET\Framework*\v4.0.30319\. .NET Framework 4 not installed?"
        exit 4
    }

    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    $src = Join-Path $script:InstallDir 'BurbleBoltService.cs'
    Set-Content -Path $src -Value $script:ServiceSource -Encoding ASCII

    & $csc /nologo /target:exe /optimize+ /platform:anycpu `
        /reference:System.ServiceProcess.dll `
        /out:"$($script:ServiceExe)" "$src" 2>&1 | ForEach-Object { Write-Host "  csc: $_" }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $script:ServiceExe)) {
        Write-Error "csc.exe failed to produce $($script:ServiceExe)."
        exit 4
    }
    Write-Host "[bolt-fwd] compiled service host: $($script:ServiceExe)"
}

function Install-Service {
    param(
        [string]$Distro,
        [int[]]$Ports,
        [switch]$Firewall,
        [System.Management.Automation.PSCredential]$Credential
    )
    Assert-Elevated -Action '-Install (creates a Windows Service)'
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }

    # If an old install exists (either the scheduled-task variant from a
    # prior version, or a previous service install), remove it first.
    if (Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue) {
        Write-Host "[bolt-fwd] existing service found — removing before reinstall."
        Uninstall-Service -Quiet
    }
    Unregister-ScheduledTask -TaskName $script:ServiceName -Confirm:$false -ErrorAction SilentlyContinue

    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null

    # Stash the script and its arguments next to the service exe so the
    # service host can find them across reboots / script-tree moves.
    $deployedScript = Join-Path $script:InstallDir 'wsl-bolt-udp-forward.ps1'
    Copy-Item -Force -Path $self -Destination $deployedScript

    $argInner = "& '$deployedScript' -Run"
    if ($Distro) { $argInner += " -Distro '$Distro'" }
    if ($Ports)  { $argInner += " -Ports $($Ports -join ',')" }
    Set-Content -Path $script:ServiceArgs -Value $argInner -Encoding ASCII

    Compile-ServiceHost

    if ($Credential) {
        $cred = $Credential
        Write-Host "[bolt-fwd] Using pre-supplied credential for $($cred.UserName) (non-interactive install)."
    } else {
        Write-Host "[bolt-fwd] WSL distros are per-user. The service needs to run under YOUR account"
        Write-Host "           so it can launch wsl.exe and see your distro. New-Service stores the"
        Write-Host "           password securely via LSA Secrets — you only enter it once."
        $cred = Get-Credential -UserName "$env:USERDOMAIN\$env:USERNAME" `
            -Message "Password for $env:USERDOMAIN\$env:USERNAME (so the service can launch wsl.exe as you)"
        if (-not $cred) { Write-Error "Cancelled — no credential supplied."; exit 1 }
    }

    # Grant the service user Modify on the install dir — it lives under
    # %ProgramData% which is admin-only by default, but the service runs
    # as a normal user and needs to append to relay.log.
    try {
        $acl  = Get-Acl $script:InstallDir
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $cred.UserName, 'Modify',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -Path $script:InstallDir -AclObject $acl
    } catch {
        Write-Warning "Could not adjust ACL on $($script:InstallDir): $($_.Exception.Message)"
    }

    # Grant the account 'Log on as a service' right; New-Service does this
    # automatically when -Credential is provided on recent Windows, but be
    # explicit so older builds don't choke.
    New-Service -Name $script:ServiceName `
                -BinaryPathName "`"$($script:ServiceExe)`"" `
                -DisplayName $script:ServiceDisp `
                -Description $script:ServiceDesc `
                -StartupType Automatic `
                -Credential $cred | Out-Null

    # Recover automatically on crash: restart after 5s, 5s, 30s.
    & sc.exe failure $script:ServiceName reset= 86400 actions= restart/5000/restart/5000/restart/30000 | Out-Null

    Start-Service -Name $script:ServiceName
    Write-Host "[bolt-fwd] service '$($script:ServiceName)' installed and started."
    Write-Host "           Log: $($script:LogFile)"
    Write-Host "           Manage: sc.exe query/start/stop/delete $($script:ServiceName)"

    if ($Firewall) {
        foreach ($p in $Ports) {
            New-NetFirewallRule -DisplayName "Burble Bolt (WSL2 NAT fwd) udp/$p" `
                -Direction Inbound -Protocol UDP -LocalPort $p -Action Allow `
                -Profile Private,Domain -ErrorAction SilentlyContinue | Out-Null
        }
        Write-Host "[bolt-fwd] firewall allow rules added for udp/$($Ports -join ',')."
    }
}

function Uninstall-Service {
    param([switch]$Quiet)
    if (-not $Quiet) { Assert-Elevated -Action '-Uninstall (removes a Windows Service)' }
    $svc = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $script:ServiceName -Force -ErrorAction SilentlyContinue
        }
        & sc.exe delete $script:ServiceName | Out-Null
        if (-not $Quiet) { Write-Host "[bolt-fwd] service '$($script:ServiceName)' removed." }
    } elseif (-not $Quiet) {
        Write-Host "[bolt-fwd] service '$($script:ServiceName)' was not installed."
    }
    # Also clear any legacy scheduled-task install from an older version.
    Unregister-ScheduledTask -TaskName $script:ServiceName -Confirm:$false -ErrorAction SilentlyContinue
}

switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-Service -Distro $Distro -Ports $Ports -Firewall:$Firewall -Credential $Credential }
    'Uninstall' { Uninstall-Service }
    'Status' {
        $ip  = Resolve-WslIp -Distro $Distro
        $svc = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
        Write-Host "WSL target IP : $(if ($ip) { $ip } else { '(unresolved - is the distro running?)' })"
        Write-Host "Service       : $(if ($svc) { "$($svc.Status) ($($script:ServiceName))" } else { 'not installed' })"
        Write-Host "Service exe   : $(if (Test-Path $script:ServiceExe) { $script:ServiceExe } else { '(not installed)' })"
        Write-Host "Relayed ports : udp/$($Ports -join ',')"
        Write-Host "Log file      : $script:LogFile"
    }
    default { Invoke-Relay -Distro $Distro -Ports $Ports }
}
