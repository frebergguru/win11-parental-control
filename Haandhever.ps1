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
$WifiStatePath = Join-Path $Base 'wifi-sperret.json'
$DnsStatePath  = Join-Path $Base 'dns-reparert.json'

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

# Lav prioritet, så spill og andre programmer aldri merker håndheveren.
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal } catch { }

# Bare én kjøring om gangen: alle utløserne tilhører samme oppgave, og oppgaven har
# MultipleInstancesPolicy IgnoreNew. (Ingen navngitt mutex: en vanlig bruker kunne lage og
# holde den og dermed stoppe håndheveren.)

try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { exit 0 }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

    # ------------------------------------------------------------------ DNS
    # Sammenligner per adressefamilie med normaliserte adresser, og endrer bare når noe faktisk
    # er annerledes. Å sette DNS tømmer DNS-hurtigbufferen og skal ikke skje hvert minutt.
    function ConvertTo-PcIp([string]$a) { try { return ([System.Net.IPAddress]::Parse($a)).ToString() } catch { return $a } }
    # Hvert femte minutt holder, så håndheveren bruker minst mulig maskinkraft.
    if ($cfg.Web -and $cfg.Web.Enabled -and $cfg.Web.Servers -and ((Get-Date).Minute % 5 -eq 0)) {
        $wantAll = @($cfg.Web.Servers | ForEach-Object { ConvertTo-PcIp $_ })
        $dnsState = @{}
        if (Test-Path -LiteralPath $DnsStatePath) {
            try { (Get-Content -LiteralPath $DnsStatePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $dnsState[$_.Name] = [long]$_.Value } } catch { }
        }
        $changed = $false
        foreach ($nic in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
            $key = [string]$nic.ifIndex
            # Samme kort høyst én gang i timen, så en innstilling som ikke "fester seg" aldri gir gjentatte nettverkshikk.
            if ($dnsState.ContainsKey($key) -and ((Get-Date) - [datetime]::new($dnsState[$key])).TotalMinutes -lt 60) { continue }
            $v6Bound = $false
            try { $v6Bound = [bool](Get-NetAdapterBinding -Name $nic.Name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled } catch { }
            $wrong = $false
            foreach ($entry in @(Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue)) {
                $isV6 = ($entry.AddressFamily -eq 23)
                if ($isV6 -and -not $v6Bound) { continue }
                $want = @($wantAll | Where-Object { ($_ -like '*:*') -eq $isV6 })
                if ($want.Count -eq 0) { continue }
                $have = @($entry.ServerAddresses | Where-Object { $_ } | ForEach-Object { ConvertTo-PcIp $_ })
                if (Compare-Object -ReferenceObject $want -DifferenceObject @($have) -SyncWindow 0) { $wrong = $true }
            }
            if ($wrong) {
                try {
                    $list = @($wantAll | Where-Object { $v6Bound -or $_ -notlike '*:*' })
                    Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $list -ErrorAction Stop
                    Write-PcLog "DNS satt tilbake på '$($nic.Name)'"
                } catch { Write-PcLog "DNS på '$($nic.Name)' feilet: $($_.Exception.Message)" }
                $dnsState[$key] = (Get-Date).Ticks; $changed = $true
            }
        }
        if ($changed) { $dnsState | ConvertTo-Json | Set-Content -LiteralPath $DnsStatePath -Encoding UTF8 }
    }

    # ------------------------------------- Alltid sperrede Wi-Fi-navn (Anlegg1, Anlegg2, ...)
    # Skriptet sperrer navn + 1 til PrefixMax på forhånd. Her sperres høyere tall som dukker opp.
    $prefixes = @($cfg.Wifi.BlockPrefixes | Where-Object { $_ })
    # Hvert femte minutt holder (leser bare listen Windows allerede har, starter ikke et nytt søk).
    if ($cfg.Wifi -and $cfg.Wifi.Mode -ne 'allow' -and $prefixes.Count -gt 0 -and ((Get-Date).Minute % 5 -eq 0)) {
        try {
            $netsh = "$env:windir\System32\netsh.exe"
            $known = @($cfg.Wifi.AppliedPrefixSsids) + @($cfg.Wifi.Ssids)
            $state = @()
            # ForEach-Object pakker ut lista (ConvertFrom-Json i PowerShell 5.1 gir hele lista som ett objekt).
            if (Test-Path -LiteralPath $WifiStatePath) { $state = @(Get-Content -LiteralPath $WifiStatePath -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) }
            $out = (& $netsh wlan show networks mode=ssid) -join "`n"
            $added = $false
            foreach ($m in [regex]::Matches($out, '(?m)^SSID \d+\s*:\s*(.*?)\s*$')) {
                $ssid = $m.Groups[1].Value
                # Wi-Fi-navn skiller mellom store og små bokstaver, så sammenligningen må gjøre det også.
                if (-not $ssid -or $known -ccontains $ssid -or $state -ccontains $ssid) { continue }
                foreach ($p in $prefixes) {
                    if ($ssid -match ('^' + [regex]::Escape($p) + '\d+$')) {
                        $psi = New-Object Diagnostics.ProcessStartInfo $netsh, "wlan add filter permission=block ssid=`"$ssid`" networktype=infrastructure"
                        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
                        $proc = [Diagnostics.Process]::Start($psi); $proc.WaitForExit()
                        $state += $ssid; $added = $true
                        Write-PcLog "Wi-Fi '$ssid' sperret automatisk"
                        break
                    }
                }
            }
            if ($added) { ConvertTo-Json -InputObject @($state) | Set-Content -LiteralPath $WifiStatePath -Encoding UTF8 }
        } catch { Write-PcLog "Wi-Fi-sjekk feilet: $($_.Exception.Message)" }
    }

    # ----------------------------------------------------------- Skjermtid
    if (-not ($cfg.ScreenTime -and $cfg.ScreenTime.Enabled)) { exit 0 }
    $children = @($cfg.Children)
    if ($children.Count -eq 0) { exit 0 }

    # C#-koden kompileres bare én gang til PcWts3.dll; senere kjøringer laster bare filen
    # (å kompilere hvert minutt ville gitt et lite CPU-hopp hvert minutt).
    $dll = Join-Path $Base 'PcWts3.dll'
    if (-not ('PcWts' -as [type]) -and (Test-Path -LiteralPath $dll)) {
        try { Add-Type -LiteralPath $dll } catch { Remove-Item -LiteralPath $dll -Force -ErrorAction SilentlyContinue }
    }
    if (-not ('PcWts' -as [type])) {
        $src = @'
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
    // 1 = låst, 0 = ulåst, -1 = ukjent. WTSINFOEXW: Level (byte 0), så unionen på byte 8 (den
    // inneholder LARGE_INTEGER og er derfor 8-justert): SessionId 8, SessionState 12, SessionFlags 16.
    public static int Locked(int id) {
        IntPtr b; int n;
        if (!WTSQuerySessionInformationW(IntPtr.Zero, id, 25, out b, out n)) return -1;
        try {
            if (n < 20 || Marshal.ReadInt32(b, 0) != 1) return -1;
            int flags = Marshal.ReadInt32(b, 16);
            if (flags == 0) return 1;
            if (flags == 1) return 0;
            return -1;
        } finally { WTSFreeMemory(b); }
    }
    public static void Send(int id, string title, string msg, int timeoutSec) {
        int r; WTSSendMessageW(IntPtr.Zero, id, title, title.Length * 2, msg, msg.Length * 2, 0x40, timeoutSec, out r, false);
    }
}
'@
        try { Add-Type -TypeDefinition $src -OutputAssembly $dll -OutputType Library } catch { }
        if (-not ('PcWts' -as [type])) {
            if (Test-Path -LiteralPath $dll) { Add-Type -LiteralPath $dll } else { Add-Type -TypeDefinition $src }
        }
    }

    $now   = Get-Date
    $today = $now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)

    # Meldinger til barnet, på språket foreldrene valgte.
    $M = @{
        nb = @{
            Title   = 'Skjermtid'
            NoTime  = 'I dag er det ingen skjermtid.'
            Window  = 'Skjermtid er bare mellom {0} og {1}.'
            WinEnd  = 'Tillatt tidsrom er slutt for i dag.'
            Used    = 'Skjermtiden for i dag er brukt opp.'
            Logoff1 = 'Du blir logget ut om 1 minutt. Lagre det du holder på med.'
            Left    = 'Du har {0} min igjen av skjermtiden.'
        }
        uk = @{
            Title   = 'Екранний час'
            NoTime  = 'Сьогодні екранного часу немає.'
            Window  = 'Екранний час дозволено лише з {0} до {1}.'
            WinEnd  = 'Дозволений проміжок часу на сьогодні закінчився.'
            Used    = 'Екранний час на сьогодні вичерпано.'
            Logoff1 = 'Через 1 хвилину тебе буде виведено із системи. Збережи все, над чим працюєш.'
            Left    = 'Залишилося {0} хв екранного часу.'
        }
    }
    $L = $M['nb']
    if ($cfg.Language -and $M.ContainsKey([string]$cfg.Language)) { $L = $M[[string]$cfg.Language] }

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
    $warnAt = @(10, 3)
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
        $active = @($mine | Where-Object {
            if ($_.State -ne 0) { return $false }
            $l = [PcWts]::Locked($_.Id)
            if ($l -ge 0) { return ($l -eq 0) }
            return -not $locked.ContainsKey($_.Id)   # reserve: påloggingsskjermen kjører i økten
        })
        if ($active.Count -gt 0) {
            if ($st.Last) {
                $delta = ($now - [datetime]::new([long]$st.Last)).TotalMinutes
                if ($delta -gt 0 -and $delta -le 3) { $st.Minutes += $delta }
                elseif ($delta -gt 3 -and $delta -le 15) { $st.Minutes += 1 }   # forsinket kjøring (travel PC): tell minst ett minutt
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
                $remaining = 0; $reason = $L.NoTime
            } elseif ($tod -lt $start -or $tod -ge $end) {
                $remaining = 0; $reason = $L.Window -f $rule.Start, $rule.End
            } else {
                $remaining = ($end - $tod).TotalMinutes
                $reason = $L.WinEnd
                if ($limit -ge 0) {
                    $left = $limit + $bonus - $st.Minutes
                    if ($left -lt $remaining) { $remaining = $left; $reason = $L.Used }
                }
            }
        }

        if ($remaining -le 0) {
            if (-not $st.ExpiredAt) {
                $st.ExpiredAt = [string]$now.Ticks
                foreach ($s in $mine) { [PcWts]::Send($s.Id, $L.Title, "$reason`n`n$($L.Logoff1)", 55) }
                Write-PcLog "$acct : tiden er ute, varslet"
            } elseif (($now - [datetime]::new([long]$st.ExpiredAt)).TotalSeconds -ge 50) {
                foreach ($s in $mine) {
                    [PcWts]::Send($s.Id, $L.Title, $reason, 5)
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
                        foreach ($s in $active) { [PcWts]::Send($s.Id, $L.Title, ($L.Left -f $mins), 30) }
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
}
