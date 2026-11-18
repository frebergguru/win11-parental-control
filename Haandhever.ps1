#Requires -Version 5.1
<#
    Haandhever.ps1 (håndhever)

    Kjøres som SYSTEM av den planlagte oppgaven "Foreldrekontroll" hvert minutt,
    ved oppstart og ved hver pålogging. Den:
      * teller skjermtid for barnekontoene (bare når økten er aktiv og ulåst),
      * varsler barnet før tiden er ute og logger ut når tiden er brukt opp
        eller klokka er utenfor tillatt tidsrom,
      * setter filter-DNS tilbake på nettverkskortene hvis noen har endret den.

    Filen ligger i C:\Program Files\Foreldrekontroll, der bare administratorer kan skrive.
#>

$ErrorActionPreference = 'Continue'
$Base       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Base 'config.json'
$UsagePath  = Join-Path $Base 'usage.json'
$LogPath    = Join-Path $Base 'haandhever.log'

function Write-PcLog([string]$Text) {
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1MB)) {
            Move-Item -LiteralPath $LogPath -Destination "$LogPath.old" -Force
        }
        Add-Content -LiteralPath $LogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $Text) -Encoding UTF8
    } catch { }
}

function ConvertTo-PcSpan([string]$Text) {
    # "HH:mm" til TimeSpan. Tåler "24:00" (TimeSpan.Parse tolker det som 24 dager).
    $p = $Text.Split(':')
    return New-Object TimeSpan ([int]$p[0]), ([int]$p[1]), 0
}

# Bare én kjøring om gangen (minutt-trigger og påloggings-trigger kan treffe samtidig).
$mutex = New-Object System.Threading.Mutex($false, 'Global\ForeldrekontrollHaandhever')
try { if (-not $mutex.WaitOne(30000)) { exit 0 } } catch [System.Threading.AbandonedMutexException] { }

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { exit 0 }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    # ------------------------------------------------------------------ DNS
    if ($cfg.Web -and $cfg.Web.Enabled -and $cfg.Web.Servers) {
        $want = @($cfg.Web.Servers)
        foreach ($nic in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
            try {
                $have = @(Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ErrorAction Stop |
                          ForEach-Object { $_.ServerAddresses }) | Where-Object { $_ }
                $diff = Compare-Object -ReferenceObject $want -DifferenceObject @($have)
                if ($diff) {
                    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $want -ErrorAction Stop
                    Write-PcLog "DNS satt tilbake på '$($nic.Name)'"
                }
            } catch { }
        }
    }

    # ----------------------------------------------------------- Skjermtid
    if (-not ($cfg.ScreenTime -and $cfg.ScreenTime.Enabled)) { exit 0 }
    $children = @($cfg.Children)
    if ($children.Count -eq 0) { exit 0 }

    if (-not ('PcWts' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PcWts {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WTS_SESSION_INFO { public int SessionId; public string Station; public int State; }
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WTSEnumerateSessionsW(IntPtr h, int reserved, int version, out IntPtr info, out int count);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WTSQuerySessionInformationW(IntPtr h, int id, int cls, out IntPtr buf, out int bytes);
    [DllImport("wtsapi32.dll")]
    static extern void WTSFreeMemory(IntPtr p);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    public static extern bool WTSLogoffSession(IntPtr h, int id, bool wait);
    [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool WTSSendMessageW(IntPtr h, int id, string title, int titleLen, string msg, int msgLen,
                                       int style, int timeout, out int resp, bool wait);
    static string Query(int id, int cls) {
        IntPtr b; int n;
        if (!WTSQuerySessionInformationW(IntPtr.Zero, id, cls, out b, out n)) return "";
        string r = Marshal.PtrToStringUni(b); WTSFreeMemory(b); return r;
    }
    // "id<TAB>domene<TAB>bruker<TAB>tilstand" for hver økt med en bruker. Tilstand 0 = aktiv.
    public static string[] Sessions() {
        var res = new List<string>(); IntPtr p; int n;
        if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out p, out n)) return res.ToArray();
        int size = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
        for (int i = 0; i < n; i++) {
            var s = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(p.ToInt64() + (long)i * size), typeof(WTS_SESSION_INFO));
            string user = Query(s.SessionId, 5);
            if (user.Length > 0) res.Add(s.SessionId + "\t" + Query(s.SessionId, 7) + "\t" + user + "\t" + s.State);
        }
        WTSFreeMemory(p); return res.ToArray();
    }
    public static void Send(int id, string title, string msg, int timeoutSec) {
        int r; WTSSendMessageW(IntPtr.Zero, id, title, title.Length * 2, msg, msg.Length * 2, 0x40, timeoutSec, out r, false);
    }
}
'@
    }

    $now   = Get-Date
    $today = $now.ToString('yyyy-MM-dd')

    # Brukstall for i dag
    $usage = @{}
    if (Test-Path -LiteralPath $UsagePath) {
        try {
            $u = Get-Content -LiteralPath $UsagePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($u.Date -eq $today) {
                foreach ($p in $u.Users.PSObject.Properties) {
                    $usage[$p.Name] = @{
                        Minutes   = [double]$p.Value.Minutes
                        Last      = [string]$p.Value.Last
                        Warned    = @($p.Value.Warned | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
                        ExpiredAt = [string]$p.Value.ExpiredAt
                    }
                }
            }
        } catch { }
    }

    $bonus = 0
    if ($cfg.Bonus -and $cfg.Bonus.Date -eq $today) { $bonus = [int]$cfg.Bonus.Minutes }

    $rule = $cfg.ScreenTime.Days.($now.DayOfWeek.ToString())
    $warnAt = @(10, 5, 1)
    if ($cfg.ScreenTime.Warn) { $warnAt = @($cfg.ScreenTime.Warn | ForEach-Object { [int]$_ }) }

    $locked = @{}
    foreach ($lp in @(Get-Process -Name LogonUI -ErrorAction SilentlyContinue)) { $locked[[int]$lp.SessionId] = $true }

    $sessions = @()
    foreach ($line in [PcWts]::Sessions()) {
        $f = $line.Split("`t")
        $sessions += [pscustomobject]@{ Id = [int]$f[0]; Account = "$($f[1])\$($f[2])"; User = $f[2]; State = [int]$f[3] }
    }

    foreach ($child in $children) {
        $sid = [string]$child.Sid
        try {
            $acct = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value
        } catch { continue }
        $mine = @($sessions | Where-Object { $_.Account -ieq $acct })
        if (-not $usage.ContainsKey($sid)) { $usage[$sid] = @{ Minutes = 0.0; Last = ''; Warned = @(); ExpiredAt = '' } }
        $st = $usage[$sid]
        if ($mine.Count -eq 0) { $st.Last = ''; continue }

        # Tell tid bare når økten er aktiv og ikke låst.
        $active = @($mine | Where-Object { $_.State -eq 0 -and -not $locked.ContainsKey($_.Id) })
        if ($active.Count -gt 0) {
            if ($st.Last) {
                $delta = ($now - [datetime]::new([long]$st.Last)).TotalMinutes
                if ($delta -gt 0 -and $delta -le 3) { $st.Minutes += $delta }
            }
            $st.Last = [string]$now.Ticks
        } else {
            $st.Last = ''
        }

        # Hvor mye tid er igjen?
        $remaining = [double]::PositiveInfinity
        $reason = ''
        if ($null -eq $rule) {
            # Ingen regel for dagen: ingen grense.
        } else {
            $limit = [int]$rule.Limit
            $start = ConvertTo-PcSpan $rule.Start
            $end   = (ConvertTo-PcSpan $rule.End).Add([TimeSpan]::FromMinutes($bonus))
            $tod   = $now.TimeOfDay
            if ($limit -eq 0 -and $bonus -le 0) {
                $remaining = 0; $reason = 'I dag er det ingen skjermtid.'
            } elseif ($tod -lt $start -or $tod -ge $end) {
                $remaining = 0; $reason = "Skjermtid er bare mellom $($rule.Start) og $($rule.End)."
            } else {
                $remaining = ($end - $tod).TotalMinutes
                $reason = 'Tillatt tidsrom er slutt for i dag.'
                if ($limit -ge 0) {
                    $left = $limit + $bonus - $st.Minutes
                    if ($left -lt $remaining) { $remaining = $left; $reason = 'Skjermtiden for i dag er brukt opp.' }
                }
            }
        }

        if ($remaining -le 0) {
            if (-not $st.ExpiredAt) {
                $st.ExpiredAt = [string]$now.Ticks
                foreach ($s in $mine) { [PcWts]::Send($s.Id, 'Skjermtid', "$reason`n`nDu blir logget ut om 1 minutt. Lagre det du holder på med.", 55) }
                Write-PcLog "$acct : tiden er ute, varslet"
            } elseif (($now - [datetime]::new([long]$st.ExpiredAt)).TotalSeconds -ge 50) {
                foreach ($s in $mine) {
                    [PcWts]::Send($s.Id, 'Skjermtid', $reason, 5)
                    [void][PcWts]::WTSLogoffSession([IntPtr]::Zero, $s.Id, $false)
                }
                Write-PcLog "$acct : logget ut ($reason)"
            }
        } else {
            $st.ExpiredAt = ''
            if ($active.Count -gt 0) {
                foreach ($w in ($warnAt | Sort-Object -Descending)) {
                    if ($remaining -le $w -and $st.Warned -notcontains $w) {
                        $mins = [math]::Max(1, [math]::Ceiling($remaining))
                        foreach ($s in $active) { [PcWts]::Send($s.Id, 'Skjermtid', "Du har $mins minutt(er) igjen av skjermtiden.", 30) }
                        $st.Warned = @($st.Warned) + @($warnAt | Where-Object { $_ -ge $remaining })
                        break
                    }
                }
                # Nye ekstra minutter: varsle på nytt neste gang.
                $st.Warned = @($st.Warned | Where-Object { $_ -ge $remaining })
            }
        }
    }

    $out = @{ Date = $today; Users = $usage }
    $out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $UsagePath -Encoding UTF8
} catch {
    Write-PcLog "Feil: $($_.Exception.Message)"
} finally {
    try { $mutex.ReleaseMutex() } catch { }
}
