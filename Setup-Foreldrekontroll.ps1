#Requires -Version 5.1
<#
.SYNOPSIS
    Interaktivt oppsett av foreldrekontroll på Windows 11.

.DESCRIPTION
    Setter opp barnekonto, skjermtid, hvilke apper og spill som er tilgjengelige,
    blokkering av installering, trådløse nettverk, nettfilter for voksensider og
    sperring av VPN og proxy. Bare Windows sine egne verktøy brukes.

    Kjør som administrator (Start-Foreldrekontroll.cmd gjør det for deg).
    Alt kan fjernes igjen fra menyen ("Fjern all foreldrekontroll").
#>
[CmdletBinding()]
param(
    # Bruk lagrede innstillinger på nytt uten meny (for eksempel etter en Windows-oppdatering).
    [switch]$BrukPaaNytt
)

$ErrorActionPreference = 'Stop'

# ============================================================== Konstanter

$InstallDir  = "$env:ProgramFiles\Foreldrekontroll"
$ConfigPath  = "$InstallDir\config.json"
$UsagePath   = "$InstallDir\usage.json"
$TaskName    = 'Foreldrekontroll'
$FwGroup     = 'Foreldrekontroll'
$SidUsers    = 'S-1-5-32-545'
$SidAdmins   = 'S-1-5-32-544'
$SidEveryone = 'S-1-1-0'

$DayNames = [ordered]@{
    Monday = 'Mandag'; Tuesday = 'Tirsdag'; Wednesday = 'Onsdag'; Thursday = 'Torsdag'
    Friday = 'Fredag'; Saturday = 'Lørdag'; Sunday = 'Søndag'
}
$Weekdays = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday')
$Weekend  = @('Saturday', 'Sunday')

$DnsProviders = [ordered]@{
    cleanbrowsing = @{
        Name = 'CleanBrowsing Family'
        Note = 'blokkerer voksensider, proxy- og VPN-sider, tvinger SafeSearch og YouTube begrenset modus'
        V4   = @('185.228.168.168', '185.228.169.168')
        V6   = @('2a0d:2a00:1::', '2a0d:2a00:2::')
        DoH  = 'https://doh.cleanbrowsing.org/doh/family-filter/'
    }
    cloudflare = @{
        Name = 'Cloudflare for Families'
        Note = 'blokkerer voksensider og skadevare (ikke VPN-sider, tvinger ikke SafeSearch)'
        V4   = @('1.1.1.3', '1.0.0.3')
        V6   = @('2606:4700:4700::1113', '2606:4700:4700::1003')
        DoH  = 'https://family.cloudflare-dns.com/dns-query'
    }
}

# Kjente offentlige DNS- og DoH-tjenere som kan brukes til å gå rundt filteret.
$PublicDns = @(
    '8.8.8.8', '8.8.4.4', '1.1.1.1', '1.0.0.1', '1.1.1.2', '1.0.0.2',
    '9.9.9.9', '149.112.112.112', '9.9.9.10', '149.112.112.10', '9.9.9.11', '149.112.112.11',
    '208.67.222.222', '208.67.220.220', '208.67.222.123', '208.67.220.123',
    '94.140.14.14', '94.140.15.15', '94.140.14.15', '94.140.15.16', '94.140.14.140', '94.140.14.141',
    '45.90.28.0/24', '45.90.30.0/24', '76.76.2.0/24', '76.76.10.0/24', '76.76.19.19', '76.223.122.150',
    '194.242.2.2', '194.242.2.3', '194.242.2.4', '194.242.2.5', '194.242.2.9',
    '185.222.222.222', '45.11.45.11', '77.88.8.8', '77.88.8.1', '4.2.2.1', '4.2.2.2', '4.2.2.3',
    '4.2.2.4', '4.2.2.5', '4.2.2.6', '8.26.56.26', '8.20.247.20', '84.200.69.80', '84.200.70.40',
    '156.154.70.1', '156.154.71.1', '64.6.64.6', '64.6.65.6', '185.228.168.9', '185.228.169.9',
    '2001:4860:4860::8888', '2001:4860:4860::8844', '2606:4700:4700::1111', '2606:4700:4700::1001',
    '2606:4700:4700::1112', '2606:4700:4700::1002', '2620:fe::fe', '2620:fe::9', '2620:fe::10',
    '2620:fe::11', '2620:119:35::35', '2620:119:53::53', '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff',
    '2a07:a8c0::/32', '2a07:a8c1::/32', '2a07:e340::2', '2a07:e340::3', '2a07:e340::4'
)

# Mapper under Windows som vanlige brukere kan skrive til (unntak fra "tillat Windows").
$WindowsWritable = @(
    'Tasks', 'Temp', 'tracing', 'Registration\CRMLog', 'debug\WIA', 'PLA\Reports', 'PLA\Rules', 'PLA\Templates',
    'System32\FxsTmp', 'System32\com\dmp', 'System32\Microsoft\Crypto\RSA\MachineKeys',
    'System32\spool\PRINTERS', 'System32\spool\SERVERS', 'System32\spool\drivers\color',
    'System32\Tasks', 'System32\Tasks_Migrated',
    'SysWOW64\FxsTmp', 'SysWOW64\com\dmp', 'SysWOW64\Tasks'
)

# Verktøy barnet aldri får starte (kan brukes til å omgå sperrene).
$ChildDeniedTools = @(
    '%WINDIR%\System32\cmd.exe', '%WINDIR%\SysWOW64\cmd.exe',
    '%WINDIR%\System32\WindowsPowerShell\*', '%WINDIR%\SysWOW64\WindowsPowerShell\*',
    '%PROGRAMFILES%\PowerShell\*',
    '%WINDIR%\regedit.exe', '%WINDIR%\System32\reg.exe', '%WINDIR%\SysWOW64\reg.exe',
    '%WINDIR%\System32\mmc.exe', '%WINDIR%\System32\wscript.exe', '%WINDIR%\System32\cscript.exe',
    '%WINDIR%\SysWOW64\wscript.exe', '%WINDIR%\SysWOW64\cscript.exe',
    '%WINDIR%\System32\mshta.exe', '%WINDIR%\SysWOW64\mshta.exe',
    '%WINDIR%\System32\rasphone.exe', '%WINDIR%\System32\rasdial.exe',
    '%WINDIR%\System32\wsl.exe', '%WINDIR%\System32\bash.exe'
)

$StorePackages = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.StorePurchaseApp')
$XboxPackages  = @('Microsoft.GamingApp', 'Microsoft.XboxApp')

# ============================================================== Hjelpere for inndata

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host "  [X]  $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "       $Text" -ForegroundColor Gray }

function Wait-Key { [void](Read-Host "`nTrykk Enter for å fortsette") }

function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $hint = if ($Default) { '[J/n]' } else { '[j/N]' }
    while ($true) {
        $a = (Read-Host "$Prompt $hint").Trim().ToLower()
        if ($a -eq '') { return $Default }
        if ($a -in @('j', 'ja', 'y', 'yes')) { return $true }
        if ($a -in @('n', 'nei', 'no')) { return $false }
        Write-Warn 'Svar j eller n.'
    }
}

function Read-Text([string]$Prompt, [string]$Default = '') {
    $p = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
    $a = (Read-Host $p).Trim()
    if ($a -eq '') { return $Default }
    return $a
}

function Read-Time([string]$Prompt, [string]$Default) {
    while ($true) {
        $a = Read-Text $Prompt $Default
        if ($a -match '^\d{1,2}$') { $a = "${a}:00" }
        if ($a -match '^(\d{1,2})[:.](\d{2})$') {
            $h = [int]$Matches[1]; $m = [int]$Matches[2]
            if (($h -lt 24 -and $m -lt 60) -or ($h -eq 24 -and $m -eq 0)) { return ('{0:00}:{1:00}' -f $h, $m) }
        }
        Write-Warn 'Skriv klokkeslett som TT:MM, for eksempel 15:30.'
    }
}

function Read-Limit([string]$Prompt, $Default) {
    $d = if ($Default -lt 0) { 'ingen' } else { [string]$Default }
    while ($true) {
        $a = Read-Text "$Prompt (minutter, 0 = ingen tilgang, 'ingen' = ingen grense)" $d
        if ($a -in @('ingen', '-', '-1')) { return -1 }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 0 -and $n -le 1440) { return $n }
        Write-Warn 'Skriv et tall mellom 0 og 1440, eller ingen.'
    }
}

function Read-Numbers([string]$Prompt, [int]$Max) {
    # "1,3,5-7" til en liste med tall.
    $a = Read-Host $Prompt
    $res = @()
    foreach ($part in ($a -split '[,; ]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { $res += [int]$Matches[1]..[int]$Matches[2] }
        elseif ($part -match '^\d+$') { $res += [int]$part }
    }
    return @($res | Where-Object { $_ -ge 1 -and $_ -le $Max } | Sort-Object -Unique)
}

function ConvertTo-PlainText([Security.SecureString]$Secure) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

# ============================================================== Konfigurasjon

function ConvertTo-PcHashtable($Obj) {
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = ConvertTo-PcHashtable $p.Value }
        return $h
    }
    if ($Obj -is [System.Collections.IEnumerable] -and $Obj -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($i in $Obj) { [void]$list.Add((ConvertTo-PcHashtable $i)) }
        return , $list.ToArray()
    }
    return $Obj
}

function Merge-PcDefaults([hashtable]$Default, [hashtable]$Loaded) {
    foreach ($k in @($Loaded.Keys)) {
        if ($Default[$k] -is [hashtable] -and $Loaded[$k] -is [hashtable]) {
            Merge-PcDefaults $Default[$k] $Loaded[$k] | Out-Null
        } else {
            $Default[$k] = $Loaded[$k]
        }
    }
    return $Default
}

function Get-DefaultConfig {
    $days = @{}
    foreach ($d in $Weekdays) { $days[$d] = @{ Start = '07:00'; End = '20:00'; Limit = 120 } }
    foreach ($d in $Weekend)  { $days[$d] = @{ Start = '08:00'; End = '21:00'; Limit = 180 } }
    return @{
        Version    = 1
        Children   = @()
        ScreenTime = @{ Enabled = $false; Days = $days; Warn = @(10, 5, 1) }
        Bonus      = @{ Date = ''; Minutes = 0 }
        Apps       = @{
            Enabled = $false; AllowPaths = @(); DenyPaths = @(); DenyPackages = @()
            BlockStore = $true; BlockXbox = $true; BlockTools = $true; StrictUac = $true
        }
        Wifi       = @{ Mode = 'off'; Ssids = @(); BlockNewAdapters = $false; DisableBtPan = $true; AppliedMode = 'off'; AppliedSsids = @() }
        Web        = @{ Enabled = $false; Provider = 'cleanbrowsing'; Servers = @(); BrowserPolicies = $true; BlockPublicDns = $true; DohAdded = @() }
        Vpn        = @{ Enabled = $false; DisableBuiltin = $true; BlockPorts = $true; HideSettings = $true }
        Extra      = @{ TimeZone = $false; WinRE = $false; RegEdit = $true }
        Backup     = @{ Registry = @{}; Services = @{}; TimeZoneLine = ''; WinREDisabledByUs = $false; StoreRemovedFor = @() }
    }
}

function Get-Config {
    $cfg = Get-DefaultConfig
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $loaded = ConvertTo-PcHashtable (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
            $cfg = Merge-PcDefaults $cfg $loaded
        } catch {
            Write-Warn "Kunne ikke lese $ConfigPath ($($_.Exception.Message)). Starter med standardverdier."
        }
    }
    return $cfg
}

function Save-Config([hashtable]$Cfg) {
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $Cfg | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# ============================================================== System-hjelpere

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-IsHomeEdition {
    $ed = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    if ($ed -like 'Core*') { return $true }
    return -not (Get-Command Set-AppLockerPolicy -ErrorAction SilentlyContinue)
}

function Get-EditionName { return (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID }

function Get-GroupName([string]$Sid) {
    return (New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
}

function Get-GroupMemberSids([string]$GroupSid) {
    # ADSI i stedet for Get-LocalGroupMember, som feiler når gruppen har ukjente SID-er.
    $grp = [ADSI]"WinNT://$env:COMPUTERNAME/$(Get-GroupName $GroupSid),group"
    $res = @()
    foreach ($m in @($grp.Invoke('Members'))) {
        try {
            $bytes = $m.GetType().InvokeMember('objectSid', 'GetProperty', $null, $m, $null)
            $res += (New-Object Security.Principal.SecurityIdentifier ([byte[]]$bytes), 0).Value
        } catch { }
    }
    return $res
}

function Get-LocalAccounts {
    # Vanlige lokale kontoer (uten de innebygde systemkontoene).
    return @(Get-LocalUser | Where-Object {
        $_.SID.Value -notmatch '-(500|501|503|504)$'
    })
}

function Get-CurrentUserSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }

function Set-PcReg([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Remove-PcReg([string]$Path, [string]$Name) {
    if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
}

function Get-PcReg([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Invoke-Native([string]$Exe, [string]$Arguments) {
    # Kjører et program med argumentene nøyaktig som skrevet (netsh krever egne anførselstegn).
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { }
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out + $err) }
}

# ---- Maskininnstillinger med sikkerhetskopi, slik at "Fjern" kan sette tilbake det som var.

function Set-ManagedHklm([hashtable]$Cfg, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    $key = "$Path|$Name"
    if (-not $Cfg.Backup.Registry.ContainsKey($key)) {
        $old = Get-PcReg $Path $Name
        $Cfg.Backup.Registry[$key] = @{ Exists = ($null -ne $old); Value = $old; Type = $Type }
    }
    Set-PcReg $Path $Name $Value $Type
}

function Restore-ManagedHklm([hashtable]$Cfg, [string]$Path, [string]$Name) {
    $key = "$Path|$Name"
    if (-not $Cfg.Backup.Registry.ContainsKey($key)) { return }
    $b = $Cfg.Backup.Registry[$key]
    if ($b.Exists) { Set-PcReg $Path $Name $b.Value $b.Type } else { Remove-PcReg $Path $Name }
    $Cfg.Backup.Registry.Remove($key)
}

function Set-ManagedService([hashtable]$Cfg, [string]$Name, [bool]$Disable) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    if ($Disable) {
        if (-not $Cfg.Backup.Services.ContainsKey($Name)) { $Cfg.Backup.Services[$Name] = [string]$svc.StartType }
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        Set-Service -Name $Name -StartupType Disabled
    } elseif ($Cfg.Backup.Services.ContainsKey($Name)) {
        $start = $Cfg.Backup.Services[$Name]
        if ($start -notin @('Automatic', 'Manual', 'Disabled')) { $start = 'Manual' }
        Set-Service -Name $Name -StartupType $start
        $Cfg.Backup.Services.Remove($Name)
    }
}

# ============================================================== Barnets brukerprofil (HKCU)

function Initialize-ProfileApi {
    if (-not ('PcProfile' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class PcProfile {
    [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
    public static extern int CreateProfile(string sid, string user, StringBuilder path, uint len);
}
'@
    }
}

function Get-ChildProfilePath([hashtable]$Child) {
    $key = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($Child.Sid)"
    $p = Get-PcReg $key 'ProfileImagePath'
    if ($p -and (Test-Path -LiteralPath (Join-Path ([Environment]::ExpandEnvironmentVariables($p)) 'NTUSER.DAT'))) {
        return [Environment]::ExpandEnvironmentVariables($p)
    }
    # Profilen finnes ikke ennå: lag den uten at barnet må logge på først.
    Initialize-ProfileApi
    $sb = New-Object Text.StringBuilder 260
    $hr = [PcProfile]::CreateProfile($Child.Sid, $Child.Name, $sb, 260)
    if ($hr -ne 0 -and $hr -ne -2147024713) { throw "Kunne ikke lage brukerprofil for $($Child.Name) (HRESULT 0x{0:X8})." -f $hr }
    $p = Get-PcReg $key 'ProfileImagePath'
    if (-not $p) { throw "Fant ikke brukerprofilen til $($Child.Name)." }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Invoke-WithChildHive([hashtable]$Child, [scriptblock]$Script) {
    $loaded = "Registry::HKEY_USERS\$($Child.Sid)"
    if (Test-Path -LiteralPath $loaded) { & $Script $loaded; return }
    $hive  = Join-Path (Get-ChildProfilePath $Child) 'NTUSER.DAT'
    $mount = 'FK_' + ($Child.Sid -replace '[^0-9]', '')
    $r = Invoke-Native "$env:windir\System32\reg.exe" "load `"HKU\$mount`" `"$hive`""
    if ($r.ExitCode -ne 0) { throw "Kunne ikke åpne registeret til $($Child.Name): $($r.Output.Trim())" }
    try {
        & $Script "Registry::HKEY_USERS\$mount"
    } finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300
        $u = Invoke-Native "$env:windir\System32\reg.exe" "unload `"HKU\$mount`""
        if ($u.ExitCode -ne 0) { Start-Sleep -Seconds 2; [GC]::Collect(); [void](Invoke-Native "$env:windir\System32\reg.exe" "unload `"HKU\$mount`"") }
    }
}

function Protect-ChildPolicyKey([string]$KeyPath, [string]$ChildSid) {
    # Barnet skal bare kunne lese policy-nøklene sine, aldri endre dem.
    if (-not (Test-Path -LiteralPath $KeyPath)) { New-Item -Path $KeyPath -Force | Out-Null }
    $acl = New-Object Security.AccessControl.RegistrySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inh = [Security.AccessControl.InheritanceFlags]::ContainerInherit
    $none = [Security.AccessControl.PropagationFlags]::None
    foreach ($s in @('S-1-5-18', $SidAdmins)) {
        $id = New-Object Security.Principal.SecurityIdentifier $s
        $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($id, 'FullControl', $inh, $none, 'Allow')))
    }
    $cid = New-Object Security.Principal.SecurityIdentifier $ChildSid
    $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($cid, 'ReadKey', $inh, $none, 'Allow')))
    Set-Acl -LiteralPath $KeyPath -AclObject $acl
}

function Get-ChildRegSettings([hashtable]$Cfg, [switch]$All) {
    # Alle verdier skriptet setter i barnets HKCU. Med -All: alt som kan settes (brukes ved opprydding).
    $P  = 'Software\Policies'
    $CV = 'Software\Microsoft\Windows\CurrentVersion\Policies'
    $list = New-Object System.Collections.ArrayList
    function Add-S($Path, $Name, $Value, $Type = 'DWord') { [void]$list.Add(@{ Path = $Path; Name = $Name; Value = $Value; Type = $Type }) }

    if ($All -or ($Cfg.Web.Enabled -and $Cfg.Web.BrowserPolicies)) {
        $chromium = @(
            @{ Key = "$P\Microsoft\Edge";       Incog = 'InPrivateModeAvailability'; AddProfile = 'BrowserAddProfileEnabled' }
            @{ Key = "$P\Google\Chrome";        Incog = 'IncognitoModeAvailability'; AddProfile = 'BrowserAddPersonEnabled' }
            @{ Key = "$P\BraveSoftware\Brave";  Incog = 'IncognitoModeAvailability'; AddProfile = 'BrowserAddPersonEnabled' }
        )
        foreach ($b in $chromium) {
            Add-S $b.Key $b.Incog 1
            Add-S $b.Key $b.AddProfile 0
            Add-S $b.Key 'BrowserGuestModeEnabled' 0
            Add-S $b.Key 'DnsOverHttpsMode' 'off' 'String'
            Add-S $b.Key 'ForceGoogleSafeSearch' 1
            Add-S $b.Key 'ForceYouTubeRestrict' 1
            Add-S $b.Key 'ProxyMode' 'direct' 'String'
            Add-S "$($b.Key)\ExtensionInstallBlocklist" '1' '*' 'String'
        }
        Add-S "$P\Microsoft\Edge" 'ForceBingSafeSearch' 2
        Add-S "$P\BraveSoftware\Brave" 'TorDisabled' 1
        Add-S "$P\BraveSoftware\Brave" 'BraveVPNDisabled' 1
        Add-S "$P\Mozilla\Firefox" 'DisablePrivateBrowsing' 1
        Add-S "$P\Mozilla\Firefox" 'ExtensionSettings' '{"*":{"installation_mode":"blocked"}}' 'String'
        Add-S "$P\Mozilla\Firefox\DNSOverHTTPS" 'Enabled' 0
        Add-S "$P\Mozilla\Firefox\DNSOverHTTPS" 'Locked' 1
        Add-S "$P\Mozilla\Firefox\Proxy" 'Mode' 'none' 'String'
        Add-S "$P\Mozilla\Firefox\Proxy" 'Locked' 1
    }
    if ($All -or ($Cfg.Vpn.Enabled -and $Cfg.Vpn.HideSettings)) {
        Add-S "$CV\Explorer" 'SettingsPageVisibility' 'hide:network-vpn;network-proxy;network-dialup;network-mobilehotspot' 'String'
        Add-S "$P\Microsoft\Windows\Network Connections" 'NC_NewConnectionWizard' 0
        Add-S "$P\Microsoft\Windows\Network Connections" 'NC_RasConnect' 0
        Add-S "$P\Microsoft\Windows\Network Connections" 'NC_RasMyProperties' 0
        Add-S "$P\Microsoft\Windows\Network Connections" 'NC_ShowSharedAccessUI' 0
        Add-S "$P\Microsoft\Internet Explorer\Control Panel" 'Proxy' 1
    }
    if ($All -or ($Cfg.Apps.Enabled -and $Cfg.Apps.BlockTools)) {
        Add-S "$P\Microsoft\Windows\System" 'DisableCMD' 1
    }
    if ($All -or $Cfg.Extra.RegEdit) {
        Add-S "$CV\System" 'DisableRegistryTools' 1
    }
    return , $list.ToArray()
}

function Set-ChildSrp([string]$Root, [hashtable]$Cfg, [string[]]$WritableDirs) {
    # Windows Home: Software Restriction Policies i barnets HKCU (gjelder bare barnet).
    $base = "$Root\Software\Policies\Microsoft\Windows\Safer"
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
    if (-not $Cfg.Apps.Enabled) { return }
    $ci = "$base\CodeIdentifiers"
    Set-PcReg $ci 'DefaultLevel' 0
    Set-PcReg $ci 'TransparentEnabled' 1
    Set-PcReg $ci 'PolicyScope' 0
    Set-PcReg $ci 'AuthenticodeEnabled' 0
    Set-PcReg $ci 'ExecutableTypes' @('ADE', 'ADP', 'BAS', 'BAT', 'CHM', 'CMD', 'COM', 'CPL', 'CRT', 'EXE', 'HLP', 'HTA',
        'INF', 'INS', 'ISP', 'MDB', 'MDE', 'MSC', 'MSI', 'MSP', 'MST', 'OCX', 'PCD', 'PIF', 'PS1', 'REG', 'SCR', 'SHS',
        'VB', 'VBS', 'WSC', 'WSF', 'JS', 'JSE') 'MultiString'
    function Add-Path([string]$Level, [string]$Path, [string]$Desc) {
        $k = "$ci\$Level\Paths\{$([guid]::NewGuid())}"
        Set-PcReg $k 'ItemData' $Path 'ExpandString'
        Set-PcReg $k 'SaferFlags' 0
        Set-PcReg $k 'Description' $Desc 'String'
    }
    $allow = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}) + @($Cfg.Apps.AllowPaths)
    foreach ($a in ($allow | Where-Object { $_ } | Sort-Object -Unique)) { Add-Path '262144' $a 'Foreldrekontroll: tillatt' }
    $deny = @($WritableDirs) + @($Cfg.Apps.DenyPaths)
    if ($Cfg.Apps.BlockTools) { $deny += @($ChildDeniedTools | ForEach-Object { Expand-AppLockerPath $_ }) }
    foreach ($d in ($deny | Where-Object { $_ } | Sort-Object -Unique)) { Add-Path '0' ($d.TrimEnd('*').TrimEnd('\')) 'Foreldrekontroll: sperret' }
}

function Set-ChildHive([hashtable]$Child, [hashtable]$Cfg, [string[]]$WritableDirs, [bool]$Remove = $false) {
    Invoke-WithChildHive $Child {
        param($Root)
        foreach ($k in @("$Root\Software\Policies", "$Root\Software\Microsoft\Windows\CurrentVersion\Policies")) {
            Protect-ChildPolicyKey $k $Child.Sid
        }
        foreach ($s in (Get-ChildRegSettings $Cfg -All)) { Remove-PcReg "$Root\$($s.Path)" $s.Name }
        if ($Remove) {
            $safer = "$Root\Software\Policies\Microsoft\Windows\Safer"
            if (Test-Path -LiteralPath $safer) { Remove-Item -LiteralPath $safer -Recurse -Force }
            return
        }
        foreach ($s in (Get-ChildRegSettings $Cfg)) { Set-PcReg "$Root\$($s.Path)" $s.Name $s.Value $s.Type }
        if (Test-IsHomeEdition) { Set-ChildSrp $Root $Cfg $WritableDirs }
        if ($Cfg.Apps.Enabled) {
            # OneDrive ligger i barnets AppData og blir sperret; fjern autostart så det ikke kommer feilmeldinger.
            $run = "$Root\Software\Microsoft\Windows\CurrentVersion\Run"
            Remove-PcReg $run 'OneDriveSetup'
            Remove-PcReg $run 'OneDrive'
        }
    }
}

# ============================================================== 1. Barnekontoer

function Show-Children([hashtable]$Cfg) {
    if (@($Cfg.Children).Count -eq 0) { Write-Info 'Ingen barnekontoer er valgt ennå.'; return }
    $admins = Get-GroupMemberSids $SidAdmins
    foreach ($c in $Cfg.Children) {
        $u = Get-LocalUser -SID $c.Sid -ErrorAction SilentlyContinue
        if (-not $u) { Write-Err "$($c.Name): kontoen finnes ikke lenger"; continue }
        if ($admins -contains $c.Sid) { Write-Err "$($u.Name): er ADMINISTRATOR (må være standardbruker)" }
        else { Write-Ok "$($u.Name): standardbruker" }
    }
}

function Test-ParentSafety {
    $me = Get-CurrentUserSid
    $admins = Get-GroupMemberSids $SidAdmins
    foreach ($u in (Get-LocalAccounts | Where-Object { $_.Enabled -and $admins -contains $_.SID.Value })) {
        if (-not $u.PasswordRequired -or -not $u.PasswordLastSet) {
            Write-Warn "Administratorkontoen '$($u.Name)' ser ut til å mangle passord. Gi den et passord barnet ikke kjenner."
        }
    }
    $guest = Get-LocalUser | Where-Object { $_.SID.Value -match '-501$' }
    if ($guest -and $guest.Enabled) {
        if (Read-YesNo "Gjestekontoen er på. Vil du slå den av?" $true) { Disable-LocalUser -SID $guest.SID; Write-Ok 'Gjestekontoen er slått av.' }
    }
    if ($admins -notcontains $me) { Write-Warn 'Du kjører ikke som medlem av Administratorer-gruppen direkte.' }
}

function New-ChildAccount([hashtable]$Cfg) {
    $name = Read-Text 'Brukernavn for barnet (for eksempel emma)'
    if (-not $name -or $name -notmatch '^[^\\/\[\]:;|=,+*?<>"@]{1,20}$') { Write-Err 'Ugyldig brukernavn.'; return }
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Write-Err "Kontoen '$name' finnes allerede. Velg den i stedet."; return }
    $full = Read-Text 'Fullt navn (vises på påloggingsskjermen)' $name
    $pw1 = Read-Host 'Passord for barnet (tomt = uten passord)' -AsSecureString
    $params = @{ Name = $name; FullName = $full; Description = 'Barnekonto (foreldrekontroll)'; AccountNeverExpires = $true }
    if ($pw1.Length -gt 0) {
        $pw2 = Read-Host 'Skriv passordet en gang til' -AsSecureString
        if ((ConvertTo-PlainText $pw1) -cne (ConvertTo-PlainText $pw2)) { Write-Err 'Passordene er ikke like.'; return }
        $params.Password = $pw1
        $params.PasswordNeverExpires = $true
    } else {
        $params.NoPassword = $true
    }
    $u = New-LocalUser @params
    Add-LocalGroupMember -SID $SidUsers -Member $u -ErrorAction SilentlyContinue
    $child = @{ Name = $u.Name; Sid = $u.SID.Value }
    $Cfg.Children = @($Cfg.Children) + @($child)
    [void](Get-ChildProfilePath $child)
    Write-Ok "Kontoen '$name' er laget som standardbruker."
}

function Select-ExistingChild([hashtable]$Cfg) {
    $me = Get-CurrentUserSid
    $admins = Get-GroupMemberSids $SidAdmins
    $chosen = @($Cfg.Children | ForEach-Object { $_.Sid })
    $cands = @(Get-LocalAccounts | Where-Object { $_.SID.Value -ne $me -and $chosen -notcontains $_.SID.Value })
    if ($cands.Count -eq 0) { Write-Info 'Ingen andre kontoer å velge.'; return }
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $u = $cands[$i]
        $tag = if ($admins -contains $u.SID.Value) { 'administrator' } else { 'standardbruker' }
        $src = if ($u.PrincipalSource -eq 'MicrosoftAccount') { ', Microsoft-konto' } else { '' }
        Write-Host ("  {0,2}. {1} ({2}{3})" -f ($i + 1), $u.Name, $tag, $src)
    }
    $n = Read-Numbers 'Hvilken konto er barnets? (nummer)' $cands.Count
    foreach ($idx in $n) {
        $u = $cands[$idx - 1]
        if ($admins -contains $u.SID.Value) {
            $otherAdmins = @($admins | Where-Object { $_ -ne $u.SID.Value -and $_ -match '^S-1-5-21-' })
            if ($otherAdmins.Count -eq 0) { Write-Err "'$($u.Name)' er eneste administrator og kan ikke gjøres om."; continue }
            if (-not (Read-YesNo "'$($u.Name)' er administrator. Gjøre om til standardbruker?" $true)) { continue }
            Remove-LocalGroupMember -SID $SidAdmins -Member $u
            Add-LocalGroupMember -SID $SidUsers -Member $u -ErrorAction SilentlyContinue
            Write-Ok "'$($u.Name)' er nå standardbruker. Endringen gjelder fra neste pålogging."
        }
        $Cfg.Children = @($Cfg.Children) + @(@{ Name = $u.Name; Sid = $u.SID.Value })
        Write-Ok "'$($u.Name)' er lagt til som barnekonto."
    }
}

function Menu-Children([hashtable]$Cfg) {
    while ($true) {
        Write-Title 'Barnekontoer'
        Show-Children $Cfg
        Write-Host ''
        Write-Host '  1. Lag ny barnekonto'
        Write-Host '  2. Velg en konto som finnes'
        Write-Host '  3. Bytt passord for en barnekonto'
        Write-Host '  4. Fjern en konto fra listen (kontoen slettes ikke)'
        Write-Host '  0. Tilbake'
        switch (Read-Host 'Valg') {
            '1' { New-ChildAccount $Cfg; Save-Config $Cfg }
            '2' { Select-ExistingChild $Cfg; Save-Config $Cfg }
            '3' {
                $c = Select-Child $Cfg
                if ($c) {
                    $pw = Read-Host "Nytt passord for $($c.Name)" -AsSecureString
                    Set-LocalUser -SID $c.Sid -Password $pw
                    Write-Ok 'Passordet er byttet.'
                }
            }
            '4' {
                $c = Select-Child $Cfg
                if ($c) {
                    Set-ChildHive $c $Cfg @() $true
                    $Cfg.Children = @($Cfg.Children | Where-Object { $_.Sid -ne $c.Sid })
                    Save-Config $Cfg
                    Write-Ok "$($c.Name) er fjernet fra listen. Bruk 'Bruk alle innstillinger på nytt' for å oppdatere app-reglene."
                }
            }
            '0' { Test-ParentSafety; return }
        }
    }
}

function Select-Child([hashtable]$Cfg) {
    $list = @($Cfg.Children)
    if ($list.Count -eq 0) { Write-Warn 'Ingen barnekontoer.'; return $null }
    if ($list.Count -eq 1) { return $list[0] }
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $list[$i].Name) }
    $n = Read-Numbers 'Hvilken?' $list.Count
    if ($n.Count -eq 0) { return $null }
    return $list[$n[0] - 1]
}

# ============================================================== 2. Skjermtid

function Format-Limit($Limit) {
    if ($Limit -lt 0) { return 'ingen grense' }
    if ($Limit -eq 0) { return 'ingen tilgang' }
    return ('{0}t {1:00}m' -f [math]::Floor($Limit / 60), ($Limit % 60))
}

function Show-Schedule([hashtable]$Cfg) {
    $state = if ($Cfg.ScreenTime.Enabled) { 'PÅ' } else { 'AV' }
    Write-Host "  Skjermtid er $state"
    Write-Host ''
    Write-Host ('  {0,-9} {1,-6} {2,-6} {3}' -f 'Dag', 'Fra', 'Til', 'Maks per dag')
    foreach ($d in $DayNames.Keys) {
        $r = $Cfg.ScreenTime.Days[$d]
        Write-Host ('  {0,-9} {1,-6} {2,-6} {3}' -f $DayNames[$d], $r.Start, $r.End, (Format-Limit $r.Limit))
    }
}

function Edit-Days([hashtable]$Cfg, [string[]]$Days, [string]$Label) {
    $first = $Cfg.ScreenTime.Days[$Days[0]]
    Write-Host "`n  $Label"
    $start = Read-Time '  Tidligste klokkeslett' $first.Start
    while ($true) {
        $end = Read-Time '  Seneste klokkeslett' $first.End
        if ($end -gt $start) { break }
        Write-Warn 'Slutt må være etter start.'
    }
    $limit = Read-Limit '  Maks skjermtid per dag' $first.Limit
    foreach ($d in $Days) { $Cfg.ScreenTime.Days[$d] = @{ Start = $start; End = $end; Limit = $limit } }
}

function Menu-ScreenTime([hashtable]$Cfg, [switch]$Wizard) {
    if ($Wizard) {
        Write-Title 'Skjermtid'
        Write-Info 'Barnet kan bare være pålogget innenfor et tidsrom, og bare så mange minutter per dag.'
        Write-Info 'Barnet får varsel 10, 5 og 1 minutt før tiden er ute, og blir logget ut etter 1 minutt til.'
        $Cfg.ScreenTime.Enabled = Read-YesNo 'Slå på skjermtid?' $true
        if ($Cfg.ScreenTime.Enabled) {
            Edit-Days $Cfg $Weekdays 'Hverdager (mandag til fredag)'
            Edit-Days $Cfg $Weekend 'Helg (lørdag og søndag)'
            if (Read-YesNo 'Vil du endre enkeltdager også?' $false) {
                foreach ($d in $DayNames.Keys) { if (Read-YesNo "  Endre $($DayNames[$d])?" $false) { Edit-Days $Cfg @($d) $DayNames[$d] } }
            }
        }
        Save-Config $Cfg; Apply-ScreenTime $Cfg
        return
    }
    while ($true) {
        Write-Title 'Skjermtid'
        Show-Schedule $Cfg
        Write-Host ''
        Write-Host '  1. Slå skjermtid på/av'
        Write-Host '  2. Sett hverdager (mandag til fredag)'
        Write-Host '  3. Sett helg (lørdag og søndag)'
        Write-Host '  4. Endre én dag'
        Write-Host '  5. Vis brukt tid i dag'
        Write-Host '  0. Tilbake (lagrer og tar i bruk)'
        switch (Read-Host 'Valg') {
            '1' { $Cfg.ScreenTime.Enabled = -not $Cfg.ScreenTime.Enabled }
            '2' { Edit-Days $Cfg $Weekdays 'Hverdager' }
            '3' { Edit-Days $Cfg $Weekend 'Helg' }
            '4' {
                $keys = @($DayNames.Keys)
                for ($i = 0; $i -lt 7; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), $DayNames[$keys[$i]]) }
                $n = Read-Numbers 'Hvilken dag?' 7
                if ($n.Count) { Edit-Days $Cfg @($keys[$n[0] - 1]) $DayNames[$keys[$n[0] - 1]] }
            }
            '5' { Show-UsageToday $Cfg; Wait-Key }
            '0' { Save-Config $Cfg; Apply-ScreenTime $Cfg; return }
        }
    }
}

function Show-UsageToday([hashtable]$Cfg) {
    $u = $null
    if (Test-Path -LiteralPath $UsagePath) { try { $u = Get-Content -LiteralPath $UsagePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    foreach ($c in $Cfg.Children) {
        $m = 0
        if ($u -and $u.Date -eq (Get-Date).ToString('yyyy-MM-dd') -and $u.Users.($c.Sid)) { $m = [math]::Round([double]$u.Users.($c.Sid).Minutes) }
        Write-Info "$($c.Name): $m minutter brukt i dag"
    }
}

function Set-LogonHours([hashtable]$Cfg, [hashtable]$Child) {
    # Påloggingstider for kontoen (21 byte, én bit per time i UTC, søndag 00:00 først).
    # Utvides én time på hver side så sommertid ikke kutter tid; håndheveren styrer på minuttet.
    $bits = New-Object bool[] 168
    if (-not $Cfg.ScreenTime.Enabled) {
        for ($i = 0; $i -lt 168; $i++) { $bits[$i] = $true }
    } else {
        $offset = [int][math]::Floor([TimeZoneInfo]::Local.BaseUtcOffset.TotalHours)
        $order = @('Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday')
        for ($d = 0; $d -lt 7; $d++) {
            $r = $Cfg.ScreenTime.Days[$order[$d]]
            if ($r.Limit -eq 0) { continue }
            $sh = [int]$r.Start.Split(':')[0] - 1
            $eh = [int]$r.End.Split(':')[0] + 2
            if ([int]$r.End.Split(':')[1] -eq 0) { $eh -= 1 }
            for ($h = $sh; $h -lt $eh; $h++) {
                $idx = (($d * 24 + $h - $offset) % 168 + 168) % 168
                $bits[$idx] = $true
            }
        }
    }
    $bytes = New-Object byte[] 21
    for ($i = 0; $i -lt 168; $i++) { if ($bits[$i]) { $bytes[[math]::Floor($i / 8)] = $bytes[[math]::Floor($i / 8)] -bor (1 -shl ($i % 8)) } }
    try {
        $u = [ADSI]"WinNT://$env:COMPUTERNAME/$($Child.Name),user"
        $u.Put('LogonHours', [byte[]]$bytes)
        $u.SetInfo()
    } catch {
        Write-Warn "Kunne ikke sette påloggingstider for $($Child.Name): $($_.Exception.Message)"
    }
}

function Install-Files {
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $here = Split-Path -Parent $PSCommandPath
    foreach ($f in @('Haandhever.ps1', 'Setup-Foreldrekontroll.ps1', 'Start-Foreldrekontroll.cmd', 'README.md')) {
        $src = Join-Path $here $f
        $dst = Join-Path $InstallDir $f
        if ((Test-Path -LiteralPath $src) -and ($src -ne $dst)) { Copy-Item -LiteralPath $src -Destination $dst -Force }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Haandhever.ps1'))) {
        throw "Fant ikke Haandhever.ps1. Den må ligge i samme mappe som dette skriptet."
    }
}

function Register-EnforcerTask {
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$InstallDir\Haandhever.ps1&quot;"
    $start = (Get-Date).Date.ToString('yyyy-MM-ddTHH:mm:ss')
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Foreldrekontroll: skjermtid og DNS-filter</Description></RegistrationInfo>
  <Triggers>
    <TimeTrigger><StartBoundary>$start</StartBoundary><Enabled>true</Enabled>
      <Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition>
    </TimeTrigger>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
    <LogonTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></LogonTrigger>
    <SessionStateChangeTrigger><Enabled>true</Enabled><StateChange>SessionUnlock</StateChange></SessionStateChangeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
  </Settings>
  <Actions Context="Author"><Exec><Command>$ps</Command><Arguments>$arg</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force | Out-Null
}

function Apply-ScreenTime([hashtable]$Cfg) {
    Install-Files
    Register-EnforcerTask
    foreach ($c in $Cfg.Children) { Set-LogonHours $Cfg $c }
    if ($Cfg.ScreenTime.Enabled) { Write-Ok 'Skjermtid er tatt i bruk.' } else { Write-Ok 'Skjermtid er av.' }
}

function Menu-Bonus([hashtable]$Cfg) {
    Write-Title 'Gi ekstra tid i dag'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $have = if ($Cfg.Bonus.Date -eq $today) { [int]$Cfg.Bonus.Minutes } else { 0 }
    Write-Info "Ekstra tid gitt i dag: $have minutter. Ekstra tid gjelder også etter siste klokkeslett."
    $n = 0
    $a = Read-Text 'Hvor mange minutter ekstra? (negativt tall trekker fra)' '30'
    if (-not [int]::TryParse($a, [ref]$n)) { Write-Err 'Ikke et tall.'; return }
    $Cfg.Bonus = @{ Date = $today; Minutes = [math]::Max(0, $have + $n) }
    Save-Config $Cfg
    Write-Ok "Ekstra tid i dag er nå $($Cfg.Bonus.Minutes) minutter."
}

# ============================================================== 3. Apper og spill

function Test-DirWritable([string]$Path, [string[]]$ExtraSids) {
    $sids = @($SidEveryone, 'S-1-5-11', $SidUsers, 'S-1-5-4', 'S-1-5-32-546') + @($ExtraSids)
    try { $acl = Get-Acl -LiteralPath $Path } catch { return $false }
    $mask = 0x2 -bor 0x4 -bor 0x40000 -bor 0x80000 -bor 0x10000000 -bor 0x40000000
    foreach ($r in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($r.AccessControlType -ne 'Allow') { continue }
        if ($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) { continue }
        if ($sids -notcontains $r.IdentityReference.Value) { continue }
        if (([int64]$r.FileSystemRights) -band $mask) { return $true }
    }
    return $false
}

function Get-WritableDirs([hashtable]$Cfg) {
    # Mapper under Windows og Program Files som vanlige brukere kan skrive i.
    $childSids = @($Cfg.Children | ForEach-Object { $_.Sid })
    $res = New-Object System.Collections.ArrayList
    foreach ($w in $WindowsWritable) {
        $p = Join-Path $env:windir $w
        if (Test-Path -LiteralPath $p) { [void]$res.Add($p) }
    }
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Sort-Object -Unique
    $stack = New-Object System.Collections.Stack
    foreach ($r in $roots) {
        try { foreach ($d in [IO.Directory]::GetDirectories($r)) { $stack.Push(@($d, 1)) } } catch { }
    }
    while ($stack.Count -gt 0) {
        $item = $stack.Pop(); $dir = $item[0]; $depth = $item[1]
        if ((Split-Path -Leaf $dir) -eq 'WindowsApps') { continue }
        try { if ((Get-Item -LiteralPath $dir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue } } catch { continue }
        if (Test-DirWritable $dir $childSids) { [void]$res.Add($dir); continue }
        if ($depth -lt 4) {
            try { foreach ($d in [IO.Directory]::GetDirectories($dir)) { $stack.Push(@($d, $depth + 1)) } } catch { }
        }
    }
    return , $res.ToArray()
}

function Convert-ToAppLockerPath([string]$Path) {
    $p = $Path.TrimEnd('\')
    $map = @(
        @{ Dir = ${env:ProgramFiles(x86)}; Var = '%PROGRAMFILES%' },
        @{ Dir = $env:ProgramFiles;        Var = '%PROGRAMFILES%' },
        @{ Dir = $env:windir;              Var = '%WINDIR%' }
    )
    foreach ($m in $map) {
        if ($m.Dir -and ($p -eq $m.Dir -or $p.StartsWith($m.Dir + '\', [StringComparison]::OrdinalIgnoreCase))) {
            return $m.Var + $p.Substring($m.Dir.Length)
        }
    }
    return $p
}

function Expand-AppLockerPath([string]$Path) {
    return $Path.Replace('%WINDIR%', $env:windir).Replace('%PROGRAMFILES%', $env:ProgramFiles).Replace('%SYSTEM32%', "$env:windir\System32")
}

function Test-UnderAny([string]$Path, [string[]]$Dirs) {
    foreach ($d in $Dirs) {
        if (-not $d) { continue }
        $d2 = $d.TrimEnd('\')
        if ($Path -eq $d2 -or $Path.StartsWith($d2 + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-AppCandidates([string[]]$WritableDirs) {
    # Finn programmapper og spill: Start-menyen, Steam, Epic.
    $found = @{}
    function Add-Cand([string]$Name, [string]$Dir, [string]$Kind) {
        if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return }
        $Dir = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
        if (Test-UnderAny $Dir @($env:windir)) { return }
        if ($Dir -in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) { return }
        if (-not $found.ContainsKey($Dir.ToLower())) { $found[$Dir.ToLower()] = [pscustomobject]@{ Name = $Name; Dir = $Dir; Kind = $Kind } }
    }
    $shell = New-Object -ComObject WScript.Shell
    $menus = @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs")
    foreach ($p in (Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special })) {
        $menus += Join-Path $p.LocalPath 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs'
    }
    foreach ($m in $menus) {
        if (-not (Test-Path -LiteralPath $m)) { continue }
        foreach ($lnk in (Get-ChildItem -LiteralPath $m -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            try { $t = $shell.CreateShortcut($lnk.FullName).TargetPath } catch { continue }
            if ($t -and $t -like '*.exe' -and (Test-Path -LiteralPath $t)) {
                if ($lnk.BaseName -match '(?i)uninstall|avinstaller') { continue }
                Add-Cand $lnk.BaseName (Split-Path -Parent $t) 'Program'
            }
        }
    }
    # Steam
    $steam = Get-PcReg 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath'
    if ($steam -and (Test-Path -LiteralPath $steam)) {
        $libs = @($steam)
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($mt in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += $mt.Groups[1].Value.Replace('\\', '\') }
        }
        foreach ($l in ($libs | Sort-Object -Unique)) {
            $common = Join-Path $l 'steamapps\common'
            if (Test-Path -LiteralPath $common) {
                foreach ($g in (Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue)) { Add-Cand "Steam: $($g.Name)" $g.FullName 'Spill' }
            }
        }
    }
    # Epic Games
    $man = "$env:ProgramData\Epic\EpicGamesLauncher\Data\Manifests"
    if (Test-Path -LiteralPath $man) {
        foreach ($f in (Get-ChildItem -LiteralPath $man -Filter '*.item' -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; Add-Cand "Epic: $($j.DisplayName)" $j.InstallLocation 'Spill' } catch { }
        }
    }
    $list = @($found.Values | Sort-Object Kind, Name)
    foreach ($c in $list) {
        $protected = (Test-UnderAny $c.Dir @($env:ProgramFiles, ${env:ProgramFiles(x86)})) -and -not (Test-UnderAny $c.Dir $WritableDirs)
        $c | Add-Member -NotePropertyName Protected -NotePropertyValue $protected
    }
    return , $list
}

function Get-StoreApps {
    $skip = '^(Microsoft\.(VCLibs|NET|UI\.Xaml|Services\.Store|WindowsAppRuntime|DirectX|Advertising|Windows\.|AAD|AccountsControl|Win32WebViewHost|LockApp|ECApp|CredDialogHost|BioEnrollment|AsyncTextService|MicrosoftEdgeDevToolsClient|XboxGameCallableUI|XboxIdentityProvider|XboxSpeechToTextOverlay|XboxGameOverlay|XboxGamingOverlay|Xbox\.TCUI|StorePurchaseApp|DesktopAppInstaller|WindowsStore|SecHealthUI|Edge|WebMediaExtensions|HEIF|HEVC|VP9|AV1|WebpImage|RawImage|MPEG2|Office\.OneNote|LanguageExperiencePack|OneDriveSync|Paint|WindowsNotepad|WindowsCalculator|WindowsCamera|ScreenSketch|WindowsTerminal|Photos|WindowsAlarms|GetHelp|Getstarted|WindowsFeedbackHub|ApplicationCompatibilityEnhancements|OOBENetworkCaptivePortal|OOBENetworkConnectionFlow|Ink\.Handwriting|WidgetsPlatformRuntime|StartExperiencesApp|Winget|GamingServices|CrossDevice|DevHome|PowerAutomateDesktop|BingWeather|BingNews|BingSearch|Todos|YourPhone|ZuneMusic|ZuneVideo|WindowsSoundRecorder|MicrosoftStickyNotes|People|OutlookForWindows|Copilot|M365Companions|MicrosoftOfficeHub|Teams|QuickAssist|SnippingTool|WindowsMaps|549981C3F5F10)|MicrosoftWindows\.|windows\.|Windows\.|NcsiUwpApp|1527c705-839a-4832-9118-54d4Bd6a0c89|c5e2524a-ea46-4f67-841f-6a9465d9d515|E2A4F912-2574-4A75-9BB0-0D023378592B|F46D4000-FD22-4DB4-AC8E-4E1DDDE828FE)'
    $pk = @()
    try { $pk = @(Get-AppxPackage -AllUsers -ErrorAction Stop) } catch { $pk = @(Get-AppxPackage -ErrorAction SilentlyContinue) }
    $res = @{}
    foreach ($p in $pk) {
        if ($p.IsFramework -or $p.IsResourcePackage -or $p.NonRemovable) { continue }
        if ($p.SignatureKind -eq 'System') { continue }
        if ($p.Name -match $skip) { continue }
        if (-not $res.ContainsKey($p.Name)) { $res[$p.Name] = [pscustomobject]@{ Name = $p.Name; Publisher = $p.Publisher } }
    }
    return , @($res.Values | Sort-Object Name)
}

function Menu-Apps([hashtable]$Cfg, [switch]$Wizard) {
    $isHome = Test-IsHomeEdition
    Write-Title 'Apper og spill'
    if ($isHome) {
        Write-Warn "Windows-utgave: $(Get-EditionName). Bruker Software Restriction Policies (svakere enn AppLocker)."
    } else {
        Write-Info "Windows-utgave: $(Get-EditionName). Bruker AppLocker."
    }
    Write-Info 'Når dette er på, kan barnet bare starte programmer som er installert av en voksen'
    Write-Info '(i Windows og Program Files). Programmer i Nedlastinger, AppData og på minnepinner starter'
    Write-Info 'ikke, så barnet kan ikke installere eller kjøre nye programmer, spill, nettlesere eller VPN.'
    if ($Wizard -or -not $Cfg.Apps.Enabled) {
        $Cfg.Apps.Enabled = Read-YesNo 'Slå på sperre for installering og ukjente programmer?' $true
        if (-not $Cfg.Apps.Enabled) { Save-Config $Cfg; Apply-Apps $Cfg; return }
        $Cfg.Apps.BlockStore = Read-YesNo 'Sperre Microsoft Store og App Installer (winget) for barnet?' $true
        $Cfg.Apps.BlockXbox = Read-YesNo 'Sperre Xbox-appen (den kan installere spill uten passord)?' $true
        $Cfg.Apps.BlockTools = Read-YesNo 'Sperre kommandolinje, PowerShell og andre verktøy som kan omgå sperrene?' $true
        $Cfg.Apps.StrictUac = Read-YesNo 'Avvise "Kjør som administrator" i barnets økt automatisk (anbefalt)?' $true
    }
    Write-Info 'Leter etter installerte programmer og spill (kan ta litt tid) ...'
    $writable = Get-WritableDirs $Cfg
    $cands = Get-AppCandidates $writable
    $store = Get-StoreApps
    while ($true) {
        Write-Title 'Apper og spill: velg hva barnet får bruke'
        $rows = @()
        foreach ($c in $cands) {
            if ($c.Protected) { $ok = -not (Test-UnderAny $c.Dir @($Cfg.Apps.DenyPaths)) }
            else { $ok = Test-UnderAny $c.Dir @($Cfg.Apps.AllowPaths) }
            $rows += [pscustomobject]@{ Type = 'dir'; Item = $c; Ok = $ok; Label = $c.Name; Note = $(if ($c.Protected) { '' } else { '(mappe barnet kan skrive i)' }) }
        }
        foreach ($s in $store) {
            $ok = -not (@($Cfg.Apps.DenyPackages | Where-Object { $_.Name -eq $s.Name }).Count)
            $rows += [pscustomobject]@{ Type = 'appx'; Item = $s; Ok = $ok; Label = "Store-app: $($s.Name)"; Note = '' }
        }
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $mark = if ($r.Ok) { 'TILLATT ' } else { 'SPERRET ' }
            $col = if ($r.Ok) { 'Green' } else { 'Red' }
            Write-Host ("  {0,3}. " -f ($i + 1)) -NoNewline
            Write-Host $mark -ForegroundColor $col -NoNewline
            Write-Host " $($r.Label) $($r.Note)"
        }
        Write-Host ''
        Write-Info "Store: $(if ($Cfg.Apps.BlockStore) {'sperret'} else {'tillatt'}),  Xbox-appen: $(if ($Cfg.Apps.BlockXbox) {'sperret'} else {'tillatt'})"
        Write-Host '  Skriv numre for å bytte mellom tillatt/sperret (for eksempel 2,5,7-9).'
        Write-Host '  S = bytt Store,  X = bytt Xbox-appen,  M = legg til mappe selv,  Enter = ferdig'
        $a = (Read-Host 'Valg').Trim()
        if ($a -eq '') { break }
        if ($a -ieq 's') { $Cfg.Apps.BlockStore = -not $Cfg.Apps.BlockStore; continue }
        if ($a -ieq 'x') { $Cfg.Apps.BlockXbox = -not $Cfg.Apps.BlockXbox; continue }
        if ($a -ieq 'm') {
            $d = Read-Text 'Full sti til programmappen'
            if ($d -and (Test-Path -LiteralPath $d -PathType Container)) {
                $d = (Resolve-Path -LiteralPath $d).ProviderPath.TrimEnd('\')
                $prot = (Test-UnderAny $d @($env:ProgramFiles, ${env:ProgramFiles(x86)})) -and -not (Test-UnderAny $d $writable)
                $cands = @($cands) + @([pscustomobject]@{ Name = (Split-Path -Leaf $d); Dir = $d; Kind = 'Program'; Protected = $prot })
            } else { Write-Err 'Fant ikke mappen.' }
            continue
        }
        $nums = @()
        foreach ($part in ($a -split '[,; ]+' | Where-Object { $_ })) {
            if ($part -match '^(\d+)-(\d+)$') { $nums += [int]$Matches[1]..[int]$Matches[2] } elseif ($part -match '^\d+$') { $nums += [int]$part }
        }
        foreach ($n in ($nums | Where-Object { $_ -ge 1 -and $_ -le $rows.Count } | Sort-Object -Unique)) {
            $r = $rows[$n - 1]
            if ($r.Type -eq 'appx') {
                if ($r.Ok) { $Cfg.Apps.DenyPackages = @($Cfg.Apps.DenyPackages) + @(@{ Name = $r.Item.Name; Publisher = $r.Item.Publisher }) }
                else { $Cfg.Apps.DenyPackages = @($Cfg.Apps.DenyPackages | Where-Object { $_.Name -ne $r.Item.Name }) }
            } elseif ($r.Item.Protected) {
                if ($r.Ok) { $Cfg.Apps.DenyPaths = @($Cfg.Apps.DenyPaths) + @($r.Item.Dir) }
                else { $Cfg.Apps.DenyPaths = @($Cfg.Apps.DenyPaths | Where-Object { $_ -ne $r.Item.Dir }) }
            } else {
                if ($r.Ok) { $Cfg.Apps.AllowPaths = @($Cfg.Apps.AllowPaths | Where-Object { $_ -ne $r.Item.Dir }) }
                else {
                    Write-Warn "Barnet kan legge egne programmer i '$($r.Item.Dir)'. Å tillate den åpner et lite hull i sperren."
                    if (Read-YesNo 'Tillate likevel?' $true) { $Cfg.Apps.AllowPaths = @($Cfg.Apps.AllowPaths) + @($r.Item.Dir) }
                }
            }
        }
    }
    Save-Config $Cfg
    Apply-Apps $Cfg $writable
}

function New-AppLockerXml([hashtable]$Cfg, [string[]]$ChildSids, [string[]]$OtherSids, [string[]]$WritableDirs) {
    # Bygger en hel AppLocker-policy. Ren tekstbygging, kan testes uten Windows.
    $sb = New-Object Text.StringBuilder
    function Esc([string]$s) { return [Security.SecurityElement]::Escape($s) }
    function Add-PathRule([string]$Name, [string]$Sid, [string]$Action, [string]$Path, [string[]]$Exceptions) {
        [void]$sb.Append("<FilePathRule Id=`"$([guid]::NewGuid())`" Name=`"$(Esc $Name)`" Description=`"Foreldrekontroll`" UserOrGroupSid=`"$Sid`" Action=`"$Action`">")
        [void]$sb.Append("<Conditions><FilePathCondition Path=`"$(Esc $Path)`" /></Conditions>")
        if ($Exceptions -and $Exceptions.Count) {
            [void]$sb.Append('<Exceptions>')
            foreach ($e in $Exceptions) { [void]$sb.Append("<FilePathCondition Path=`"$(Esc $e)`" />") }
            [void]$sb.Append('</Exceptions>')
        }
        [void]$sb.Append('</FilePathRule>')
    }
    function Add-AppxRule([string]$Name, [string]$Sid, [string]$Action, [string]$Publisher, [string]$Product) {
        [void]$sb.Append("<FilePublisherRule Id=`"$([guid]::NewGuid())`" Name=`"$(Esc $Name)`" Description=`"Foreldrekontroll`" UserOrGroupSid=`"$Sid`" Action=`"$Action`">")
        [void]$sb.Append("<Conditions><FilePublisherCondition PublisherName=`"$(Esc $Publisher)`" ProductName=`"$(Esc $Product)`" BinaryName=`"*`">")
        [void]$sb.Append('<BinaryVersionRange LowSection="0.0.0.0" HighSection="*" /></FilePublisherCondition></Conditions></FilePublisherRule>')
    }
    $win = @(); $pf = @()
    foreach ($w in $WritableDirs) {
        $a = (Convert-ToAppLockerPath $w) + '\*'
        if ($a.StartsWith('%WINDIR%')) { $win += $a } elseif ($a.StartsWith('%PROGRAMFILES%')) { $pf += $a }
    }
    $win = @($win | Sort-Object -Unique); $pf = @($pf | Sort-Object -Unique)
    $trusted = @($SidAdmins, 'S-1-5-18', 'S-1-5-19', 'S-1-5-20') + @($OtherSids)

    [void]$sb.Append('<AppLockerPolicy Version="1">')
    foreach ($type in @('Exe', 'Script', 'Msi')) {
        [void]$sb.Append("<RuleCollection Type=`"$type`" EnforcementMode=`"Enabled`">")
        foreach ($t in $trusted) { Add-PathRule "Alt for voksne og system ($t)" $t 'Allow' '*' @() }
        if ($type -eq 'Msi') {
            Add-PathRule 'Windows Installer-cache' $SidEveryone 'Allow' '%WINDIR%\Installer\*' @()
        } else {
            Add-PathRule 'Windows' $SidEveryone 'Allow' '%WINDIR%\*' $win
            Add-PathRule 'Program Files' $SidEveryone 'Allow' '%PROGRAMFILES%\*' $pf
            foreach ($c in $ChildSids) {
                foreach ($p in $Cfg.Apps.AllowPaths) { Add-PathRule "Tillatt for barn: $p" $c 'Allow' ((Convert-ToAppLockerPath $p) + '\*') @() }
                if ($type -eq 'Exe') {
                    foreach ($p in $Cfg.Apps.DenyPaths) { Add-PathRule "Sperret for barn: $p" $c 'Deny' ((Convert-ToAppLockerPath $p) + '\*') @() }
                    if ($Cfg.Apps.BlockTools) { foreach ($t in $ChildDeniedTools) { Add-PathRule "Verktøy sperret for barn: $t" $c 'Deny' $t @() } }
                }
            }
        }
        [void]$sb.Append('</RuleCollection>')
    }
    [void]$sb.Append('<RuleCollection Type="Appx" EnforcementMode="Enabled">')
    foreach ($t in @($SidEveryone) + $trusted) { Add-AppxRule 'Alle signerte pakkeapper' $t 'Allow' '*' '*' }
    foreach ($c in $ChildSids) {
        $deny = @($Cfg.Apps.DenyPackages | ForEach-Object { @{ Name = $_.Name; Publisher = $_.Publisher } })
        $ms = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US'
        if ($Cfg.Apps.BlockStore) { foreach ($n in $StorePackages) { $deny += @{ Name = $n; Publisher = $ms } } }
        if ($Cfg.Apps.BlockXbox)  { foreach ($n in $XboxPackages)  { $deny += @{ Name = $n; Publisher = $ms } } }
        foreach ($d in $deny) { Add-AppxRule "Sperret for barn: $($d.Name)" $c 'Deny' $d.Publisher $d.Name }
    }
    [void]$sb.Append('</RuleCollection>')
    [void]$sb.Append('</AppLockerPolicy>')
    return $sb.ToString()
}

function Get-EmptyAppLockerXml {
    return '<AppLockerPolicy Version="1"><RuleCollection Type="Exe" EnforcementMode="NotConfigured" /><RuleCollection Type="Msi" EnforcementMode="NotConfigured" /><RuleCollection Type="Script" EnforcementMode="NotConfigured" /><RuleCollection Type="Dll" EnforcementMode="NotConfigured" /><RuleCollection Type="Appx" EnforcementMode="NotConfigured" /></AppLockerPolicy>'
}

function Set-AppLockerFromXml([string]$Xml) {
    $f = Join-Path $InstallDir 'applocker.xml'
    Set-Content -LiteralPath $f -Value $Xml -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $f
}

function Get-OtherUserSids([hashtable]$Cfg) {
    $childSids = @($Cfg.Children | ForEach-Object { $_.Sid })
    return @(Get-LocalUser | Where-Object { $childSids -notcontains $_.SID.Value -and $_.SID.Value -notmatch '-(501|503|504)$' } | ForEach-Object { $_.SID.Value })
}

function Set-StoreForChildHome([hashtable]$Cfg) {
    # Windows Home: AppLocker finnes ikke, så Store-pakkene fjernes for barnet.
    $names = @()
    if ($Cfg.Apps.Enabled -and $Cfg.Apps.BlockStore) { $names += $StorePackages }
    if ($Cfg.Apps.Enabled -and $Cfg.Apps.BlockXbox)  { $names += $XboxPackages }
    $names += @($Cfg.Apps.DenyPackages | ForEach-Object { $_.Name })
    foreach ($c in $Cfg.Children) {
        foreach ($n in ($names | Sort-Object -Unique)) {
            foreach ($p in @(Get-AppxPackage -Name $n -User $c.Sid -ErrorAction SilentlyContinue)) {
                try { Remove-AppxPackage -Package $p.PackageFullName -User $c.Sid -ErrorAction Stop; Write-Ok "$n er fjernet for $($c.Name)." }
                catch { Write-Warn "Kunne ikke fjerne $n for $($c.Name): $($_.Exception.Message)" }
            }
        }
    }
}

function Apply-Apps([hashtable]$Cfg, [string[]]$Writable = $null) {
    $hklmInst = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Installer'
    $hklmUac  = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if ($null -eq $Writable) { $Writable = Get-WritableDirs $Cfg }
    $childSids = @($Cfg.Children | ForEach-Object { $_.Sid })
    $isHome = Test-IsHomeEdition

    if ($Cfg.Apps.Enabled -and $childSids.Count) {
        Set-ManagedHklm $Cfg $hklmInst 'DisableUserInstalls' 1
        if ($Cfg.Apps.StrictUac) { Set-ManagedHklm $Cfg $hklmUac 'ConsentPromptBehaviorUser' 0 } else { Restore-ManagedHklm $Cfg $hklmUac 'ConsentPromptBehaviorUser' }
        if ($isHome) {
            Set-StoreForChildHome $Cfg
            Write-Ok 'Software Restriction Policies settes i barnets profil.'
        } else {
            Set-AppLockerFromXml (New-AppLockerXml $Cfg $childSids (Get-OtherUserSids $Cfg) $Writable)
            [void](Invoke-Native "$env:windir\System32\sc.exe" 'config AppIDSvc start= auto')
            [void](Invoke-Native "$env:windir\System32\sc.exe" 'start AppIDSvc')
            [void](Invoke-Native "$env:windir\System32\gpupdate.exe" '/target:computer /force')
            Write-Ok 'AppLocker-reglene er tatt i bruk.'
        }
    } else {
        Restore-ManagedHklm $Cfg $hklmInst 'DisableUserInstalls'
        Restore-ManagedHklm $Cfg $hklmUac 'ConsentPromptBehaviorUser'
        if (-not $isHome) { Set-AppLockerFromXml (Get-EmptyAppLockerXml) }
        Write-Ok 'App-sperren er av.'
    }
    foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg $Writable }
    Save-Config $Cfg
}

# ============================================================== 4. Trådløse nettverk

function Test-HasWifi {
    $r = Invoke-Native "$env:windir\System32\netsh.exe" 'wlan show interfaces'
    return ($r.ExitCode -eq 0 -and $r.Output -match '(?m)^\s+SSID\s')
}

function Get-VisibleSsids {
    $r = Invoke-Native "$env:windir\System32\netsh.exe" 'wlan show networks mode=ssid'
    return @([regex]::Matches($r.Output, '(?m)^SSID \d+\s*:\s*(.*?)\s*$') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-SavedSsids {
    $tmp = Join-Path $InstallDir 'wlan-eksport'
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    [void](Invoke-Native "$env:windir\System32\netsh.exe" "wlan export profile folder=`"$tmp`"")
    $res = @()
    foreach ($f in (Get-ChildItem -LiteralPath $tmp -Filter '*.xml' -ErrorAction SilentlyContinue)) {
        try {
            $x = [xml](Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8)
            $res += [pscustomobject]@{ Profile = $x.WLANProfile.name; Ssid = $x.WLANProfile.SSIDConfig.SSID.name }
        } catch { }
    }
    Remove-Item -LiteralPath $tmp -Recurse -Force
    return , $res
}

function Get-CurrentSsid {
    $r = Invoke-Native "$env:windir\System32\netsh.exe" 'wlan show interfaces'
    $m = [regex]::Match($r.Output, '(?m)^\s+SSID\s+:\s(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Menu-Wifi([hashtable]$Cfg) {
    Write-Title 'Trådløse nettverk'
    if (-not (Test-HasWifi)) { Write-Warn 'Fant ingen Wi-Fi på denne PC-en.' }
    Write-Info 'Filteret gjelder hele PC-en (også voksne), men bare administratorer kan endre det.'
    $modeTxt = @{ off = 'av'; allow = 'bare valgte nettverk er tillatt'; block = 'valgte nettverk er sperret' }
    Write-Info "Nå: $($modeTxt[$Cfg.Wifi.Mode]) $(if (@($Cfg.Wifi.Ssids).Count) { '(' + (@($Cfg.Wifi.Ssids) -join ', ') + ')' })"
    Write-Host ''
    Write-Host '  1. Bare tillat nettverk jeg velger (anbefalt: hjemme, skole, besteforeldre)'
    Write-Host '  2. Sperr bestemte nettverk'
    Write-Host '  3. Slå av Wi-Fi-filteret'
    Write-Host '  0. Ingen endring'
    $choice = Read-Host 'Valg'
    if ($choice -eq '3') { $Cfg.Wifi.Mode = 'off'; $Cfg.Wifi.Ssids = @() }
    elseif ($choice -in @('1', '2')) {
        $saved = Get-SavedSsids
        $names = @(@($saved | ForEach-Object { $_.Ssid }) + (Get-VisibleSsids) + @($Cfg.Wifi.Ssids) | Where-Object { $_ } | Sort-Object -Unique)
        $current = Get-CurrentSsid
        for ($i = 0; $i -lt $names.Count; $i++) {
            $tag = if ($names[$i] -eq $current) { ' (tilkoblet nå)' } else { '' }
            Write-Host ("  {0,3}. {1}{2}" -f ($i + 1), $names[$i], $tag)
        }
        $verb = if ($choice -eq '1') { 'tillate' } else { 'sperre' }
        $sel = @(Read-Numbers "Hvilke vil du $verb? (numre, for eksempel 1,3)" $names.Count | ForEach-Object { $names[$_ - 1] })
        while ($true) {
            $extra = Read-Text 'Legg til et nettverksnavn som ikke står i listen (Enter = ferdig)'
            if (-not $extra) { break }
            $sel += $extra
        }
        if ($choice -eq '1') {
            if ($current -and $sel -notcontains $current) {
                Write-Warn "Nettverket du er koblet til nå ('$current') er ikke valgt. PC-en mister nettet."
                if (Read-YesNo "Ta med '$current'?" $true) { $sel += $current }
            }
            if ($sel.Count -eq 0) { Write-Err 'Du må velge minst ett nettverk.'; Wait-Key; return }
            $Cfg.Wifi.Mode = 'allow'
        } else { $Cfg.Wifi.Mode = 'block' }
        $Cfg.Wifi.Ssids = @($sel | Sort-Object -Unique)
    }
    Write-Host ''
    Write-Info 'Barnet kan gå rundt Wi-Fi-filteret ved å koble en mobil til med USB eller Bluetooth (deling av mobilnett).'
    $Cfg.Wifi.BlockNewAdapters = Read-YesNo 'Hindre at nye nettverkskort installeres (USB-deling, USB-Wi-Fi)? Voksne kan slå det av her senere.' ([bool]$Cfg.Wifi.BlockNewAdapters -or $Cfg.Wifi.Mode -eq 'allow')
    $Cfg.Wifi.DisableBtPan = Read-YesNo 'Slå av Bluetooth-nettverk (deling av mobilnett over Bluetooth)?' ([bool]$Cfg.Wifi.DisableBtPan)
    Save-Config $Cfg
    Apply-Wifi $Cfg
}

function Apply-Wifi([hashtable]$Cfg, [switch]$Remove) {
    $netsh = "$env:windir\System32\netsh.exe"
    # Fjern filtrene vi la inn sist.
    foreach ($s in @($Cfg.Wifi.AppliedSsids)) {
        $perm = if ($Cfg.Wifi.AppliedMode -eq 'allow') { 'allow' } else { 'block' }
        [void](Invoke-Native $netsh "wlan delete filter permission=$perm ssid=`"$s`" networktype=infrastructure")
    }
    if ($Cfg.Wifi.AppliedMode -eq 'allow') { [void](Invoke-Native $netsh 'wlan delete filter permission=denyall networktype=infrastructure') }
    if ($Cfg.Wifi.AppliedMode -ne 'off') { [void](Invoke-Native $netsh 'wlan delete filter permission=denyall networktype=adhoc') }
    $Cfg.Wifi.AppliedMode = 'off'; $Cfg.Wifi.AppliedSsids = @()

    $mode = if ($Remove) { 'off' } else { $Cfg.Wifi.Mode }
    if ($mode -ne 'off') {
        $perm = if ($mode -eq 'allow') { 'allow' } else { 'block' }
        foreach ($s in $Cfg.Wifi.Ssids) {
            $r = Invoke-Native $netsh "wlan add filter permission=$perm ssid=`"$s`" networktype=infrastructure"
            if ($r.ExitCode -ne 0) { Write-Warn "Wi-Fi-filter for '$s' feilet: $($r.Output.Trim())" }
        }
        if ($mode -eq 'allow') { [void](Invoke-Native $netsh 'wlan add filter permission=denyall networktype=infrastructure') }
        [void](Invoke-Native $netsh 'wlan add filter permission=denyall networktype=adhoc')
        if ($mode -eq 'block') {
            foreach ($p in (Get-SavedSsids | Where-Object { $Cfg.Wifi.Ssids -contains $_.Ssid })) {
                [void](Invoke-Native $netsh "wlan delete profile name=`"$($p.Profile)`"")
            }
        }
        $Cfg.Wifi.AppliedMode = $mode; $Cfg.Wifi.AppliedSsids = @($Cfg.Wifi.Ssids)
        Write-Ok "Wi-Fi-filter: $(if ($mode -eq 'allow') {'bare'} else {'sperret:'}) $(@($Cfg.Wifi.Ssids) -join ', ')"
    } else {
        Write-Ok 'Wi-Fi-filteret er av.'
    }

    # Nye nettverkskort (USB-deling fra mobil, USB-Wi-Fi).
    $dev = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
    if (-not $Remove -and $Cfg.Wifi.BlockNewAdapters) {
        Set-ManagedHklm $Cfg $dev 'DenyDeviceClasses' 1
        Set-ManagedHklm $Cfg $dev 'DenyDeviceClassesRetroactive' 0
        Set-ManagedHklm $Cfg $dev 'AllowAdminInstall' 1
        Set-PcReg "$dev\DenyDeviceClasses" 'FK1' '{4d36e972-e325-11ce-bfc1-08002be10318}' 'String'
        Write-Ok 'Nye nettverkskort kan ikke installeres.'
    } else {
        Remove-PcReg "$dev\DenyDeviceClasses" 'FK1'
        foreach ($n in @('DenyDeviceClasses', 'DenyDeviceClassesRetroactive', 'AllowAdminInstall')) { Restore-ManagedHklm $Cfg $dev $n }
    }
    # Bluetooth-nettverk (PAN)
    $pan = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -like '*Personal Area Network*' })
    foreach ($a in $pan) {
        if (-not $Remove -and $Cfg.Wifi.DisableBtPan) { Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
        else { Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue }
    }
    Save-Config $Cfg
}

# ============================================================== 5. Nettfilter

function Menu-Web([hashtable]$Cfg, [switch]$Wizard) {
    Write-Title 'Nettfilter (voksensider, SafeSearch, DNS)'
    Write-Info 'PC-en bruker en familievennlig DNS-tjeneste som sperrer voksensider. Det gjelder hele PC-en.'
    Write-Info 'Nettleserne (Edge, Chrome, Brave, Firefox) får i barnets konto: ingen privat modus, tvunget'
    Write-Info 'SafeSearch og YouTube begrenset modus, ingen utvidelser (stopper VPN-utvidelser) og ingen egen DNS.'
    $Cfg.Web.Enabled = Read-YesNo 'Slå på nettfilteret?' $true
    if ($Cfg.Web.Enabled) {
        $keys = @($DnsProviders.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $p = $DnsProviders[$keys[$i]]
            $tag = if ($i -eq 0) { ' (anbefalt)' } else { '' }
            Write-Host ("  {0}. {1}{2}: {3}" -f ($i + 1), $p.Name, $tag, $p.Note)
        }
        $cur = [array]::IndexOf($keys, $Cfg.Web.Provider) + 1
        if ($cur -lt 1) { $cur = 1 }
        $n = Read-Numbers "Velg DNS-filter [$cur]" $keys.Count
        if ($n.Count) { $Cfg.Web.Provider = $keys[$n[0] - 1] }
        $Cfg.Web.BrowserPolicies = Read-YesNo 'Sette sperrer i nettleserne for barnet?' $true
        $Cfg.Web.BlockPublicDns = Read-YesNo 'Sperre andre kjente DNS-tjenere i brannmuren (så filteret ikke kan omgås)?' $true
    }
    Save-Config $Cfg
    Apply-Web $Cfg
}

function Apply-Web([hashtable]$Cfg, [switch]$Remove) {
    $on = $Cfg.Web.Enabled -and -not $Remove
    # Fjern det vi la inn sist.
    Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'FK-DNS*' } | Remove-NetFirewallRule
    foreach ($ip in @($Cfg.Web.DohAdded)) { Remove-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue }
    $Cfg.Web.DohAdded = @()

    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($on) {
        $p = $DnsProviders[$Cfg.Web.Provider]
        $Cfg.Web.Servers = @($p.V4) + @($p.V6)
        foreach ($nic in $nics) {
            try { Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $Cfg.Web.Servers } catch { Write-Warn "DNS på '$($nic.Name)': $($_.Exception.Message)" }
        }
        if (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
            foreach ($ip in $Cfg.Web.Servers) {
                if (-not (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)) {
                    try {
                        Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $p.DoH -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null
                        $Cfg.Web.DohAdded = @($Cfg.Web.DohAdded) + @($ip)
                    } catch { }
                }
            }
        }
        if ($Cfg.Web.BlockPublicDns) {
            New-NetFirewallRule -Name 'FK-DNS-ut' -DisplayName 'Foreldrekontroll: sperr andre DNS-tjenere' -Group $FwGroup `
                -Direction Outbound -Action Block -RemoteAddress $PublicDns -Profile Any | Out-Null
        }
        Clear-DnsClientCache
        Write-Ok "Nettfilter: $($p.Name) ($(@($p.V4) -join ', '))"
    } else {
        foreach ($nic in $nics) { Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue }
        $Cfg.Web.Servers = @()
        Write-Ok 'Nettfilteret er av (DNS hentes automatisk igjen).'
    }
    if (-not $Remove) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg @() } }
    Save-Config $Cfg
}

# ============================================================== 6. VPN og proxy

function Menu-Vpn([hashtable]$Cfg) {
    Write-Title 'VPN og proxy'
    Write-Info 'Barnet kan uansett ikke installere VPN-programmer når app-sperren er på (meny 3).'
    Write-Info 'Her sperres også VPN-en som er innebygd i Windows, vanlige VPN-porter og proxy-innstillinger.'
    Write-Info 'NB: Dette gjelder hele PC-en, også voksne. Slå det av her hvis du selv trenger VPN.'
    $Cfg.Vpn.Enabled = Read-YesNo 'Sperre VPN og proxy?' $true
    if ($Cfg.Vpn.Enabled) {
        $Cfg.Vpn.DisableBuiltin = Read-YesNo 'Slå av Windows sin innebygde VPN (tjenestene RasMan og SstpSvc)?' $true
        $Cfg.Vpn.BlockPorts = Read-YesNo 'Sperre VPN-porter i brannmuren (PPTP, L2TP, IKEv2, OpenVPN, WireGuard)?' $true
        $Cfg.Vpn.HideSettings = Read-YesNo 'Skjule VPN-, proxy- og mobilsone-sidene i Innstillinger for barnet?' $true
    }
    Save-Config $Cfg
    Apply-Vpn $Cfg
}

function Apply-Vpn([hashtable]$Cfg, [switch]$Remove) {
    $on = $Cfg.Vpn.Enabled -and -not $Remove
    Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'FK-VPN*' } | Remove-NetFirewallRule
    $proxy = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($on) {
        foreach ($s in @('RasMan', 'SstpSvc')) { Set-ManagedService $Cfg $s ([bool]$Cfg.Vpn.DisableBuiltin) }
        if ($Cfg.Vpn.BlockPorts) {
            $rules = @(
                @{ N = 'FK-VPN-pptp';      D = 'PPTP';             P = 'TCP'; Port = '1723' }
                @{ N = 'FK-VPN-udp';       D = 'L2TP/IKEv2/OpenVPN/WireGuard (UDP)'; P = 'UDP'; Port = @('500', '1701', '4500', '1194', '51820') }
                @{ N = 'FK-VPN-openvpn';   D = 'OpenVPN (TCP)';    P = 'TCP'; Port = '1194' }
            )
            foreach ($r in $rules) {
                New-NetFirewallRule -Name $r.N -DisplayName "Foreldrekontroll: sperr $($r.D)" -Group $FwGroup -Direction Outbound `
                    -Action Block -Protocol $r.P -RemotePort $r.Port -Profile Any | Out-Null
            }
            New-NetFirewallRule -Name 'FK-VPN-gre' -DisplayName 'Foreldrekontroll: sperr GRE (PPTP)' -Group $FwGroup -Direction Outbound `
                -Action Block -Protocol 47 -Profile Any | Out-Null
        }
        Set-ManagedHklm $Cfg $proxy 'ProxySettingsPerUser' 0
        Write-Ok 'VPN og proxy er sperret.'
    } else {
        foreach ($s in @('RasMan', 'SstpSvc')) { Set-ManagedService $Cfg $s $false }
        Restore-ManagedHklm $Cfg $proxy 'ProxySettingsPerUser'
        Write-Ok 'VPN-sperren er av.'
    }
    if (-not $Remove) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg @() } }
    Save-Config $Cfg
}

# ============================================================== 7. Ekstra sikring

function Menu-Extra([hashtable]$Cfg) {
    Write-Title 'Ekstra sikring'
    Write-Info 'Tidssone: vanlige brukere kan bytte tidssone og dermed flytte klokka og få mer skjermtid.'
    $Cfg.Extra.TimeZone = Read-YesNo 'Hindre at barnet bytter tidssone?' $true
    Write-Info 'Registerredigering: hindrer barnet i å åpne regedit.'
    $Cfg.Extra.RegEdit = Read-YesNo 'Sperre registerredigering for barnet?' ([bool]$Cfg.Extra.RegEdit)
    Write-Info 'Gjenopprettingsmiljøet (WinRE) kan brukes til å starte i sikkermodus, der sperrene er svakere.'
    Write-Info 'Slår du det av, mister PC-en også de innebygde reparasjonsverktøyene til du slår det på igjen her.'
    $Cfg.Extra.WinRE = Read-YesNo 'Slå av gjenopprettingsmiljøet?' ([bool]$Cfg.Extra.WinRE)
    Save-Config $Cfg
    Apply-Extra $Cfg
    Write-Host ''
    Write-Info 'Tips som skriptet ikke kan gjøre for deg:'
    Write-Info ' * Sett et BIOS/UEFI-passord og slå av oppstart fra USB.'
    Write-Info ' * Slå på BitLocker/enhetskryptering, og hold gjenopprettingsnøkkelen for deg selv.'
    Write-Info ' * Gi administratorkontoen et passord barnet ikke kjenner.'
}

function Set-TimeZonePrivilege([hashtable]$Cfg, [bool]$Restrict) {
    $dir = Join-Path $InstallDir 'secedit'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $exp = Join-Path $dir 'eksport.inf'; $imp = Join-Path $dir 'import.inf'; $db = Join-Path $dir 'secedit.sdb'
    [void](Invoke-Native "$env:windir\System32\secedit.exe" "/export /cfg `"$exp`" /areas USER_RIGHTS")
    $line = (Get-Content -LiteralPath $exp -Encoding Unicode | Where-Object { $_ -match '^SeTimeZonePrivilege\s*=' } | Select-Object -First 1)
    if ($Restrict) {
        if (-not $Cfg.Backup.TimeZoneLine) { $Cfg.Backup.TimeZoneLine = if ($line) { $line } else { 'SeTimeZonePrivilege = *S-1-5-19,*S-1-5-32-544,*S-1-5-32-545' } }
        $new = 'SeTimeZonePrivilege = *S-1-5-19,*S-1-5-32-544'
    } else {
        if (-not $Cfg.Backup.TimeZoneLine) { Remove-Item -LiteralPath $dir -Recurse -Force; return }
        $new = $Cfg.Backup.TimeZoneLine
    }
    $inf = "[Unicode]`r`nUnicode=yes`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n[Privilege Rights]`r`n$new`r`n"
    Set-Content -LiteralPath $imp -Value $inf -Encoding Unicode
    $r = Invoke-Native "$env:windir\System32\secedit.exe" "/configure /db `"$db`" /cfg `"$imp`" /areas USER_RIGHTS /quiet"
    if ($r.ExitCode -ne 0) { Write-Warn "secedit: $($r.Output.Trim())" } elseif (-not $Restrict) { $Cfg.Backup.TimeZoneLine = '' }
    Remove-Item -LiteralPath $dir -Recurse -Force
}

function Apply-Extra([hashtable]$Cfg, [switch]$Remove) {
    $tz = $Cfg.Extra.TimeZone -and -not $Remove
    Set-TimeZonePrivilege $Cfg $tz
    if ($tz) { Write-Ok 'Barn kan ikke bytte tidssone.' }
    if ($Cfg.Extra.WinRE -and -not $Remove) {
        $r = Invoke-Native "$env:windir\System32\reagentc.exe" '/disable'
        if ($r.ExitCode -eq 0) { $Cfg.Backup.WinREDisabledByUs = $true; Write-Ok 'Gjenopprettingsmiljøet er slått av.' }
        else { Write-Warn "reagentc: $($r.Output.Trim())" }
    } elseif ($Cfg.Backup.WinREDisabledByUs) {
        $r = Invoke-Native "$env:windir\System32\reagentc.exe" '/enable'
        if ($r.ExitCode -eq 0) { $Cfg.Backup.WinREDisabledByUs = $false; Write-Ok 'Gjenopprettingsmiljøet er slått på igjen.' }
        else { Write-Warn "reagentc: $($r.Output.Trim())" }
    }
    if (-not $Remove) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg @() } }
    Save-Config $Cfg
}

# ============================================================== 9. Status

function Show-Status([hashtable]$Cfg) {
    Write-Title 'Status'
    Write-Host '  Barnekontoer' -ForegroundColor White
    Show-Children $Cfg

    Write-Host "`n  Skjermtid" -ForegroundColor White
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Cfg.ScreenTime.Enabled) { Write-Ok 'På' } else { Write-Info 'Av' }
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Info "Håndhever-oppgaven: $($task.State), sist kjørt $($info.LastRunTime), resultat $($info.LastTaskResult)"
    } elseif ($Cfg.ScreenTime.Enabled -or $Cfg.Web.Enabled) { Write-Err 'Håndhever-oppgaven mangler. Velg "Bruk alle innstillinger på nytt".' }
    Show-UsageToday $Cfg

    Write-Host "`n  Apper og spill" -ForegroundColor White
    if (-not $Cfg.Apps.Enabled) { Write-Info 'Av' }
    elseif (Test-IsHomeEdition) { Write-Ok 'På (Software Restriction Policies i barnets profil)' }
    else {
        try {
            $pol = Get-AppLockerPolicy -Effective
            foreach ($rc in $pol.RuleCollections) { Write-Info ("{0,-7} {1,-14} {2} regler" -f $rc.RuleCollectionType, $rc.EnforcementMode, @($rc).Count) }
        } catch { Write-Warn "Kunne ikke lese AppLocker: $($_.Exception.Message)" }
        $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') { Write-Ok 'Tjenesten Application Identity kjører' } else { Write-Err "Tjenesten Application Identity: $($svc.Status)" }
    }
    Write-Info "Sperret for barnet: $(@($Cfg.Apps.DenyPaths).Count) mapper, $(@($Cfg.Apps.DenyPackages).Count) Store-apper. Ekstra tillatt: $(@($Cfg.Apps.AllowPaths).Count) mapper."

    Write-Host "`n  Trådløse nettverk" -ForegroundColor White
    Write-Info "Modus: $($Cfg.Wifi.Mode) $(@($Cfg.Wifi.Ssids) -join ', ')"
    $f = Invoke-Native "$env:windir\System32\netsh.exe" 'wlan show filters'
    foreach ($l in ($f.Output -split "`r?`n" | Where-Object { $_.Trim() })) { Write-Info $l.TrimEnd() }

    Write-Host "`n  Nettfilter" -ForegroundColor White
    foreach ($nic in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses }) -join ', '
        Write-Info "$($nic.Name) ($($nic.Status)): $dns"
    }

    Write-Host "`n  VPN og brannmur" -ForegroundColor White
    $fw = @(Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue)
    Write-Info "Brannmurregler fra foreldrekontrollen: $($fw.Count)"
    foreach ($s in @('RasMan', 'SstpSvc', 'AppIDSvc')) {
        $svc = Get-Service $s -ErrorAction SilentlyContinue
        if ($svc) { Write-Info "Tjeneste ${s}: $($svc.StartType), $($svc.Status)" }
    }

    Write-Host "`n  Ekstra" -ForegroundColor White
    Write-Info "Tidssone sperret: $([bool]$Cfg.Extra.TimeZone),  regedit sperret: $([bool]$Cfg.Extra.RegEdit),  WinRE av: $([bool]$Cfg.Backup.WinREDisabledByUs)"

    Write-Host "`n  Kjente begrensninger" -ForegroundColor White
    Write-Info 'DNS-filter, Wi-Fi-filter og VPN-sperre gjelder hele PC-en, også voksne.'
    Write-Info 'Steam/Epic som er tillatt for barnet kan fortsatt hente gratisspill inne i klienten (bruk Steam Family View).'
    Write-Info 'Sikkermodus og oppstart fra USB stoppes bare helt med BIOS-passord og BitLocker.'
}

# ============================================================== 10/11. Bruk på nytt og fjern

function Invoke-ApplyAll([hashtable]$Cfg) {
    Write-Title 'Tar i bruk alle innstillinger'
    $steps = @(
        @{ N = 'Skjermtid';    S = { Apply-ScreenTime $Cfg } }
        @{ N = 'Apper';        S = { Apply-Apps $Cfg } }
        @{ N = 'Wi-Fi';        S = { Apply-Wifi $Cfg } }
        @{ N = 'Nettfilter';   S = { Apply-Web $Cfg } }
        @{ N = 'VPN';          S = { Apply-Vpn $Cfg } }
        @{ N = 'Ekstra';       S = { Apply-Extra $Cfg } }
    )
    foreach ($s in $steps) {
        try { & $s.S } catch { Write-Err "$($s.N): $($_.Exception.Message)" }
    }
    Save-Config $Cfg
}

function Invoke-RemoveAll([hashtable]$Cfg) {
    Write-Title 'Fjern all foreldrekontroll'
    if (-not (Read-YesNo 'Er du sikker på at du vil fjerne alle sperrene?' $false)) { return }
    $steps = @(
        @{ N = 'Oppgave';    S = { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue; Write-Ok 'Håndhever-oppgaven er fjernet.' } }
        @{ N = 'Påloggingstider'; S = { $Cfg.ScreenTime.Enabled = $false; foreach ($c in $Cfg.Children) { Set-LogonHours $Cfg $c } } }
        @{ N = 'Apper';      S = {
            $Cfg.Apps.Enabled = $false
            if (-not (Test-IsHomeEdition)) { Set-AppLockerFromXml (Get-EmptyAppLockerXml); Write-Ok 'AppLocker-reglene er fjernet.' }
            Restore-ManagedHklm $Cfg 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Installer' 'DisableUserInstalls'
            Restore-ManagedHklm $Cfg 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorUser' } }
        @{ N = 'Wi-Fi';      S = { Apply-Wifi $Cfg -Remove } }
        @{ N = 'Nettfilter'; S = { Apply-Web $Cfg -Remove } }
        @{ N = 'VPN';        S = { Apply-Vpn $Cfg -Remove } }
        @{ N = 'Ekstra';     S = { Apply-Extra $Cfg -Remove } }
        @{ N = 'Brannmur';   S = { Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule } }
        @{ N = 'Barnas profiler'; S = { foreach ($c in $Cfg.Children) { if (Get-LocalUser -SID $c.Sid -ErrorAction SilentlyContinue) { Set-ChildHive $c $Cfg @() $true; Write-Ok "Sperrer fjernet fra profilen til $($c.Name)." } } } }
    )
    foreach ($s in $steps) {
        try { & $s.S } catch { Write-Err "$($s.N): $($_.Exception.Message)" }
    }
    # Gjenstående sikkerhetskopier (for eksempel verdier fra tidligere versjoner).
    foreach ($k in @($Cfg.Backup.Registry.Keys)) { $p = $k.Split('|'); Restore-ManagedHklm $Cfg $p[0] $p[1] }
    foreach ($s in @($Cfg.Backup.Services.Keys)) { Set-ManagedService $Cfg $s $false }
    $Cfg.ScreenTime.Enabled = $false; $Cfg.Web.Enabled = $false; $Cfg.Vpn.Enabled = $false
    $Cfg.Wifi.Mode = 'off'; $Cfg.Extra.TimeZone = $false; $Cfg.Extra.WinRE = $false; $Cfg.Extra.RegEdit = $false
    Save-Config $Cfg
    if ((Test-IsHomeEdition) -and @($Cfg.Children).Count) {
        Write-Info 'Windows Home: Store-appen ble fjernet for barnet. Logg inn som barnet og kjør wsreset -i for å få den tilbake.'
    }
    foreach ($c in @($Cfg.Children)) {
        if ((Get-LocalUser -SID $c.Sid -ErrorAction SilentlyContinue) -and (Read-YesNo "Slette kontoen $($c.Name) også (filene i profilen blir liggende)?" $false)) {
            Remove-LocalUser -SID $c.Sid
            $Cfg.Children = @($Cfg.Children | Where-Object { $_.Sid -ne $c.Sid })
            Write-Ok "Kontoen $($c.Name) er slettet."
        }
    }
    Save-Config $Cfg
    Write-Ok 'Foreldrekontrollen er fjernet. Start PC-en på nytt for at alt skal gjelde fullt ut.'
}

# ============================================================== Hurtigoppsett og meny

function Invoke-Wizard([hashtable]$Cfg) {
    Write-Title 'Hurtigoppsett'
    Write-Info 'Vi går gjennom alt steg for steg. Du kan endre hver del senere fra menyen.'
    if (@($Cfg.Children).Count -eq 0 -or (Read-YesNo 'Vil du legge til eller endre barnekontoer?' (@($Cfg.Children).Count -eq 0))) { Menu-Children $Cfg }
    if (@($Cfg.Children).Count -eq 0) { Write-Err 'Ingen barnekonto er valgt, så oppsettet stopper her.'; return }
    Menu-ScreenTime $Cfg -Wizard
    Menu-Apps $Cfg -Wizard
    Menu-Wifi $Cfg
    Menu-Web $Cfg -Wizard
    Menu-Vpn $Cfg
    Menu-Extra $Cfg
    Show-Status $Cfg
    Write-Host ''
    Write-Ok 'Ferdig. Barnet må logge av og på (eller PC-en startes på nytt) før alt gjelder.'
}

function Show-Menu {
    Write-Host ''
    Write-Host '  FORELDREKONTROLL FOR WINDOWS 11' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '   H. Hurtigoppsett (anbefalt første gang)'
    Write-Host '   1. Barnekontoer'
    Write-Host '   2. Skjermtid'
    Write-Host '   3. Apper og spill'
    Write-Host '   4. Trådløse nettverk'
    Write-Host '   5. Nettfilter (voksensider, SafeSearch, DNS)'
    Write-Host '   6. VPN og proxy'
    Write-Host '   7. Ekstra sikring'
    Write-Host '   8. Gi ekstra tid i dag'
    Write-Host '   9. Vis status'
    Write-Host '  10. Bruk alle innstillinger på nytt'
    Write-Host '  11. Fjern all foreldrekontroll'
    Write-Host '   0. Avslutt'
}

function Start-Main {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Skriptet må kjøres som administrator. Starter på nytt med administratorrettigheter ...'
        $args2 = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($BrukPaaNytt) { $args2 += ' -BrukPaaNytt' }
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args2 -Verb RunAs
        return
    }
    $cfg = Get-Config
    if ($BrukPaaNytt) { Invoke-ApplyAll $cfg; return }
    while ($true) {
        Show-Menu
        $c = (Read-Host "`n  Valg").Trim()
        try {
            switch ($c) {
                { $_ -ieq 'h' } { Invoke-Wizard $cfg; Wait-Key }
                '1'  { Menu-Children $cfg }
                '2'  { if (@($cfg.Children).Count) { Menu-ScreenTime $cfg } else { Write-Warn 'Velg en barnekonto først (1).' }; Wait-Key }
                '3'  { if (@($cfg.Children).Count) { Menu-Apps $cfg } else { Write-Warn 'Velg en barnekonto først (1).' }; Wait-Key }
                '4'  { Menu-Wifi $cfg; Wait-Key }
                '5'  { Menu-Web $cfg; Wait-Key }
                '6'  { Menu-Vpn $cfg; Wait-Key }
                '7'  { Menu-Extra $cfg; Wait-Key }
                '8'  { Menu-Bonus $cfg; Wait-Key }
                '9'  { Show-Status $cfg; Wait-Key }
                '10' { Invoke-ApplyAll $cfg; Wait-Key }
                '11' { Invoke-RemoveAll $cfg; Wait-Key }
                '0'  { return }
            }
        } catch {
            Write-Err "Noe gikk galt: $($_.Exception.Message)"
            Write-Info "($($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber))"
            Wait-Key
        }
    }
}

# Kan "dot-sources" for testing uten at menyen starter.
if ($MyInvocation.InvocationName -ne '.') { Start-Main }
