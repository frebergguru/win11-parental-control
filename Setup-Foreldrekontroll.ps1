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
    [switch]$BrukPaaNytt,
    # Brukes av oppgaven "Foreldrekontroll etter oppdatering": bruker alt på nytt bare hvis Windows
    # er oppdatert siden sist, eller hvis en sperre mangler.
    [switch]$EtterOppdatering
)

$ErrorActionPreference = 'Stop'

# ============================================================== Konstanter

$InstallDir  = "$env:ProgramFiles\Foreldrekontroll"
$ConfigPath  = "$InstallDir\config.json"
$UsagePath   = "$InstallDir\usage.json"
$WifiStatePath = "$InstallDir\wifi-sperret.json"
$TaskName    = 'Foreldrekontroll'
$UpdateTaskName = 'Foreldrekontroll etter oppdatering'
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
    '%WINDIR%\System32\wsl.exe', '%WINDIR%\System32\bash.exe',
    # .NET-kompilatorer og verktøy (MSBuild, csc, InstallUtil) kan kjøre egen kode.
    '%WINDIR%\Microsoft.NET\*',
    '%WINDIR%\System32\regsvr32.exe', '%WINDIR%\SysWOW64\regsvr32.exe',
    '%WINDIR%\System32\cmstp.exe', '%WINDIR%\SysWOW64\cmstp.exe'
)
# Samme verktøy sperres også etter filnavnet i signaturen, så kopier (for eksempel i WinSxS) også stoppes.
$ChildDeniedBinaries = @('CMD.EXE', 'POWERSHELL.EXE', 'POWERSHELL_ISE.EXE', 'PWSH.DLL', 'MSBUILD.EXE', 'CSC.EXE',
    'VBC.EXE', 'INSTALLUTIL.EXE', 'REGASM.EXE', 'REGSVCS.EXE', 'REGSVR32.EXE', 'MSHTA.EXE', 'WSCRIPT.EXE', 'CSCRIPT.EXE', 'CMSTP.EXE')
$MsPublisher = 'O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US'

# Spillklienter (kjennes igjen på navn eller sti).
$LauncherPattern = '(?i)steam|epic games|EpicGamesLauncher|\bEA app\b|EA Desktop|EADesktop|Origin|Battle\.net|Ubisoft|uplay|Riot Client|GOG Galaxy|Rockstar Games Launcher'
# Mapper for antijuks og spilltjenester (Fortnite, Battlefield og andre trenger dem).
$GameServiceDirs = @(
    '%ProgramFiles(x86)%\Epic Games\Epic Online Services', '%ProgramFiles(x86)%\EasyAntiCheat_EOS',
    '%ProgramFiles(x86)%\EasyAntiCheat', '%ProgramFiles(x86)%\Common Files\BattlEye',
    '%ProgramFiles%\EA\AC', '%ProgramFiles%\Common Files\EAInstaller', '%ProgramFiles(x86)%\Common Files\Steam',
    '%ProgramData%\Battle.net\Agent'
)

$StorePackages = @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.StorePurchaseApp')
$XboxPackages  = @('Microsoft.GamingApp', 'Microsoft.XboxApp')

# ============================================================== Språk

# Norsk tekst er nøkkelen; oversettelser ligger i lang\<kode>.psd1 (for eksempel lang\uk.psd1).
$script:Lang = 'nb'
$script:Tr = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$Languages = [ordered]@{ nb = 'Norsk (bokmål)'; uk = 'Українська' }

function Import-Language([string]$Code) {
    $script:Lang = 'nb'
    $script:Tr.Clear()
    if ($Code -eq 'nb' -or -not $Code) { return }
    foreach ($dir in @("$(Split-Path -Parent $PSCommandPath)\lang", "$InstallDir\lang")) {
        $f = "$dir\$Code.psd1"
        if (-not (Test-Path -LiteralPath $f)) { $f = [IO.Path]::Combine((Split-Path -Parent $PSCommandPath), 'lang', "$Code.psd1") }
        if (Test-Path -LiteralPath $f) {
            $data = Import-PowerShellDataFile -LiteralPath $f
            foreach ($k in $data.Keys) { $script:Tr[[string]$k] = [string]$data[$k] }
            $script:Lang = $Code
            return
        }
    }
    Write-Host "Language file lang\$Code.psd1 not found, using Norwegian." -ForegroundColor Yellow
}

function T([string]$Text) {
    # Oversetter en tekst. Mellomrom foran beholdes. Ekstra argumenter settes inn i {0}, {1} ...
    $lead = $Text.Length - $Text.TrimStart().Length
    $core = $Text.Trim()
    $val = $null
    if ($script:Lang -ne 'nb' -and $core -and $script:Tr.TryGetValue($core, [ref]$val)) { $core = $val }
    $out = (' ' * $lead) + $core
    if ($args.Count -gt 0) { $out = $out -f $args }
    return $out
}

function ConvertTo-MenuKey([string]$Text) {
    # Menybokstaver tastet med ukrainsk (eller russisk) tastaturoppsett gir kyrilliske tegn på de
    # samme tastene. Gjør dem om til latinske bokstaver, så H, L, G, S, X og M virker uansett oppsett.
    $map = @{ 'р' = 'h'; 'д' = 'l'; 'п' = 'g'; 'і' = 's'; 'ы' = 's'; 'ч' = 'x'; 'ь' = 'm' }
    $t = $Text.Trim().ToLowerInvariant()
    if ($map.ContainsKey($t)) { return $map[$t] }
    return $t
}

function Select-Language([hashtable]$Cfg) {
    Write-Host ''
    Write-Host '  Velg språk / Оберіть мову:' -ForegroundColor Cyan
    $codes = @($Languages.Keys)
    for ($i = 0; $i -lt $codes.Count; $i++) { Write-Host ("   {0}. {1}" -f ($i + 1), $Languages[$codes[$i]]) }
    while ($true) {
        $a = (Read-Host '  1/2').Trim()
        $n = 0
        if ([int]::TryParse($a, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -ge 1 -and $n -le $codes.Count) { break }
    }
    $Cfg.Language = $codes[$n - 1]
    Import-Language $Cfg.Language
}

# ============================================================== Hjelpere for inndata

function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
    Write-Host (' ' + (T $Text @args)) -ForegroundColor Cyan
    Write-Host ('=' * 70) -ForegroundColor DarkCyan
}
function Write-Ok([string]$Text)   { Write-Host ('  [OK] ' + (T $Text @args)) -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host ('  [!]  ' + (T $Text @args)) -ForegroundColor Yellow }
function Write-Err([string]$Text)  { Write-Host ('  [X]  ' + (T $Text @args)) -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host ('       ' + (T $Text @args)) -ForegroundColor Gray }

function Wait-Key { [void](Read-Host ("`n" + (T 'Trykk Enter for å fortsette'))) }

function Read-YesNo([string]$Prompt, [bool]$Default = $true) {
    $y = T 'j'; $n = T 'n'
    $hint = if ($Default) { '[{0}/{1}]' -f $y.ToUpperInvariant(), $n } else { '[{0}/{1}]' -f $y, $n.ToUpperInvariant() }
    while ($true) {
        $a = (Read-Host ((T $Prompt) + ' ' + $hint)).Trim().ToLowerInvariant()
        if ($a -eq '') { return $Default }
        # Kyrilliske svar godtas bare i det ukrainske grensesnittet. Med ukrainsk tastatur gir N-tasten
        # 'т' (ja), så i det norske grensesnittet kunne et "nei" ellers blitt et "ja".
        $yes = @('j', 'ja', 'y', 'yes'); $no = @('n', 'nei', 'no')
        if ($script:Lang -eq 'uk') { $yes += @('т', 'так'); $no += @('н', 'ні') }
        if ($a -in $yes) { return $true }
        if ($a -in $no) { return $false }
        Write-Warn 'Svar j eller n.'
    }
}

function Read-Text([string]$Prompt, [string]$Default = '') {
    $p = T $Prompt
    if ($Default) { $p = "$p [$Default]" }
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

function Test-NoLimitWord([string]$Text) {
    return ($Text -in @('ingen', '-', '-1', 'без', 'немає', (T 'ingen')))
}

function Read-Limit([string]$Prompt, $Default) {
    $d = if ($Default -lt 0) { T 'ingen' } else { [string]$Default }
    while ($true) {
        $a = Read-Text ((T $Prompt) + ' ' + (T "(minutter, 0 = ingen tilgang, '{0}' = ingen grense)" (T 'ingen'))) $d
        if (Test-NoLimitWord $a) { return -1 }
        $n = 0
        if ([int]::TryParse($a, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -ge 0 -and $n -le 1440) { return $n }
        Write-Warn "Skriv et tall mellom 0 og 1440, eller '{0}'." (T 'ingen')
    }
}

function Read-Numbers([string]$Prompt, [int]$Max) {
    # "1,3,5-7" til en liste med tall.
    $a = Read-Host (T $Prompt)
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
        Language   = ''
        Children   = @()
        ScreenTime = @{ Enabled = $false; Days = $days; Warn = @(10, 3) }
        Bonus      = @{ Date = ''; Minutes = 0 }
        Apps       = @{
            Enabled = $false; AllowPaths = @(); DenyPaths = @(); DenyPackages = @()
            BlockStore = $true; BlockXbox = $true; BlockTools = $true; StrictUac = $true; WritableDirs = @(); TrustedSids = @()
        }
        Wifi       = @{
            Mode = 'off'; Ssids = @(); BlockNewAdapters = $false; DisableBtPan = $true; AppliedMode = 'off'; AppliedSsids = @()
            # Nettverk med disse navnene pluss et tall (Anlegg1, Anlegg2, ...) er alltid sperret.
            BlockPrefixes = @('Anlegg'); PrefixMax = 50; AppliedPrefixSsids = @()
        }
        Web        = @{ Enabled = $false; Provider = 'cleanbrowsing'; Servers = @(); BrowserPolicies = $true; BlockPublicDns = $true; DohAdded = @() }
        Vpn        = @{ Enabled = $false; DisableBuiltin = $true; BlockPorts = $true; HideSettings = $true }
        Extra      = @{ TimeZone = $false; WinRE = $false; RegEdit = $true }
        AutoReapply = @{ Enabled = $true; LastBuild = ''; LastRun = ''; LastCheck = ''; LastFailDay = '' }
        Backup     = @{
            Registry = @{}; Services = @{}; TimeZoneLine = ''; WinREDisabledByUs = $false; StoreRemovedFor = @()
            OneDrive = @{}; Dns = @{}; BtPanDisabled = @(); AppLockerSaved = $false
        }
    }
}

function Get-Config {
    # Returnerer $null hvis konfigurasjonen finnes, men verken den eller sikkerhetskopien kan leses.
    # Da må vi aldri fortsette med standardverdier: de ville skrevet over alle sikkerhetskopiene.
    $cfg = Get-DefaultConfig
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return $cfg }
    foreach ($f in @($ConfigPath, "$ConfigPath.bak")) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $loaded = ConvertTo-PcHashtable (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json)
            if ($loaded -isnot [hashtable] -or -not $loaded.ContainsKey('Version')) { throw (T 'ugyldig innhold') }
            if ($f -ne $ConfigPath) { Write-Warn 'Konfigurasjonen var skadet. Sikkerhetskopien ({0}) brukes.' $f }
            return (Merge-PcDefaults $cfg $loaded)
        } catch {
            Write-Warn "Kunne ikke lese {0} ({1})." $f $($_.Exception.Message)
        }
    }
    return $null
}

function Save-Config([hashtable]$Cfg) {
    # Skriv til en midlertidig fil og bytt den inn, så et strømbrudd aldri etterlater en halv fil.
    # Forrige versjon blir liggende som config.json.bak.
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $tmp = "$ConfigPath.tmp"
    $json = $Cfg | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $true))
    if (Test-Path -LiteralPath $ConfigPath) { [IO.File]::Replace($tmp, $ConfigPath, "$ConfigPath.bak") }
    else { [IO.File]::Move($tmp, $ConfigPath) }
}

function Lock-Settings {
    # Bare én kjøring om gangen (menyen eller oppgaven etter oppdateringer). Låsefilen kan bare
    # SYSTEM og administratorer åpne, så et barn kan ikke holde den.
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $f = "$InstallDir\.laas"
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $fs = [IO.File]::Open($f, 'OpenOrCreate', 'ReadWrite', 'None')
            try {
                $acl = New-Object Security.AccessControl.FileSecurity
                $acl.SetAccessRuleProtection($true, $false)
                foreach ($sid in @('S-1-5-18', $SidAdmins)) {
                    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'Allow')))
                }
                Set-Acl -LiteralPath $f -AclObject $acl -ErrorAction SilentlyContinue
            } catch { }
            return $fs
        } catch {
            if ($i -eq 0) { Write-Info 'Venter på at en annen kjøring av foreldrekontrollen blir ferdig ...' }
            Start-Sleep -Seconds 2
        }
    }
    return $null
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
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    # Konsollprogrammer skriver med systemets OEM-tegnsett (systemlokalet), ikke brukerens formatvalg.
    try {
        $oem = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -ErrorAction Stop).OEMCP
        $psi.StandardOutputEncoding = [Text.Encoding]::GetEncoding($oem)
    } catch { }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()   # for eksempel gpupdate kan spørre om omstart; tom inndata svarer nei
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{ ExitCode = $p.ExitCode; Output = ($out + $err) }
}

function Get-StableGuid([string]$Text) {
    # Samme tekst gir alltid samme GUID, så en uendret AppLocker-policy blir byte for byte lik.
    $md5 = [Security.Cryptography.MD5]::Create()
    return (New-Object Guid (, $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).ToString()
}

function Set-PcFirewallRule([string]$Name, [string]$Display, [hashtable]$Params) {
    # Lager en utgående sperreregel bare hvis den mangler eller er annerledes (ingen glipp i sperren).
    $sigText = (@($Params.Keys | Sort-Object | ForEach-Object { "$_=" + (@($Params[$_]) -join ',') }) -join ';')
    $sig = 'Foreldrekontroll ' + (Get-StableGuid $sigText)
    $old = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if ($old -and $old.Description -eq $sig) { return }
    if ($old) { $old | Remove-NetFirewallRule }
    New-NetFirewallRule -Name $Name -DisplayName $Display -Description $sig -Group $FwGroup -Direction Outbound -Action Block -Profile Any @Params | Out-Null
}

function Remove-PcFirewallRules([string]$Prefix, [string[]]$Keep) {
    Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "$Prefix*" -and @($Keep) -notcontains $_.Name } | Remove-NetFirewallRule
}

function ConvertTo-PcIp([string]$Address) {
    try { return ([Net.IPAddress]::Parse($Address)).ToString() } catch { return $Address }
}

function Test-NicDns($Nic, [string[]]$Want) {
    # Sant hvis kortet allerede har akkurat disse DNS-tjenerne (per adressefamilie).
    foreach ($family in @(2, 23)) {
        $w = @($Want | Where-Object { ($_ -like '*:*') -eq ($family -eq 23) } | ForEach-Object { ConvertTo-PcIp $_ })
        if ($w.Count -eq 0) { continue }
        $have = @(Get-DnsClientServerAddress -InterfaceIndex $Nic.ifIndex -AddressFamily $family -ErrorAction SilentlyContinue |
                  ForEach-Object { $_.ServerAddresses } | Where-Object { $_ } | ForEach-Object { ConvertTo-PcIp $_ })
        if (Compare-Object -ReferenceObject $w -DifferenceObject @($have) -SyncWindow 0) { return $false }
    }
    return $true
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
    if ($hr -ne 0 -and $hr -ne -2147024713) { throw (T "Kunne ikke lage brukerprofil for {0} (HRESULT 0x{1:X8})." $($Child.Name) $hr) }
    $p = Get-PcReg $key 'ProfileImagePath'
    if (-not $p) { throw (T "Fant ikke brukerprofilen til {0}." $($Child.Name)) }
    return [Environment]::ExpandEnvironmentVariables($p)
}

function Invoke-WithChildHive([hashtable]$Child, [scriptblock]$Script) {
    $loaded = "Registry::HKEY_USERS\$($Child.Sid)"
    if (Test-Path -LiteralPath $loaded) { & $Script $loaded; return }
    $hive  = Join-Path (Get-ChildProfilePath $Child) 'NTUSER.DAT'
    $mount = 'FK_' + ($Child.Sid -replace '[^0-9]', '')
    $r = Invoke-Native "$env:windir\System32\reg.exe" "load `"HKU\$mount`" `"$hive`""
    if ($r.ExitCode -ne 0) { throw (T "Kunne ikke åpne registeret til {0}: {1}" $($Child.Name) $($r.Output.Trim())) }
    try {
        & $Script "Registry::HKEY_USERS\$mount"
    } finally {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300
        $u = Invoke-Native "$env:windir\System32\reg.exe" "unload `"HKU\$mount`""
        if ($u.ExitCode -ne 0) {
            Start-Sleep -Seconds 2; [GC]::Collect()
            $u = Invoke-Native "$env:windir\System32\reg.exe" "unload `"HKU\$mount`""
            if ($u.ExitCode -ne 0) { Write-Warn "Registeret til {0} kunne ikke lukkes. Start PC-en på nytt før barnet logger på." $($Child.Name) }
        }
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
    # Barnet, eieren (OWNER RIGHTS), pakkeapper (ALL APPLICATION PACKAGES) og RESTRICTED får bare lese.
    foreach ($s in @($ChildSid, 'S-1-3-4', 'S-1-15-2-1', 'S-1-5-12')) {
        $id = New-Object Security.Principal.SecurityIdentifier $s
        $acl.AddAccessRule((New-Object Security.AccessControl.RegistryAccessRule($id, 'ReadKey', $inh, $none, 'Allow')))
    }
    # Administratorer eier nøkkelen, ellers kunne barnet som eier gi seg selv skrivetilgang.
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier $SidAdmins))
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
    if (-not $Cfg.Apps.Enabled) {
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        return
    }
    $ci = "$base\CodeIdentifiers"
    # Nye regler legges til før de gamle fjernes, og "sperr alt annet" settes til slutt, så barnet
    # aldri blir sperret ute fra spill og programmer mens reglene skrives på nytt.
    $old = @()
    foreach ($lvl in @('262144', '0')) {
        $pk = "$ci\$lvl\Paths"
        if (Test-Path -LiteralPath $pk) { $old += @(Get-ChildItem -LiteralPath $pk | ForEach-Object { $_.PSPath }) }
    }
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
    # Skrivbare mapper som en voksen har tillatt (for eksempel spill i Steam), skal ikke sperres:
    # i SRP vinner sperren når to regler er like spesifikke, og undermapper er mer spesifikke.
    $deny = @($WritableDirs | Where-Object { -not (Test-UnderAny $_ @($Cfg.Apps.AllowPaths)) }) + @($Cfg.Apps.DenyPaths)
    if ($Cfg.Apps.BlockTools) { foreach ($t in $ChildDeniedTools) { $deny += @(Expand-AppLockerPath $t) } }
    foreach ($d in ($deny | Where-Object { $_ } | Sort-Object -Unique)) { Add-Path '0' ($d.TrimEnd('*').TrimEnd('\')) 'Foreldrekontroll: sperret' }
    foreach ($o in $old) { Remove-Item -LiteralPath $o -Recurse -Force -ErrorAction SilentlyContinue }
    Set-PcReg $ci 'DefaultLevel' 0
}

function Set-ChildHive([hashtable]$Child, [hashtable]$Cfg, [string[]]$WritableDirs, [bool]$Remove = $false) {
    Invoke-WithChildHive $Child {
        param($Root)
        foreach ($k in @("$Root\Software\Policies", "$Root\Software\Microsoft\Windows\CurrentVersion\Policies")) {
            Protect-ChildPolicyKey $k $Child.Sid
        }
        # Fjern bare verdier som ikke lenger skal være satt (ingen pause der nettleserreglene mangler).
        $want = @{}
        if (-not $Remove) { foreach ($s in (Get-ChildRegSettings $Cfg)) { $want["$($s.Path)|$($s.Name)"] = $true } }
        foreach ($s in (Get-ChildRegSettings $Cfg -All)) {
            if (-not $want.ContainsKey("$($s.Path)|$($s.Name)")) { Remove-PcReg "$Root\$($s.Path)" $s.Name }
        }
        if ($Remove) {
            $safer = "$Root\Software\Policies\Microsoft\Windows\Safer"
            if (Test-Path -LiteralPath $safer) { Remove-Item -LiteralPath $safer -Recurse -Force }
            foreach ($k in @($Cfg.Backup.OneDrive.Keys | Where-Object { $_ -like "$($Child.Sid)|*" })) {
                Set-PcReg "$Root\Software\Microsoft\Windows\CurrentVersion\Run" $k.Split('|')[1] $Cfg.Backup.OneDrive[$k] 'String'
                $Cfg.Backup.OneDrive.Remove($k)
            }
            return
        }
        foreach ($s in (Get-ChildRegSettings $Cfg)) { Set-PcReg "$Root\$($s.Path)" $s.Name $s.Value $s.Type }
        # Skrivbare mapper huskes fra siste skanning i meny 3, så andre menyer ikke lager hull i sperren.
        $wd = @($WritableDirs | Where-Object { $_ })
        if ($wd.Count -eq 0) { $wd = @($Cfg.Apps.WritableDirs | Where-Object { $_ }) }
        if (Test-IsHomeEdition) { Set-ChildSrp $Root $Cfg $wd }
        if ($Cfg.Apps.Enabled) {
            # OneDrive ligger i barnets AppData og blir sperret; fjern autostart så det ikke kommer feilmeldinger.
            $run = "$Root\Software\Microsoft\Windows\CurrentVersion\Run"
            foreach ($n in @('OneDriveSetup', 'OneDrive')) {
                $v = Get-PcReg $run $n
                if ($null -ne $v) { $Cfg.Backup.OneDrive["$($Child.Sid)|$n"] = $v; Remove-PcReg $run $n }
            }
        }
    }
}

# ============================================================== 1. Barnekontoer

function Show-Children([hashtable]$Cfg) {
    if (@($Cfg.Children).Count -eq 0) { Write-Info 'Ingen barnekontoer er valgt ennå.'; return }
    $admins = Get-GroupMemberSids $SidAdmins
    foreach ($c in $Cfg.Children) {
        $u = Get-LocalUser -SID $c.Sid -ErrorAction SilentlyContinue
        if (-not $u) { Write-Err "{0}: kontoen finnes ikke lenger" $($c.Name); continue }
        if ($admins -contains $c.Sid) { Write-Err "{0}: er ADMINISTRATOR (må være standardbruker)" $($u.Name) }
        else { Write-Ok "{0}: standardbruker" $($u.Name) }
    }
}

function Test-ParentSafety {
    $me = Get-CurrentUserSid
    $admins = Get-GroupMemberSids $SidAdmins
    foreach ($u in (Get-LocalAccounts | Where-Object { $_.Enabled -and $admins -contains $_.SID.Value })) {
        if (-not $u.PasswordRequired -or -not $u.PasswordLastSet) {
            Write-Warn "Administratorkontoen '{0}' ser ut til å mangle passord. Gi den et passord barnet ikke kjenner." $($u.Name)
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
    if (Get-LocalUser -Name $name -ErrorAction SilentlyContinue) { Write-Err "Kontoen '{0}' finnes allerede. Velg den i stedet." $name; return }
    $full = Read-Text 'Fullt navn (vises på påloggingsskjermen)' $name
    $pw1 = Read-Host (T 'Passord for barnet (tomt = uten passord)') -AsSecureString
    $params = @{ Name = $name; FullName = $full; Description = 'Barnekonto (foreldrekontroll)'; AccountNeverExpires = $true }
    if ($pw1.Length -gt 0) {
        $pw2 = Read-Host (T 'Skriv passordet en gang til') -AsSecureString
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
    Write-Ok "Kontoen '{0}' er laget som standardbruker." $name
}

function Select-ExistingChild([hashtable]$Cfg) {
    $me = Get-CurrentUserSid
    $admins = Get-GroupMemberSids $SidAdmins
    $chosen = @($Cfg.Children | ForEach-Object { $_.Sid })
    $cands = @(Get-LocalAccounts | Where-Object { $_.SID.Value -ne $me -and $chosen -notcontains $_.SID.Value })
    if ($cands.Count -eq 0) { Write-Info 'Ingen andre kontoer å velge.'; return }
    for ($i = 0; $i -lt $cands.Count; $i++) {
        $u = $cands[$i]
        $tag = if ($admins -contains $u.SID.Value) { T 'administrator' } else { T 'standardbruker' }
        $src = if ($u.PrincipalSource -eq 'MicrosoftAccount') { ', ' + (T 'Microsoft-konto') } else { '' }
        Write-Host ("  {0,2}. {1} ({2}{3})" -f ($i + 1), $u.Name, $tag, $src)
    }
    $n = Read-Numbers 'Hvilken konto er barnets? (nummer)' $cands.Count
    foreach ($idx in $n) {
        $u = $cands[$idx - 1]
        if ($admins -contains $u.SID.Value) {
            $otherAdmins = @($admins | Where-Object { $_ -ne $u.SID.Value -and $_ -match '^S-1-5-21-' })
            if ($otherAdmins.Count -eq 0) { Write-Err "'{0}' er eneste administrator og kan ikke gjøres om." $($u.Name); continue }
            if (-not (Read-YesNo (T "'{0}' er administrator. Gjøre om til standardbruker?" $($u.Name)) $true)) { continue }
            Remove-LocalGroupMember -SID $SidAdmins -Member $u
            Add-LocalGroupMember -SID $SidUsers -Member $u -ErrorAction SilentlyContinue
            Write-Ok "'{0}' er nå standardbruker. Endringen gjelder fra neste pålogging." $($u.Name)
        }
        $Cfg.Children = @($Cfg.Children) + @(@{ Name = $u.Name; Sid = $u.SID.Value })
        Write-Ok "'{0}' er lagt til som barnekonto." $($u.Name)
    }
}

function Menu-Children([hashtable]$Cfg) {
    while ($true) {
        Write-Title 'Barnekontoer'
        Show-Children $Cfg
        Write-Host ''
        Write-Host (T '  1. Lag ny barnekonto')
        Write-Host (T '  2. Velg en konto som finnes')
        Write-Host (T '  3. Bytt passord for en barnekonto')
        Write-Host (T '  4. Fjern en konto fra listen (kontoen slettes ikke)')
        Write-Host (T '  0. Tilbake')
        switch (Read-Host (T 'Valg')) {
            '1' { New-ChildAccount $Cfg; Save-Config $Cfg }
            '2' { Select-ExistingChild $Cfg; Save-Config $Cfg }
            '3' {
                $c = Select-Child $Cfg
                if ($c) {
                    $pw = Read-Host (T "Nytt passord for {0}" $($c.Name)) -AsSecureString
                    Set-LocalUser -SID $c.Sid -Password $pw
                    Write-Ok 'Passordet er byttet.'
                }
            }
            '4' {
                $c = Select-Child $Cfg
                if ($c) {
                    Set-ChildHive $c $Cfg @() $true
                    Set-LogonHours @{ ScreenTime = @{ Enabled = $false } } $c
                    $Cfg.Children = @($Cfg.Children | Where-Object { $_.Sid -ne $c.Sid })
                    Save-Config $Cfg
                    Write-Ok "{0} er fjernet fra listen. Bruk 'Bruk alle innstillinger på nytt' for å oppdatere app-reglene." $($c.Name)
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
    if ($Limit -lt 0) { return (T 'ingen grense') }
    if ($Limit -eq 0) { return (T 'ingen tilgang') }
    return (T '{0} t {1:00} min' ([math]::Floor($Limit / 60)) ($Limit % 60))
}

function Show-Schedule([hashtable]$Cfg) {
    if ($Cfg.ScreenTime.Enabled) { Write-Host (T '  Skjermtid er PÅ') } else { Write-Host (T '  Skjermtid er AV') }
    Write-Host ''
    Write-Host ('  {0,-11} {1,-6} {2,-6} {3}' -f (T 'Dag'), (T 'Fra'), (T 'Til'), (T 'Maks per dag'))
    foreach ($d in $DayNames.Keys) {
        $r = $Cfg.ScreenTime.Days[$d]
        Write-Host ('  {0,-11} {1,-6} {2,-6} {3}' -f (T $DayNames[$d]), $r.Start, $r.End, (Format-Limit $r.Limit))
    }
}

function Edit-Days([hashtable]$Cfg, [string[]]$Days, [string]$Label) {
    $first = $Cfg.ScreenTime.Days[$Days[0]]
    Write-Host ("`n  " + (T $Label))
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
        Write-Info 'Barnet får varsel 10 og 3 minutter før tiden er ute, og blir logget ut 1 minutt etter at tiden er brukt opp.'
        Write-Info 'Varslene er små vinduer som kan ta fokus fra et spill i fullskjerm, derfor er det bare to.'
        $Cfg.ScreenTime.Enabled = Read-YesNo 'Slå på skjermtid?' $true
        if ($Cfg.ScreenTime.Enabled) {
            Edit-Days $Cfg $Weekdays 'Hverdager (mandag til fredag)'
            Edit-Days $Cfg $Weekend 'Helg (lørdag og søndag)'
            if (Read-YesNo 'Vil du endre enkeltdager også?' $false) {
                foreach ($d in $DayNames.Keys) { if (Read-YesNo (T "  Endre {0}?" (T $DayNames[$d])) $false) { Edit-Days $Cfg @($d) $DayNames[$d] } }
            }
        }
        Save-Config $Cfg; Apply-ScreenTime $Cfg
        return
    }
    while ($true) {
        Write-Title 'Skjermtid'
        Show-Schedule $Cfg
        Write-Host ''
        Write-Host (T '  1. Slå skjermtid på/av')
        Write-Host (T '  2. Sett hverdager (mandag til fredag)')
        Write-Host (T '  3. Sett helg (lørdag og søndag)')
        Write-Host (T '  4. Endre én dag')
        Write-Host (T '  5. Vis brukt tid i dag')
        Write-Host (T '  0. Tilbake (lagrer og tar i bruk)')
        switch (Read-Host (T 'Valg')) {
            '1' { $Cfg.ScreenTime.Enabled = -not $Cfg.ScreenTime.Enabled }
            '2' { Edit-Days $Cfg $Weekdays 'Hverdager' }
            '3' { Edit-Days $Cfg $Weekend 'Helg' }
            '4' {
                $keys = @($DayNames.Keys)
                for ($i = 0; $i -lt 7; $i++) { Write-Host ("  {0}. {1}" -f ($i + 1), (T $DayNames[$keys[$i]])) }
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
        if ($u -and $u.Date -eq (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) -and $u.Users.($c.Sid)) { $m = [math]::Round([double]$u.Users.($c.Sid).Minutes) }
        Write-Info "{0}: {1} minutter brukt i dag" $($c.Name) $m
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
        $today = (Get-Date).DayOfWeek.ToString()
        $bonus = 0
        if ($Cfg.Bonus -and $Cfg.Bonus.Date -eq (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)) { $bonus = [int]$Cfg.Bonus.Minutes }
        for ($d = 0; $d -lt 7; $d++) {
            $r = $Cfg.ScreenTime.Days[$order[$d]]
            $extra = if ($order[$d] -eq $today) { $bonus } else { 0 }
            if ($r.Limit -eq 0 -and $extra -le 0) { continue }
            $sh = [int]$r.Start.Split(':')[0] - 1
            $eh = [int]$r.End.Split(':')[0] + 2 + [int][math]::Ceiling($extra / 60)
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
        Write-Warn "Kunne ikke sette påloggingstider for {0}: {1}" $($Child.Name) $($_.Exception.Message)
    }
}

function Install-Files {
    if (-not (Test-Path -LiteralPath $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
    $here = Split-Path -Parent $PSCommandPath
    foreach ($f in @('Haandhever.ps1', 'Setup-Foreldrekontroll.ps1', 'Start-Foreldrekontroll.cmd', 'README.md', 'README.uk.md', 'LICENSE')) {
        $src = Join-Path $here $f
        $dst = Join-Path $InstallDir $f
        if ((Test-Path -LiteralPath $src) -and ($src -ne $dst)) {
            $changed = -not (Test-Path -LiteralPath $dst) -or ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash)
            if ($changed) {
                Copy-Item -LiteralPath $src -Destination $dst -Force
                # Ny håndhever: den kompilerer PcWts3.dll på nytt neste gang.
                if ($f -eq 'Haandhever.ps1') { Remove-Item -LiteralPath (Join-Path $InstallDir 'PcWts3.dll') -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    $langSrc = Join-Path $here 'lang'
    $langDst = Join-Path $InstallDir 'lang'
    if ((Test-Path -LiteralPath $langSrc) -and ($langSrc -ne $langDst)) {
        New-Item -ItemType Directory -Path $langDst -Force | Out-Null
        Copy-Item -Path (Join-Path $langSrc '*.psd1') -Destination $langDst -Force
    }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'Haandhever.ps1'))) {
        throw (T 'Fant ikke Haandhever.ps1. Den må ligge i samme mappe som dette skriptet.')
    }
}

function Register-EnforcerTask {
    # Etter en oppdatering: ikke registrer oppgaven på nytt hvis den finnes (unødvendig mens den kjører).
    if ($script:AutoMode -and (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { return }
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$InstallDir\Haandhever.ps1&quot;"
    $start = (Get-Date).Date.ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
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
    <Priority>7</Priority>
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
    $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $have = if ($Cfg.Bonus.Date -eq $today) { [int]$Cfg.Bonus.Minutes } else { 0 }
    Write-Info "Ekstra tid gitt i dag: {0} minutter. Ekstra tid gjelder også etter siste klokkeslett." $have
    $n = 0
    $a = Read-Text 'Hvor mange minutter ekstra? (negativt tall trekker fra)' '30'
    if (-not [int]::TryParse($a, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { Write-Err 'Ikke et tall.'; return }
    $Cfg.Bonus = @{ Date = $today; Minutes = [math]::Max(0, $have + $n) }
    Save-Config $Cfg
    # Påloggingstidene utvides også, så ekstra tid kan brukes etter en utlogging eller omstart.
    if ($Cfg.ScreenTime.Enabled) { foreach ($c in $Cfg.Children) { Set-LogonHours $Cfg $c } }
    Write-Ok "Ekstra tid i dag er nå {0} minutter." $($Cfg.Bonus.Minutes)
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
        if ($depth -lt 6) {
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
    # %PROGRAMFILES% betyr begge Program Files-mappene i AppLocker.
    $p = $Path.Replace('%WINDIR%', $env:windir).Replace('%SYSTEM32%', "$env:windir\System32")
    if ($p -like '*%PROGRAMFILES%*') {
        return @(@($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | ForEach-Object { $p.Replace('%PROGRAMFILES%', $_) })
    }
    return @($p)
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
                $kind = if ("$($lnk.BaseName) $t" -match $LauncherPattern) { 'Spillklient' } else { 'Program' }
                Add-Cand $lnk.BaseName (Split-Path -Parent $t) $kind
            }
        }
    }
    # Steam (selve klienten trengs for å starte Steam-spill)
    $steam = Get-PcReg 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' 'InstallPath'
    if ($steam -and (Test-Path -LiteralPath $steam)) {
        Add-Cand (T 'Steam (klient og alle Steam-spill)') $steam 'Spillklient'
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
    # EA-spill (Battlefield og andre) som er registrert i registeret
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\EA Games', 'HKLM:\SOFTWARE\EA Games', 'HKLM:\SOFTWARE\WOW6432Node\Electronic Arts', 'HKLM:\SOFTWARE\Electronic Arts')) {
        foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue)) {
            $dir = Get-PcReg $k.PSPath 'Install Dir'
            if (-not $dir) { $dir = Get-PcReg $k.PSPath 'InstallLocation' }
            if ($dir) {
                $kind = if ($k.PSChildName -match $LauncherPattern) { 'Spillklient' } else { 'Spill' }
                Add-Cand "EA: $($k.PSChildName)" $dir $kind
            }
        }
    }
    # Antijuks og spilltjenester som spillene starter i barnets økt
    foreach ($d in $GameServiceDirs) {
        $full = [Environment]::ExpandEnvironmentVariables($d)
        Add-Cand (T 'Spilltjeneste: {0}' (Split-Path -Leaf $full)) $full 'Spilltjeneste'
    }
    $order = @{ Spill = 0; Spillklient = 1; Spilltjeneste = 2; Program = 3 }
    $list = @($found.Values | Sort-Object @{ Expression = { $order[$_.Kind] } }, Name)
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
        Write-Warn "Windows-utgave: {0}. Bruker Software Restriction Policies (svakere enn AppLocker)." $(Get-EditionName)
    } else {
        Write-Info "Windows-utgave: {0}. Bruker AppLocker." $(Get-EditionName)
    }
    Write-Info 'Når dette er på, kan barnet bare starte programmer som en voksen har installert (i Windows og Program Files).'
    Write-Info 'Programmer i Nedlastinger, AppData og på minnepinner starter ikke.'
    Write-Info 'Barnet kan derfor ikke installere eller kjøre nye programmer, spill, nettlesere eller VPN.'
    if ($Wizard -or -not $Cfg.Apps.Enabled) {
        $Cfg.Apps.Enabled = Read-YesNo 'Slå på sperre for installering og ukjente programmer?' $true
        if (-not $Cfg.Apps.Enabled) { Save-Config $Cfg; Apply-Apps $Cfg; return }
        $Cfg.Apps.BlockStore = Read-YesNo 'Sperre Microsoft Store og App Installer (winget) for barnet?' $true
        $Cfg.Apps.BlockXbox = Read-YesNo 'Sperre Xbox-appen (den kan installere spill uten passord)?' $true
        $Cfg.Apps.BlockTools = Read-YesNo 'Sperre kommandolinje, PowerShell og andre verktøy som kan omgå sperrene? (Slå av hvis et spill ikke vil starte.)' $true
        Write-Info 'Neste valg gjelder alle standardbrukere, ikke bare barnet.'
        Write-Info 'Bruker du selv en standardkonto til hverdags, må du logge på administratorkontoen for å gjøre endringer.'
        $Cfg.Apps.StrictUac = Read-YesNo 'Avvise "Kjør som administrator" i barnets økt automatisk (anbefalt)?' $true
    }
    Write-Info 'Leter etter installerte programmer og spill (kan ta litt tid) ...'
    $writable = Get-WritableDirs $Cfg
    $cands = Get-AppCandidates $writable
    $store = Get-StoreApps
    $games = @($cands | Where-Object { $_.Kind -ne 'Program' })
    if ($Wizard -and $games.Count) {
        Write-Host ''
        Write-Info "Fant {0} spill, spillklienter og antijuks-tjenester (for eksempel Steam, Epic/Fortnite, EA/Battlefield)." $($games.Count)
        if (Read-YesNo 'Tillate alle sammen, så spillene starter og oppdateres som vanlig?' $true) { Enable-AllGames $Cfg $cands }
    }
    while ($true) {
        Write-Title 'Apper og spill: velg hva barnet får bruke'
        $rows = @()
        $kindTxt = @{ Spill = (T 'Spill'); Spillklient = (T 'Spillklient'); Spilltjeneste = (T 'Antijuks/tjeneste'); Program = (T 'Program') }
        foreach ($c in $cands) {
            if ($c.Protected) { $ok = -not (Test-UnderAny $c.Dir @($Cfg.Apps.DenyPaths)) }
            else { $ok = Test-UnderAny $c.Dir @($Cfg.Apps.AllowPaths) }
            $label = "[$($kindTxt[$c.Kind])] $($c.Name)"
            $rows += [pscustomobject]@{ Type = 'dir'; Item = $c; Ok = $ok; Label = $label; Note = $(if ($c.Protected) { '' } else { T '(mappe barnet kan skrive i)' }) }
        }
        foreach ($s in $store) {
            $ok = -not (@($Cfg.Apps.DenyPackages | Where-Object { $_.Name -eq $s.Name }).Count)
            $rows += [pscustomobject]@{ Type = 'appx'; Item = $s; Ok = $ok; Label = (T 'Store-app: {0}' $s.Name); Note = '' }
        }
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $mark = if ($r.Ok) { (T 'tillatt').ToUpperInvariant().PadRight(14) } else { (T 'sperret').ToUpperInvariant().PadRight(14) }
            $col = if ($r.Ok) { 'Green' } else { 'Red' }
            Write-Host ("  {0,3}. " -f ($i + 1)) -NoNewline
            Write-Host $mark -ForegroundColor $col -NoNewline
            Write-Host " $($r.Label) $($r.Note)"
        }
        Write-Host ''
        Write-Info "Store: {0},  Xbox-appen: {1}" $(if ($Cfg.Apps.BlockStore) { T 'sperret' } else { T 'tillatt' }) $(if ($Cfg.Apps.BlockXbox) { T 'sperret' } else { T 'tillatt' })
        Write-Host (T '  Skriv numre for å bytte mellom tillatt/sperret (for eksempel 2,5,7-9).')
        Write-Host (T '  G = tillat alle spill, spillklienter og antijuks (anbefalt så spillene virker som de skal)')
        Write-Host (T '  S = bytt Store,  X = bytt Xbox-appen,  M = legg til mappe selv,  Enter = ferdig')
        $a = ConvertTo-MenuKey (Read-Host (T 'Valg'))
        if ($a -eq '') { break }
        if ($a -ieq 'g') { Enable-AllGames $Cfg $cands; continue }
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
                if ($r.Ok) {
                    $Cfg.Apps.DenyPaths = @($Cfg.Apps.DenyPaths) + @($r.Item.Dir)
                    $Cfg.Apps.AllowPaths = @($Cfg.Apps.AllowPaths | Where-Object { $_ -ne $r.Item.Dir })
                } else { $Cfg.Apps.DenyPaths = @($Cfg.Apps.DenyPaths | Where-Object { $_ -ne $r.Item.Dir }) }
            } else {
                if ($r.Ok) { $Cfg.Apps.AllowPaths = @($Cfg.Apps.AllowPaths | Where-Object { $_ -ne $r.Item.Dir }) }
                else {
                    Write-Warn "Barnet kan legge egne programmer i '{0}'. Å tillate den åpner et lite hull i sperren." $($r.Item.Dir)
                    if (Read-YesNo 'Tillate likevel?' $true) { $Cfg.Apps.AllowPaths = @($Cfg.Apps.AllowPaths) + @($r.Item.Dir) }
                }
            }
        }
    }
    Save-Config $Cfg
    Apply-Apps $Cfg $writable
}

function Enable-AllGames([hashtable]$Cfg, $Cands) {
    # Hele spillmappen tillates for barnet, også undermapper som barnet kan skrive i
    # (spill og antijuks legger ofte hjelpeprogrammer der). Det er prisen for at spillene virker.
    $games = @($Cands | Where-Object { $_.Kind -ne 'Program' })
    foreach ($g in $games) {
        $Cfg.Apps.DenyPaths = @($Cfg.Apps.DenyPaths | Where-Object { $_ -ne $g.Dir })
        if (@($Cfg.Apps.AllowPaths) -notcontains $g.Dir) { $Cfg.Apps.AllowPaths = @($Cfg.Apps.AllowPaths) + @($g.Dir) }
    }
    $open = @($games | Where-Object { -not $_.Protected })
    Write-Ok "{0} spill og spillklienter er tillatt." $($games.Count)
    if ($open.Count) {
        Write-Warn "{0} av dem ligger i mapper barnet kan skrive i (typisk Steam), så barnet kan i teorien legge egne programmer der." $($open.Count)
        Write-Warn 'Vil du stenge det, sperr dem igjen med nummeret i listen.'
    }
}

function New-AppLockerXml([hashtable]$Cfg, [string[]]$ChildSids, [string[]]$OtherSids, [string[]]$WritableDirs) {
    # Bygger en hel AppLocker-policy. Ren tekstbygging, kan testes uten Windows.
    $sb = New-Object Text.StringBuilder
    function Esc([string]$s) { return [Security.SecurityElement]::Escape($s) }
    function Add-PathRule([string]$Name, [string]$Sid, [string]$Action, [string]$Path, [string[]]$Exceptions) {
        [void]$sb.Append("<FilePathRule Id=`"$(Get-StableGuid "P|$Name|$Sid|$Action|$Path")`" Name=`"$(Esc $Name)`" Description=`"Foreldrekontroll`" UserOrGroupSid=`"$Sid`" Action=`"$Action`">")
        [void]$sb.Append("<Conditions><FilePathCondition Path=`"$(Esc $Path)`" /></Conditions>")
        if ($Exceptions -and $Exceptions.Count) {
            [void]$sb.Append('<Exceptions>')
            foreach ($e in $Exceptions) { [void]$sb.Append("<FilePathCondition Path=`"$(Esc $e)`" />") }
            [void]$sb.Append('</Exceptions>')
        }
        [void]$sb.Append('</FilePathRule>')
    }
    function Add-AppxRule([string]$Name, [string]$Sid, [string]$Action, [string]$Publisher, [string]$Product, [string]$Binary = '*') {
        [void]$sb.Append("<FilePublisherRule Id=`"$(Get-StableGuid "X|$Name|$Sid|$Action|$Publisher|$Product|$Binary")`" Name=`"$(Esc $Name)`" Description=`"Foreldrekontroll`" UserOrGroupSid=`"$Sid`" Action=`"$Action`">")
        [void]$sb.Append("<Conditions><FilePublisherCondition PublisherName=`"$(Esc $Publisher)`" ProductName=`"$(Esc $Product)`" BinaryName=`"$(Esc $Binary)`">")
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
                    if ($Cfg.Apps.BlockTools) {
                        foreach ($t in $ChildDeniedTools) { Add-PathRule "Verktøy sperret for barn: $t" $c 'Deny' $t @() }
                        foreach ($b in $ChildDeniedBinaries) { Add-AppxRule "Verktøy sperret for barn: $b" $c 'Deny' $MsPublisher '*' $b }
                    }
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

function Save-AppLockerBackup([hashtable]$Cfg) {
    # Ta vare på en AppLocker-policy som fantes før foreldrekontrollen, så den kan settes tilbake.
    if ($Cfg.Backup.AppLockerSaved) { return }
    try {
        $old = Get-AppLockerPolicy -Local -Xml
        Set-Content -LiteralPath (Join-Path $InstallDir 'applocker-foer.xml') -Value $old -Encoding UTF8
    } catch { }
    $Cfg.Backup.AppLockerSaved = $true
}

function Restore-AppLocker([hashtable]$Cfg) {
    $b = Join-Path $InstallDir 'applocker-foer.xml'
    if ($Cfg.Backup.AppLockerSaved -and (Test-Path -LiteralPath $b) -and ((Get-Content -LiteralPath $b -Raw) -match '<FilePathRule|<FilePublisherRule|<FileHashRule')) {
        Set-AppLockerPolicy -XmlPolicy $b
    } else {
        Set-AppLockerFromXml (Get-EmptyAppLockerXml)
        [void](Invoke-Native "$env:windir\System32\sc.exe" 'config AppIDSvc start= demand')
    }
    $Cfg.Backup.AppLockerSaved = $false
    Remove-Item -LiteralPath $b -Force -ErrorAction SilentlyContinue
}

function Set-AppLockerFromXml([string]$Xml) {
    $f = Join-Path $InstallDir 'applocker.xml'
    Set-Content -LiteralPath $f -Value $Xml -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $f
}

function Get-OtherUserSids([hashtable]$Cfg) {
    $childSids = @($Cfg.Children | ForEach-Object { $_.Sid })
    $res = @(Get-LocalUser | Where-Object { $childSids -notcontains $_.SID.Value -and $_.SID.Value -notmatch '-(501|503|504)$' } | ForEach-Object { $_.SID.Value })
    # Også voksne som har kjørt skriptet (for eksempel en Microsoft Entra-/domenekonto som ikke er
    # lokal). De huskes i konfigurasjonen, så de er med også når oppgaven kjører som SYSTEM.
    $me = Get-CurrentUserSid
    if ($childSids -notcontains $me -and $me -ne 'S-1-5-18') { $res += $me }
    $res += @($Cfg.Apps.TrustedSids | Where-Object { $_ -and $childSids -notcontains $_ })
    return @($res | Sort-Object -Unique)
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
                try {
                    Remove-AppxPackage -Package $p.PackageFullName -User $c.Sid -ErrorAction Stop
                    Write-Ok "{0} er fjernet for {1}." $n $($c.Name)
                    $Cfg.Backup.StoreRemovedFor = @($Cfg.Backup.StoreRemovedFor) + @("$($c.Name): $n")
                }
                catch { Write-Warn "Kunne ikke fjerne {0} for {1}: {2}" $n $($c.Name) $($_.Exception.Message) }
            }
        }
    }
}

function Apply-Apps([hashtable]$Cfg, [string[]]$Writable = $null) {
    $hklmInst = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Installer'
    $hklmUac  = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if ($null -eq $Writable -or @($Writable).Count -eq 0) { $Writable = Get-WritableDirs $Cfg }
    $Cfg.Apps.WritableDirs = @($Writable)
    $childSids = @($Cfg.Children | ForEach-Object { $_.Sid })
    $isHome = Test-IsHomeEdition

    if ($Cfg.Apps.Enabled -and $childSids.Count) {
        Set-ManagedHklm $Cfg $hklmInst 'DisableUserInstalls' 1
        if ($Cfg.Apps.StrictUac) { Set-ManagedHklm $Cfg $hklmUac 'ConsentPromptBehaviorUser' 0 } else { Restore-ManagedHklm $Cfg $hklmUac 'ConsentPromptBehaviorUser' }
        if ($isHome) {
            Set-StoreForChildHome $Cfg
            Write-Ok 'Software Restriction Policies settes i barnets profil.'
        } else {
            Save-AppLockerBackup $Cfg
            $xml = New-AppLockerXml $Cfg $childSids (Get-OtherUserSids $Cfg) $Writable
            $prev = Join-Path $InstallDir 'applocker.xml'
            $same = (Test-Path -LiteralPath $prev) -and ((Get-Content -LiteralPath $prev -Raw -Encoding UTF8).Trim() -ceq $xml.Trim()) -and
                    -not @(Get-MissingProtections $Cfg | Where-Object { $_ -eq (T 'AppLocker-regler') }).Count
            if (-not $same) {
                Set-AppLockerFromXml $xml
                [void](Invoke-Native "$env:windir\System32\gpupdate.exe" '/target:computer /force')
            }
            $r = Invoke-Native "$env:windir\System32\sc.exe" 'config AppIDSvc start= auto'
            if ($r.ExitCode -ne 0) { throw ('sc config AppIDSvc: ' + $r.Output.Trim()) }
            if ((Get-Service AppIDSvc -ErrorAction SilentlyContinue).Status -ne 'Running') { [void](Invoke-Native "$env:windir\System32\sc.exe" 'start AppIDSvc') }
            Write-Ok 'AppLocker-reglene er tatt i bruk.'
        }
    } else {
        Restore-ManagedHklm $Cfg $hklmInst 'DisableUserInstalls'
        Restore-ManagedHklm $Cfg $hklmUac 'ConsentPromptBehaviorUser'
        # Rør bare AppLocker hvis det var foreldrekontrollen som satte reglene.
        if (-not $isHome -and $Cfg.Backup.AppLockerSaved) { Restore-AppLocker $Cfg }
        Write-Ok 'App-sperren er av.'
    }
    if (-not $script:InApplyAll) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg $Writable } }
    Save-Config $Cfg
}

# ============================================================== 4. Trådløse nettverk

function Test-HasWifi {
    # Fra nettverkskortene, ikke netsh (netsh viser lite når kortet er frakoblet eller posisjon er av).
    return [bool](Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.PhysicalMediaType -match '802\.11' -or $_.NdisPhysicalMedium -eq 9 })
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

function Get-PrefixSsids([hashtable]$Cfg) {
    # Navn som sperres på forhånd: hvert prefiks med tallene 1 til PrefixMax.
    $res = @()
    foreach ($p in @($Cfg.Wifi.BlockPrefixes | Where-Object { $_ })) {
        for ($i = 1; $i -le [int]$Cfg.Wifi.PrefixMax; $i++) { $res += "$p$i" }
    }
    return , $res
}

function Test-PrefixSsid([hashtable]$Cfg, [string]$Ssid) {
    foreach ($p in @($Cfg.Wifi.BlockPrefixes | Where-Object { $_ })) {
        if ($Ssid -match ('^(?i)' + [regex]::Escape($p) + '\d+$')) { return $true }
    }
    return $false
}

function Format-Prefixes([hashtable]$Cfg) {
    $p = @($Cfg.Wifi.BlockPrefixes | Where-Object { $_ })
    if ($p.Count -eq 0) { return (T 'ingen') }
    return (($p | ForEach-Object { "${_}1, ${_}2, ${_}3 ..." }) -join '; ')
}

function Get-WifiModeTexts {
    return @{ off = (T 'filteret er av'); allow = (T 'bare valgte nettverk er tillatt'); block = (T 'valgte nettverk er sperret') }
}

function Format-Bool($Value) { if ($Value) { return (T 'ja') } return (T 'nei') }

function Menu-Wifi([hashtable]$Cfg) {
    Write-Title 'Trådløse nettverk'
    if (-not (Test-HasWifi)) { Write-Warn 'Fant ingen Wi-Fi på denne PC-en.' }
    Write-Info 'Filteret gjelder hele PC-en (også voksne), men bare administratorer kan endre det.'
    $modeTxt = Get-WifiModeTexts
    Write-Info "Nå: {0} {1}" $($modeTxt[$Cfg.Wifi.Mode]) $(if (@($Cfg.Wifi.Ssids).Count) { '(' + (@($Cfg.Wifi.Ssids) -join ', ') + ')' })
    Write-Info "Alltid sperret (navn pluss tall): {0}" $(Format-Prefixes $Cfg)
    Write-Host ''
    Write-Host (T '  1. Bare tillat nettverk jeg velger (anbefalt: hjemme, skole, besteforeldre)')
    Write-Host (T '  2. Sperr bestemte nettverk')
    Write-Host (T '  3. Slå av Wi-Fi-filteret (alltid sperrede navn er fortsatt sperret)')
    Write-Host (T '  4. Endre navn som alltid er sperret')
    Write-Host (T '  0. Ingen endring')
    $choice = Read-Host (T 'Valg')
    if ($choice -eq '3') { $Cfg.Wifi.Mode = 'off'; $Cfg.Wifi.Ssids = @() }
    elseif ($choice -eq '4') {
        Write-Info 'Skriv navn uten tall, skilt med komma. "Anlegg" sperrer Anlegg1, Anlegg2 og så videre.'
        Write-Info 'Skriv "{0}" for å ikke sperre noen navn automatisk.' (T 'ingen')
        $a = Read-Text 'Navn' ((@($Cfg.Wifi.BlockPrefixes) -join ', '))
        if (Test-NoLimitWord $a) { $Cfg.Wifi.BlockPrefixes = @() }
        else { $Cfg.Wifi.BlockPrefixes = @($a -split '\s*,\s*' | Where-Object { $_ } | Sort-Object -Unique) }
    }
    elseif ($choice -in @('1', '2')) {
        $saved = Get-SavedSsids
        $names = @(@($saved | ForEach-Object { $_.Ssid }) + (Get-VisibleSsids) + @($Cfg.Wifi.Ssids) | Where-Object { $_ } | Sort-Object -Unique)
        $current = Get-CurrentSsid
        if (-not $current -and (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.PhysicalMediaType -match '802\.11' })) {
            Write-Warn 'Windows viser ikke navnet på nettverket du er koblet til.'
            Write-Warn 'Det skjer ofte når posisjonstjenester er slått av i personverninnstillingene i Windows.'
            Write-Warn 'Pass på at ditt eget nettverk er med i listen.'
        }
        for ($i = 0; $i -lt $names.Count; $i++) {
            $tag = if ($names[$i] -eq $current) { ' ' + (T '(tilkoblet nå)') } else { '' }
            Write-Host ("  {0,3}. {1}{2}" -f ($i + 1), $names[$i], $tag)
        }
        $q = if ($choice -eq '1') { 'Hvilke nettverk vil du tillate? (numre, for eksempel 1,3)' } else { 'Hvilke nettverk vil du sperre? (numre, for eksempel 1,3)' }
        $sel = @(Read-Numbers $q $names.Count | ForEach-Object { $names[$_ - 1] })
        while ($true) {
            $extra = Read-Text 'Legg til et nettverksnavn som ikke står i listen (Enter = ferdig)'
            if (-not $extra) { break }
            $sel += $extra
        }
        if ($choice -eq '1') {
            if ($current -and $sel -notcontains $current) {
                Write-Warn "Nettverket du er koblet til nå ('{0}') er ikke valgt. PC-en mister nettet." $current
                if (Read-YesNo (T "Ta med '{0}'?" $current) $true) { $sel += $current }
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
    $mode = if ($Remove) { 'off' } else { $Cfg.Wifi.Mode }
    $oldMode = [string]$Cfg.Wifi.AppliedMode
    $oldList = @($Cfg.Wifi.AppliedSsids | Where-Object { $_ })
    $newList = if ($mode -eq 'off') { @() } else { @($Cfg.Wifi.Ssids | Where-Object { $_ }) }
    function Add-WlanFilter([string]$Perm, [string]$Ssid) {
        $r = Invoke-Native $netsh "wlan add filter permission=$Perm ssid=`"$Ssid`" networktype=infrastructure"
        if ($r.ExitCode -ne 0) { Write-Warn "Wi-Fi-filter for '{0}' feilet: {1}" $Ssid $($r.Output.Trim()) }
    }
    # Endre bare det som er annerledes. Å fjerne et "tillat"-filter mens "sperr alt annet" er på,
    # ville koblet PC-en fra nettet et øyeblikk (og kastet barnet ut av et nettspill).
    if ($oldMode -eq $mode -and $mode -ne 'off') {
        $perm = if ($mode -eq 'allow') { 'allow' } else { 'block' }
        foreach ($s in $newList) { if ($oldList -cnotcontains $s) { Add-WlanFilter $perm $s } }
        foreach ($s in $oldList) { if ($newList -cnotcontains $s) { [void](Invoke-Native $netsh "wlan delete filter permission=$perm ssid=`"$s`" networktype=infrastructure") } }
    } else {
        # Ny modus: legg til de nye filtrene først, fjern de gamle etterpå.
        if ($mode -ne 'off') {
            $perm = if ($mode -eq 'allow') { 'allow' } else { 'block' }
            foreach ($s in $newList) { Add-WlanFilter $perm $s }
            if ($mode -eq 'allow') { [void](Invoke-Native $netsh 'wlan add filter permission=denyall networktype=infrastructure') }
            [void](Invoke-Native $netsh 'wlan add filter permission=denyall networktype=adhoc')
        }
        if ($oldMode -eq 'allow' -or $oldMode -eq 'block') {
            $operm = if ($oldMode -eq 'allow') { 'allow' } else { 'block' }
            foreach ($s in $oldList) { [void](Invoke-Native $netsh "wlan delete filter permission=$operm ssid=`"$s`" networktype=infrastructure") }
            if ($oldMode -eq 'allow') { [void](Invoke-Native $netsh 'wlan delete filter permission=denyall networktype=infrastructure') }
            if ($mode -eq 'off') { [void](Invoke-Native $netsh 'wlan delete filter permission=denyall networktype=adhoc') }
        }
    }
    $Cfg.Wifi.AppliedMode = $mode; $Cfg.Wifi.AppliedSsids = @($newList)

    if ($mode -ne 'off') {
        if ($mode -eq 'block') {
            $saved = Get-SavedSsids
            foreach ($p in ($saved | Where-Object { $Cfg.Wifi.Ssids -ccontains $_.Ssid })) {
                [void](Invoke-Native $netsh "wlan delete profile name=`"$($p.Profile)`"")
            }
        }
        if ($mode -eq 'allow') { Write-Ok 'Wi-Fi-filter: bare {0}' (@($Cfg.Wifi.Ssids) -join ', ') }
        else { Write-Ok 'Wi-Fi-filter: sperret: {0}' (@($Cfg.Wifi.Ssids) -join ', ') }
    } else {
        Write-Ok 'Wi-Fi-filteret er av.'
    }

    # Alltid sperrede navn (Anlegg1, Anlegg2, ...). I "bare tillatte"-modus er de allerede sperret,
    # med mindre en voksen har tillatt et av dem med vilje.
    $oldPrefix = @($Cfg.Wifi.AppliedPrefixSsids | Where-Object { $_ })
    $byEnforcer = @()
    if (Test-Path -LiteralPath $WifiStatePath) {
        try { $byEnforcer = @(Get-Content -LiteralPath $WifiStatePath -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) } catch { }
    }
    $wantPrefix = @()
    $usePrefix = (-not $Remove) -and @($Cfg.Wifi.BlockPrefixes | Where-Object { $_ }).Count
    if ($usePrefix -and $mode -ne 'allow') {
        # I "bare tillatte"-modus er navnene allerede sperret av "sperr alt annet". I "sperr"-modus står
        # navn som også er i sperrelisten, allerede der.
        $wantPrefix = @(@(Get-PrefixSsids $Cfg) + @(Get-VisibleSsids | Where-Object { Test-PrefixSsid $Cfg $_ }) + @($byEnforcer) |
            Where-Object { $_ } | Sort-Object -Unique | Where-Object { -not ($mode -eq 'block' -and $newList -ccontains $_) })
    }
    $have = @($oldPrefix + $byEnforcer | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($s in $wantPrefix) { if ($have -cnotcontains $s) { [void](Invoke-Native $netsh "wlan add filter permission=block ssid=`"$s`" networktype=infrastructure") } }
    foreach ($s in $have) { if ($wantPrefix -cnotcontains $s -and -not ($mode -eq 'block' -and $newList -ccontains $s)) { [void](Invoke-Native $netsh "wlan delete filter permission=block ssid=`"$s`" networktype=infrastructure") } }
    $Cfg.Wifi.AppliedPrefixSsids = @($wantPrefix)
    if (Test-Path -LiteralPath $WifiStatePath) { Remove-Item -LiteralPath $WifiStatePath -Force }
    if ($usePrefix) {
        $saved = Get-SavedSsids
        foreach ($p in ($saved | Where-Object { Test-PrefixSsid $Cfg $_.Ssid })) {
            [void](Invoke-Native $netsh "wlan delete profile name=`"$($p.Profile)`"")
        }
        Write-Ok "Alltid sperret: {0}" $(Format-Prefixes $Cfg)
        # Håndheveren sperrer høyere tall (for eksempel Anlegg51) når de dukker opp.
        if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { Install-Files; Register-EnforcerTask }
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
        if (-not $Remove -and $Cfg.Wifi.DisableBtPan) {
            if ($a.Status -ne 'Disabled' -and @($Cfg.Backup.BtPanDisabled) -notcontains $a.Name) { $Cfg.Backup.BtPanDisabled = @($Cfg.Backup.BtPanDisabled) + @($a.Name) }
            Disable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
        } elseif (@($Cfg.Backup.BtPanDisabled) -contains $a.Name) {
            Enable-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    if ($Remove -or -not $Cfg.Wifi.DisableBtPan) { $Cfg.Backup.BtPanDisabled = @() }
    Save-Config $Cfg
}

# ============================================================== 5. Nettfilter

function Menu-Web([hashtable]$Cfg, [switch]$Wizard) {
    Write-Title 'Nettfilter (voksensider, SafeSearch, DNS)'
    Write-Info 'PC-en bruker en familievennlig DNS-tjeneste som sperrer voksensider. Det gjelder hele PC-en.'
    Write-Info 'Nettleserne (Edge, Chrome, Brave, Firefox) får disse reglene i barnets konto:'
    Write-Info ' * ingen privat modus og ingen utvidelser (det stopper også VPN-utvidelser)'
    Write-Info ' * SafeSearch og begrenset modus på YouTube er alltid på'
    Write-Info ' * nettleseren kan ikke bruke sin egen DNS'
    $Cfg.Web.Enabled = Read-YesNo 'Slå på nettfilteret?' $true
    if ($Cfg.Web.Enabled) {
        $keys = @($DnsProviders.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $p = $DnsProviders[$keys[$i]]
            $tag = if ($i -eq 0) { ' ' + (T '(anbefalt)') } else { '' }
            Write-Host ("  {0}. {1}{2}: {3}" -f ($i + 1), $p.Name, $tag, (T $p.Note))
        }
        $cur = [array]::IndexOf($keys, $Cfg.Web.Provider) + 1
        if ($cur -lt 1) { $cur = 1 }
        $n = Read-Numbers (T "Velg DNS-filter [{0}]" $cur) $keys.Count
        if ($n.Count) { $Cfg.Web.Provider = $keys[$n[0] - 1] }
        $Cfg.Web.BrowserPolicies = Read-YesNo 'Sette sperrer i nettleserne for barnet?' $true
        $Cfg.Web.BlockPublicDns = Read-YesNo 'Sperre andre kjente DNS-tjenere i brannmuren (så filteret ikke kan omgås)?' $true
    }
    Save-Config $Cfg
    Apply-Web $Cfg
}

function Apply-Web([hashtable]$Cfg, [switch]$Remove) {
    $on = $Cfg.Web.Enabled -and -not $Remove
    $newServers = if ($on) { @($DnsProviders[$Cfg.Web.Provider].V4) + @($DnsProviders[$Cfg.Web.Provider].V6) } else { @() }
    # Fjern bare det som ikke lenger skal være der.
    $keepRules = if ($on -and $Cfg.Web.BlockPublicDns) { @('FK-DNS-tcp', 'FK-DNS-udp') } else { @() }
    Remove-PcFirewallRules 'FK-DNS' $keepRules
    foreach ($ip in @($Cfg.Web.DohAdded)) {
        if ($newServers -notcontains $ip) { Remove-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue }
    }
    $Cfg.Web.DohAdded = @($Cfg.Web.DohAdded | Where-Object { $newServers -contains $_ })

    $nics = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
    if ($on) {
        # Husk faste DNS-tjenere som var satt fra før (tomt betyr automatisk fra ruteren).
        foreach ($nic in $nics) {
            $key = [string]$nic.InterfaceGuid
            if ($Cfg.Backup.Dns.ContainsKey($key)) { continue }
            $v4 = Get-PcReg "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$key" 'NameServer'
            $v6 = Get-PcReg "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$key" 'NameServer'
            $Cfg.Backup.Dns[$key] = (@("$v4" -split '[ ,]+') + @("$v6" -split '[ ,]+') | Where-Object { $_ }) -join ','
        }
        $p = $DnsProviders[$Cfg.Web.Provider]
        $Cfg.Web.Servers = @($p.V4) + @($p.V6)
        $dnsChanged = $false
        foreach ($nic in $nics) {
            $v6 = $false
            try { $v6 = [bool](Get-NetAdapterBinding -Name $nic.Name -ComponentID ms_tcpip6 -ErrorAction Stop).Enabled } catch { }
            $list = @($Cfg.Web.Servers | Where-Object { $v6 -or $_ -notlike '*:*' })
            if (Test-NicDns $nic $list) { continue }
            try { Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses $list; $dnsChanged = $true } catch { Write-Warn "DNS på '{0}': {1}" $($nic.Name) $($_.Exception.Message) }
        }
        if (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue) {
            foreach ($ip in $Cfg.Web.Servers) {
                if (-not (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)) {
                    try {
                        Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $p.DoH -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction Stop | Out-Null
                        $Cfg.Web.DohAdded = @($Cfg.Web.DohAdded) + @($ip)
                        $dnsChanged = $true
                    } catch { }
                }
            }
        }
        if ($Cfg.Web.BlockPublicDns) {
            # Bare DNS-portene (53, DoH 443, DoT/DoQ 853). Ping og annen trafikk til disse adressene går
            # fortsatt, siden noen spill og klienter bruker for eksempel 8.8.8.8 til å sjekke nettforbindelsen.
            $ports = @('53', '443', '853', '5443', '8443')
            Set-PcFirewallRule 'FK-DNS-tcp' 'Foreldrekontroll: sperr andre DNS-tjenere (TCP)' @{ Protocol = 'TCP'; RemotePort = $ports; RemoteAddress = $PublicDns }
            Set-PcFirewallRule 'FK-DNS-udp' 'Foreldrekontroll: sperr andre DNS-tjenere (UDP)' @{ Protocol = 'UDP'; RemotePort = $ports; RemoteAddress = $PublicDns }
        }
        if ($dnsChanged) { Clear-DnsClientCache }
        Write-Ok "Nettfilter: {0} ({1})" $($p.Name) $(@($p.V4) -join ', ')
    } else {
        # Bare kort som foreldrekontrollen faktisk endret (de har en sikkerhetskopi). Andre kort, for
        # eksempel med egen fast DNS, røres ikke.
        foreach ($nic in $nics) {
            $key = [string]$nic.InterfaceGuid
            if (-not $Cfg.Backup.Dns.ContainsKey($key)) { continue }
            $old = [string]$Cfg.Backup.Dns[$key]
            if ($old) { Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ServerAddresses ($old -split ',') -ErrorAction SilentlyContinue }
            else { Set-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue }
        }
        $Cfg.Backup.Dns = @{}
        $Cfg.Web.Servers = @()
        Write-Ok 'Nettfilteret er av (DNS er satt tilbake slik den var).'
    }
    if (-not $Remove -and -not $script:InApplyAll) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg @() } }
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
        $Cfg.Vpn.BlockPorts = Read-YesNo 'Sperre VPN-porter i brannmuren (PPTP, L2TP, OpenVPN, WireGuard; ikke portene Xbox-spill trenger)?' $true
        $Cfg.Vpn.HideSettings = Read-YesNo 'Skjule VPN-, proxy- og mobilsone-sidene i Innstillinger for barnet?' $true
    }
    Save-Config $Cfg
    Apply-Vpn $Cfg
}

function Apply-Vpn([hashtable]$Cfg, [switch]$Remove) {
    $on = $Cfg.Vpn.Enabled -and -not $Remove
    $keepRules = if ($on -and $Cfg.Vpn.BlockPorts) { @('FK-VPN-pptp', 'FK-VPN-udp', 'FK-VPN-openvpn', 'FK-VPN-gre') } else { @() }
    Remove-PcFirewallRules 'FK-VPN' $keepRules
    $proxy = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($on) {
        foreach ($s in @('RasMan', 'SstpSvc')) { Set-ManagedService $Cfg $s ([bool]$Cfg.Vpn.DisableBuiltin) }
        if ($Cfg.Vpn.BlockPorts) {
            $rules = @(
                @{ N = 'FK-VPN-pptp';      D = 'PPTP';             P = 'TCP'; Port = '1723' }
                # UDP 500 og 4500 (IKEv2) sperres IKKE: Xbox-nettverket (partychat, Teredo, krysspill) bruker dem.
                # Windows sin egen IKEv2-VPN er uansett av når RasMan er slått av.
                @{ N = 'FK-VPN-udp';       D = 'L2TP/OpenVPN/WireGuard (UDP)'; P = 'UDP'; Port = @('1701', '1194', '51820') }
                @{ N = 'FK-VPN-openvpn';   D = 'OpenVPN (TCP)';    P = 'TCP'; Port = '1194' }
            )
            foreach ($r in $rules) {
                Set-PcFirewallRule $r.N "Foreldrekontroll: sperr $($r.D)" @{ Protocol = $r.P; RemotePort = $r.Port }
            }
            Set-PcFirewallRule 'FK-VPN-gre' 'Foreldrekontroll: sperr GRE (PPTP)' @{ Protocol = 47 }
        }
        Set-ManagedHklm $Cfg $proxy 'ProxySettingsPerUser' 0
        Write-Ok 'VPN og proxy er sperret.'
    } else {
        foreach ($s in @('RasMan', 'SstpSvc')) { Set-ManagedService $Cfg $s $false }
        Restore-ManagedHklm $Cfg $proxy 'ProxySettingsPerUser'
        Write-Ok 'VPN-sperren er av.'
    }
    if (-not $Remove -and -not $script:InApplyAll) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg @() } }
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
    Write-Info 'Store Windows-oppdateringer kan tilbakestille noen av innstillingene.'
    Write-Info 'Skriptet kan sjekke ved hver oppstart og én gang om dagen, og bruke alt på nytt når Windows er oppdatert.'
    $Cfg.AutoReapply.Enabled = Read-YesNo 'Bruke alle innstillinger på nytt automatisk etter Windows-oppdateringer (anbefalt)?' ([bool]$Cfg.AutoReapply.Enabled)
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
    if ($r.ExitCode -ne 0) { Write-Warn "secedit: {0}" $($r.Output.Trim()) } elseif (-not $Restrict) { $Cfg.Backup.TimeZoneLine = '' }
    Remove-Item -LiteralPath $dir -Recurse -Force
}

function Apply-Extra([hashtable]$Cfg, [switch]$Remove) {
    $tz = $Cfg.Extra.TimeZone -and -not $Remove
    Set-TimeZonePrivilege $Cfg $tz
    if ($tz) { Write-Ok 'Barn kan ikke bytte tidssone.' }
    if ($Cfg.Extra.WinRE -and -not $Remove) {
        $r = Invoke-Native "$env:windir\System32\reagentc.exe" '/disable'
        if ($r.ExitCode -eq 0) { $Cfg.Backup.WinREDisabledByUs = $true; Write-Ok 'Gjenopprettingsmiljøet er slått av.' }
        else { Write-Warn "reagentc: {0}" $($r.Output.Trim()) }
    } elseif ($Cfg.Backup.WinREDisabledByUs) {
        $r = Invoke-Native "$env:windir\System32\reagentc.exe" '/enable'
        if ($r.ExitCode -eq 0) { $Cfg.Backup.WinREDisabledByUs = $false; Write-Ok 'Gjenopprettingsmiljøet er slått på igjen.' }
        else { Write-Warn "reagentc: {0}" $($r.Output.Trim()) }
    }
    if (-not $Remove -and -not $script:InApplyAll) { foreach ($c in $Cfg.Children) { Set-ChildHive $c $Cfg @() } }
    Register-UpdateTask $Cfg ([bool]$Remove)
    Save-Config $Cfg
}

# ============================================================== Etter Windows-oppdateringer

function Get-WindowsBuild {
    # For eksempel "26100.2605": byggnummer og oppdateringsnummer (UBR) endres ved hver Windows-oppdatering.
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return ('{0}.{1}' -f $cv.CurrentBuild, $cv.UBR)
}

function Get-MissingProtections([hashtable]$Cfg) {
    # Rask helsesjekk av sperrene som en oppdatering kan fjerne.
    $missing = @()
    $needTask = $Cfg.ScreenTime.Enabled -or $Cfg.Web.Enabled -or @($Cfg.Wifi.BlockPrefixes | Where-Object { $_ }).Count
    if ($needTask -and -not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) { $missing += (T 'håndhever-oppgaven') }
    if ($Cfg.Apps.Enabled -and @($Cfg.Children).Count -and -not (Test-IsHomeEdition)) {
        $ok = $false
        try { $ok = @((Get-AppLockerPolicy -Effective).RuleCollections | Where-Object { [string]$_.RuleCollectionType -eq 'Exe' -and @($_).Count -gt 0 }).Count -gt 0 } catch { }
        if (-not $ok) { $missing += (T 'AppLocker-regler') }
        $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
        if (-not $svc -or [string]$svc.StartType -ne 'Automatic') { $missing += (T 'AppLocker-tjenesten') }
    }
    $fw = @(Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($Cfg.Web.Enabled -and $Cfg.Web.BlockPublicDns -and $fw -notcontains 'FK-DNS-tcp') { $missing += (T 'brannmurregler for DNS') }
    if ($Cfg.Vpn.Enabled -and $Cfg.Vpn.BlockPorts -and $fw -notcontains 'FK-VPN-pptp') { $missing += (T 'brannmurregler for VPN') }
    if ($Cfg.Vpn.Enabled -and $Cfg.Vpn.DisableBuiltin) {
        $ras = Get-Service RasMan -ErrorAction SilentlyContinue
        if ($ras -and [string]$ras.StartType -ne 'Disabled') { $missing += (T 'VPN-tjenestene') }
    }
    return , $missing
}

function Register-UpdateTask([hashtable]$Cfg, [bool]$Remove = $false) {
    if ($Remove -or -not $Cfg.AutoReapply.Enabled) {
        Stop-ScheduledTask -TaskName $UpdateTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
        return
    }
    # Oppgaven kjører nettopp nå (og finnes derfor): ikke bytt den ut mens den kjører.
    if ($script:AutoMode) { return }
    # Sørg for at oppgaven kjører den nyeste versjonen av skriptet.
    Install-Files
    if (-not $Cfg.AutoReapply.LastBuild) { $Cfg.AutoReapply.LastBuild = Get-WindowsBuild }
    $ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $arg = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File &quot;$InstallDir\Setup-Foreldrekontroll.ps1&quot; -EtterOppdatering"
    $noon = (Get-Date).Date.AddHours(12).ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Foreldrekontroll: bruker alle innstillinger på nytt etter Windows-oppdateringer</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT3M</Delay></BootTrigger>
    <CalendarTrigger><StartBoundary>$noon</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <Priority>7</Priority>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowHardTerminate>true</AllowHardTerminate>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
  </Settings>
  <Actions Context="Author"><Exec><Command>$ps</Command><Arguments>$arg</Arguments></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $UpdateTaskName -Xml $xml -Force | Out-Null
    Write-Ok 'Innstillingene brukes automatisk på nytt etter Windows-oppdateringer.'
}

function Invoke-AutoReapply([hashtable]$Cfg) {
    # Kjøres av oppgaven som SYSTEM, uten vindu. Alt skrives til etter-oppdatering.log.
    $log = "$InstallDir\etter-oppdatering.log"
    if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 1MB)) { Move-Item -LiteralPath $log -Destination "$log.old" -Force }
    try { Start-Transcript -LiteralPath $log -Append | Out-Null } catch { }
    # Loggen kan nevne nettverksnavn og mapper; bare SYSTEM og administratorer får lese den.
    try {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', $SidAdmins)) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'Allow'))) }
        Set-Acl -LiteralPath $log -AclObject $acl
    } catch { }
    try {
        $today = (Get-Date).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $build = Get-WindowsBuild
        $Cfg.AutoReapply.LastCheck = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $reason = $null
        if ($Cfg.AutoReapply.LastBuild -and $Cfg.AutoReapply.LastBuild -ne $build) {
            $reason = T 'Windows er oppdatert ({0} til {1}).' $Cfg.AutoReapply.LastBuild $build
        } else {
            $miss = Get-MissingProtections $Cfg
            if ($miss.Count) { $reason = T 'Noe mangler: {0}.' ($miss -join ', ') }
        }
        if ($reason -and $Cfg.AutoReapply.LastFailDay -eq $today) {
            # Noe feilet allerede i dag: ikke prøv igjen hver gang, det kunne forstyrret barnet unødig.
            Write-Info '{0} Det ble forsøkt i dag uten å lykkes helt, så det prøves igjen i morgen.' $reason
        } elseif ($reason) {
            Write-Info '{0} Bruker alle innstillinger på nytt.' $reason
            $failed = Invoke-ApplyAll $Cfg
            $Cfg.AutoReapply.LastRun = (Get-Date).ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            if ($failed -eq 0) { $Cfg.AutoReapply.LastBuild = $build; $Cfg.AutoReapply.LastFailDay = '' }
            else { $Cfg.AutoReapply.LastFailDay = $today; Write-Warn 'Steg som feilet: {0}. Det prøves igjen i morgen.' $failed }
        } else {
            Write-Info 'Ingen endring siden sist.'
            $Cfg.AutoReapply.LastBuild = $build
        }
        Save-Config $Cfg
    } catch {
        Write-Err 'Noe gikk galt: {0}' $_.Exception.Message
    } finally {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

# ============================================================== 9. Status

function Show-Status([hashtable]$Cfg) {
    Write-Title 'Status'
    Write-Host (T '  Barnekontoer') -ForegroundColor White
    Show-Children $Cfg

    Write-Host ("`n" + (T '  Skjermtid')) -ForegroundColor White
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Cfg.ScreenTime.Enabled) { Write-Ok 'Slått på' } else { Write-Info 'Slått av' }
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        Write-Info "Håndhever-oppgaven: {0}, sist kjørt {1}, resultat {2}" $($task.State) $($info.LastRunTime) $($info.LastTaskResult)
    } elseif ($Cfg.ScreenTime.Enabled -or $Cfg.Web.Enabled) { Write-Err 'Håndhever-oppgaven mangler. Velg "Bruk alle innstillinger på nytt".' }
    Show-UsageToday $Cfg

    Write-Host ("`n" + (T '  Apper og spill')) -ForegroundColor White
    if (-not $Cfg.Apps.Enabled) { Write-Info 'Slått av' }
    elseif (Test-IsHomeEdition) { Write-Ok 'På (Software Restriction Policies i barnets profil)' }
    else {
        try {
            $pol = Get-AppLockerPolicy -Effective
            foreach ($rc in $pol.RuleCollections) { Write-Info '{0}: {1}, regler: {2}' $rc.RuleCollectionType $rc.EnforcementMode @($rc).Count }
        } catch { Write-Warn "Kunne ikke lese AppLocker: {0}" $($_.Exception.Message) }
        $svc = Get-Service AppIDSvc -ErrorAction SilentlyContinue
        if ($svc.Status -eq 'Running') { Write-Ok 'Tjenesten Application Identity kjører' } else { Write-Err "Tjenesten Application Identity: {0}" $($svc.Status) }
    }
    Write-Info "Sperret for barnet: {0} mapper, {1} Store-apper. Ekstra tillatt: {2} mapper." $(@($Cfg.Apps.DenyPaths).Count) $(@($Cfg.Apps.DenyPackages).Count) $(@($Cfg.Apps.AllowPaths).Count)

    Write-Host ("`n" + (T '  Trådløse nettverk')) -ForegroundColor White
    Write-Info "Modus: {0} {1}" $((Get-WifiModeTexts)[$Cfg.Wifi.Mode]) $(@($Cfg.Wifi.Ssids) -join ', ')
    Write-Info "Alltid sperret: {0}" $(Format-Prefixes $Cfg)
    $f = Invoke-Native "$env:windir\System32\netsh.exe" 'wlan show filters'
    foreach ($l in ($f.Output -split "`r?`n" | Where-Object { $_.Trim() })) { Write-Info $l.TrimEnd() }

    Write-Host ("`n" + (T '  Nettfilter')) -ForegroundColor White
    foreach ($nic in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
        $dns = @(Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses }) -join ', '
        Write-Info "{0} ({1}): {2}" $($nic.Name) $($nic.Status) $dns
    }

    Write-Host ("`n" + (T '  VPN og brannmur')) -ForegroundColor White
    $fw = @(Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue)
    Write-Info "Brannmurregler fra foreldrekontrollen: {0}" $($fw.Count)
    foreach ($s in @('RasMan', 'SstpSvc', 'AppIDSvc')) {
        $svc = Get-Service $s -ErrorAction SilentlyContinue
        if ($svc) { Write-Info "Tjeneste {0}: {1}, {2}" $s $($svc.StartType) $($svc.Status) }
    }

    Write-Host ("`n" + (T '  Ekstra')) -ForegroundColor White
    Write-Info "Tidssone sperret: {0},  regedit sperret: {1},  WinRE av: {2}" (Format-Bool $Cfg.Extra.TimeZone) (Format-Bool $Cfg.Extra.RegEdit) (Format-Bool $Cfg.Backup.WinREDisabledByUs)
    $ut = Get-ScheduledTask -TaskName $UpdateTaskName -ErrorAction SilentlyContinue
    Write-Info 'Ny bruk etter Windows-oppdateringer: {0} (oppgaven finnes: {1})' (Format-Bool $Cfg.AutoReapply.Enabled) (Format-Bool $ut)
    Write-Info 'Windows-versjon: {0}. Sist sjekket: {1}. Sist brukt på nytt automatisk: {2}.' (Get-WindowsBuild) $(if ($Cfg.AutoReapply.LastCheck) { $Cfg.AutoReapply.LastCheck } else { '-' }) $(if ($Cfg.AutoReapply.LastRun) { $Cfg.AutoReapply.LastRun } else { '-' })
    $miss = Get-MissingProtections $Cfg
    if ($miss.Count) { Write-Err 'Noe mangler: {0}.' ($miss -join ', ') }

    Write-Host ("`n" + (T '  Kjente begrensninger')) -ForegroundColor White
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
    $failed = 0
    $script:InApplyAll = $true
    try {
        foreach ($s in $steps) {
            try { $null = & $s.S } catch { Write-Err "{0}: {1}" (T $s.N) $($_.Exception.Message); $failed++ }
        }
        # Barnets profil oppdateres én gang til slutt. Etter en oppdatering hoppes profilen over hvis
        # barnet ikke er pålogget: å åpne barnets register akkurat da kunne krasje med en pålogging,
        # og innstillingene i profilen fjernes ikke av Windows-oppdateringer.
        foreach ($c in $Cfg.Children) {
            if ($script:AutoMode -and -not (Test-Path -LiteralPath "Registry::HKEY_USERS\$($c.Sid)")) { continue }
            try { $null = Set-ChildHive $c $Cfg @() } catch { Write-Err "{0}: {1}" (T 'Barnas profiler') $($_.Exception.Message); $failed++ }
        }
    } finally { $script:InApplyAll = $false }
    if ($failed -eq 0) { try { $Cfg.AutoReapply.LastBuild = Get-WindowsBuild } catch { } }
    Save-Config $Cfg
    return $failed
}

function Invoke-RemoveAll([hashtable]$Cfg) {
    Write-Title 'Fjern all foreldrekontroll'
    if (-not (Read-YesNo 'Er du sikker på at du vil fjerne alle sperrene?' $false)) { return }
    $steps = @(
        @{ N = 'Oppgave';    S = {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Stop-ScheduledTask -TaskName $UpdateTaskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Ok 'Håndhever-oppgaven er fjernet.' } }
        @{ N = 'Påloggingstider'; S = { $Cfg.ScreenTime.Enabled = $false; foreach ($c in $Cfg.Children) { Set-LogonHours $Cfg $c } } }
        @{ N = 'Apper';      S = {
            $Cfg.Apps.Enabled = $false
            if (-not (Test-IsHomeEdition)) { Restore-AppLocker $Cfg; Write-Ok 'AppLocker-reglene er fjernet.' }
            Restore-ManagedHklm $Cfg 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\Installer' 'DisableUserInstalls'
            Restore-ManagedHklm $Cfg 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'ConsentPromptBehaviorUser' } }
        @{ N = 'Wi-Fi';      S = { Apply-Wifi $Cfg -Remove } }
        @{ N = 'Nettfilter'; S = { Apply-Web $Cfg -Remove } }
        @{ N = 'VPN';        S = { Apply-Vpn $Cfg -Remove } }
        @{ N = 'Ekstra';     S = { Apply-Extra $Cfg -Remove } }
        @{ N = 'Brannmur';   S = { Get-NetFirewallRule -Group $FwGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule } }
        @{ N = 'Barnas profiler'; S = { foreach ($c in $Cfg.Children) { if (Get-LocalUser -SID $c.Sid -ErrorAction SilentlyContinue) { Set-ChildHive $c $Cfg @() $true; Write-Ok "Sperrer fjernet fra profilen til {0}." $($c.Name) } } } }
    )
    foreach ($s in $steps) {
        try { & $s.S } catch { Write-Err "{0}: {1}" (T $s.N) $($_.Exception.Message) }
    }
    # Gjenstående sikkerhetskopier (for eksempel verdier fra tidligere versjoner).
    foreach ($k in @($Cfg.Backup.Registry.Keys)) { $p = $k.Split('|'); Restore-ManagedHklm $Cfg $p[0] $p[1] }
    foreach ($s in @($Cfg.Backup.Services.Keys)) { Set-ManagedService $Cfg $s $false }
    $Cfg.ScreenTime.Enabled = $false; $Cfg.Web.Enabled = $false; $Cfg.Vpn.Enabled = $false
    $Cfg.Wifi.Mode = 'off'; $Cfg.Extra.TimeZone = $false; $Cfg.Extra.WinRE = $false; $Cfg.Extra.RegEdit = $false
    Save-Config $Cfg
    if ((Test-IsHomeEdition) -and @($Cfg.Children).Count) {
        $gone = @($Cfg.Backup.StoreRemovedFor | Sort-Object -Unique)
        if ($gone.Count) {
            Write-Info "Windows Home: disse appene ble fjernet for barnet: {0}" $($gone -join ', ')
            Write-Info 'Logg inn som barnet og kjør wsreset -i for å få Store tilbake, og installer de andre fra Store.'
            $Cfg.Backup.StoreRemovedFor = @()
        }
    }
    foreach ($c in @($Cfg.Children)) {
        if ((Get-LocalUser -SID $c.Sid -ErrorAction SilentlyContinue) -and (Read-YesNo (T "Slette kontoen {0} også (filene i profilen blir liggende)?" $($c.Name)) $false)) {
            Remove-LocalUser -SID $c.Sid
            $Cfg.Children = @($Cfg.Children | Where-Object { $_.Sid -ne $c.Sid })
            Write-Ok "Kontoen {0} er slettet." $($c.Name)
        }
    }
    Save-Config $Cfg
    foreach ($f in @('PcWts3.dll', 'dns-reparert.json', 'applocker.xml', 'usage.json', 'wifi-sperret.json', 'etter-oppdatering.log', 'etter-oppdatering.log.old')) {
        Remove-Item -LiteralPath (Join-Path $InstallDir $f) -Force -ErrorAction SilentlyContinue
    }
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
    Write-Host (T '  FORELDREKONTROLL FOR WINDOWS 11') -ForegroundColor Cyan
    Write-Host ''
    Write-Host (T '   H. Hurtigoppsett (anbefalt første gang)')
    Write-Host (T '   1. Barnekontoer')
    Write-Host (T '   2. Skjermtid')
    Write-Host (T '   3. Apper og spill')
    Write-Host (T '   4. Trådløse nettverk')
    Write-Host (T '   5. Nettfilter (voksensider, SafeSearch, DNS)')
    Write-Host (T '   6. VPN og proxy')
    Write-Host (T '   7. Ekstra sikring')
    Write-Host (T '   8. Gi ekstra tid i dag')
    Write-Host (T '   9. Vis status')
    Write-Host (T '  10. Bruk alle innstillinger på nytt')
    Write-Host (T '  11. Fjern all foreldrekontroll')
    Write-Host '   L. Språk / Мова'
    Write-Host (T '   0. Avslutt')
}

function Start-Main {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Skriptet må kjøres som administrator ... / Скрипт потрібно запускати від імені адміністратора ...'
        $args2 = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        if ($BrukPaaNytt) { $args2 += ' -BrukPaaNytt' }
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList $args2 -Verb RunAs
        return
    }
    $script:AutoMode = [bool]$EtterOppdatering
    # Bare én kjøring om gangen; låsen holdes til skriptet avsluttes.
    $script:SettingsLock = Lock-Settings
    if (-not $script:SettingsLock) {
        Write-Err 'En annen kjøring av foreldrekontrollen pågår. Prøv igjen om litt.'
        return
    }
    $cfg = Get-Config
    if ($null -eq $cfg) {
        Write-Err 'Konfigurasjonen ({0}) er skadet, og sikkerhetskopien kan heller ikke leses. Ingenting er endret.' $ConfigPath
        Write-Err 'Gi filen et annet navn og kjør skriptet på nytt for å starte med nye innstillinger.'
        return
    }
    if ($cfg.Language) { Import-Language $cfg.Language }
    elseif (-not ($BrukPaaNytt -or $EtterOppdatering)) { Select-Language $cfg; Save-Config $cfg }
    if ($EtterOppdatering) {
        if ($cfg.AutoReapply.Enabled -and (Test-Path -LiteralPath $ConfigPath)) { Invoke-AutoReapply $cfg }
        return
    }
    # Husk den voksne som kjører skriptet, så kontoen alltid er unntatt app-sperren.
    $me = Get-CurrentUserSid
    if ($me -ne 'S-1-5-18' -and @($cfg.Children | ForEach-Object { $_.Sid }) -notcontains $me -and @($cfg.Apps.TrustedSids) -notcontains $me) {
        $cfg.Apps.TrustedSids = @($cfg.Apps.TrustedSids) + @($me)
        if (Test-Path -LiteralPath $ConfigPath) { Save-Config $cfg }
    }
    if ($BrukPaaNytt) { [void](Invoke-ApplyAll $cfg); return }
    while ($true) {
        Show-Menu
        $c = ConvertTo-MenuKey (Read-Host ("`n" + (T '  Valg')))
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
                '10' { [void](Invoke-ApplyAll $cfg); Wait-Key }
                '11' { Invoke-RemoveAll $cfg; Wait-Key }
                { $_ -ieq 'l' } { Select-Language $cfg; Save-Config $cfg }
                '0'  { return }
            }
        } catch {
            Write-Err "Noe gikk galt: {0}" $($_.Exception.Message)
            Write-Info "({0}:{1})" $($_.InvocationInfo.ScriptName) $($_.InvocationInfo.ScriptLineNumber)
            Wait-Key
        }
    }
}

# Kan "dot-sources" for testing uten at menyen starter.
if ($MyInvocation.InvocationName -ne '.') { Start-Main }
