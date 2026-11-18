<#
    Tester Wi-Fi-filtrene (særlig de alltid sperrede Anlegg-navnene) mot en simulert netsh, og
    konfigurasjonsfilene og AppLocker-ID-ene. Kjøres uten Windows:  pwsh -File tests/Test-Logikk.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $env:windir) { $env:windir = 'C:\Windows'; $env:ProgramFiles = 'C:\Program Files'; ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'; $env:SystemRoot = 'C:\Windows' }
. (Join-Path $root 'Setup-Foreldrekontroll.ps1')
${function:Save-ConfigReal} = ${function:Save-Config}
$work = Join-Path $root 'scratchpad/test-logikk'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null
$fail = 0
function Check([string]$Name, $Got, $Want) {
    if ("$Got" -ceq "$Want") { [Console]::WriteLine("  ok   $Name") } else { [Console]::WriteLine("  FEIL $Name : fikk '$Got', ventet '$Want'"); $script:fail++ }
}

# ------------------------------------------------------------ simulert netsh
$script:filters = New-Object 'System.Collections.Generic.HashSet[string]'   # "allow|navn", "block|navn", "denyall|infrastructure"
$script:visible = @()
$script:calls = 0
function Invoke-Native([string]$Exe, [string]$Arguments) {
    $out = ''
    if ($Arguments -match '^wlan (add|delete) filter permission=(allow|block) ssid="([^"]*)" networktype=infrastructure$') {
        $script:calls++
        $k = "$($Matches[2])|$($Matches[3])"
        if ($Matches[1] -eq 'add') { [void]$script:filters.Add($k) } else { [void]$script:filters.Remove($k) }
        if ([Text.Encoding]::UTF8.GetByteCount($Matches[3]) -gt 32) { return [pscustomobject]@{ ExitCode = 1; Output = 'SSID too long' } }
    } elseif ($Arguments -match '^wlan (add|delete) filter permission=denyall networktype=(\w+)$') {
        $k = "denyall|$($Matches[2])"
        if ($Matches[1] -eq 'add') { [void]$script:filters.Add($k) } else { [void]$script:filters.Remove($k) }
    } elseif ($Arguments -eq 'wlan show filters') {
        $out = (@($script:filters) | Sort-Object | ForEach-Object {
            $p = $_.Split('|', 2)
            if ($p[0] -eq 'denyall') { "    Type: $($p[1])" } else { "    SSID: `"$($p[1])`", Type: Infrastructure ($($p[0]))" }
        }) -join "`n"
    } elseif ($Arguments -eq 'wlan show networks mode=ssid') {
        $i = 0; $out = ($script:visible | ForEach-Object { $i++; "SSID $i : $_" }) -join "`n"
    } elseif ($Arguments -eq 'wlan show interfaces') {
        $out = '    SSID                   : Hjemme'
    }
    return [pscustomobject]@{ ExitCode = 0; Output = $out }
}
function Get-SavedSsids { return @() }
function Get-NetAdapter { return @() }
function Get-ScheduledTask { return [pscustomobject]@{ State = 'Ready' } }
function Save-Config { }
function Install-Files { }
function Register-EnforcerTask { }
function Write-Host { }
function Test-HasWifi { $true }
function Get-NetFirewallRule { @() }
function Get-Service { $null }
$WifiStatePath = Join-Path $work 'wifi-sperret.json'

function Get-Blocked { @(Get-UniqueSsids @($script:filters | Where-Object { $_ -like 'block|*' } | ForEach-Object { $_.Substring(6) })) }
function Get-Allowed { @($script:filters | Where-Object { $_ -like 'allow|*' } | ForEach-Object { $_.Substring(6) } | Sort-Object) }
$anlegg = @(1..50 | ForEach-Object { "Anlegg$_" } | Sort-Object)

Write-Host ''
[Console]::WriteLine('== Anlegg og Wi-Fi-filtre ==')
$cfg = Get-DefaultConfig
Check 'Get-PrefixSsids gir 50 enkeltnavn' (@(Get-PrefixSsids $cfg).Count) 50
Check 'Get-PrefixSsids første og siste' ((@(Get-PrefixSsids $cfg)[0]) + ',' + (@(Get-PrefixSsids $cfg)[-1])) 'Anlegg1,Anlegg50'

# 1. Standard (Wi-Fi-filter av): Anlegg1-50 + synlige Anlegg77 og anlegg3 sperres
$script:visible = @('Hjemme', 'Anlegg77', 'anlegg3', 'AnleggX', 'MinAnlegg5')
Apply-Wifi $cfg
$want = @(Get-UniqueSsids $anlegg 'Anlegg77' 'anlegg3')
Check 'av: nøyaktig Anlegg1-50 + synlige Anlegg-navn sperret' ((Get-Blocked) -join ',') ($want -join ',')
Check 'av: AnleggX og MinAnlegg5 ikke sperret' ((Get-Blocked) -ccontains 'AnleggX' -or (Get-Blocked) -ccontains 'MinAnlegg5') $false
Check 'av: ingen tillat-filtre eller sperr-alt' (@(Get-Allowed).Count + [int]$script:filters.Contains('denyall|infrastructure')) 0
Check 'av: lagret liste er flat (bare tekst)' (@($cfg.Wifi.AppliedPrefixSsids | Where-Object { $_ -isnot [string] }).Count) 0
Check 'av: lagret liste har 52 navn' (@($cfg.Wifi.AppliedPrefixSsids).Count) 52

# 2. Ny kjøring uten endring: ingen netsh-endringer
$script:calls = 0
Apply-Wifi $cfg
Check 'uendret: ingen filtre lagt til eller fjernet' $script:calls 0

# 3. Windows har fjernet alle filtrene: de legges inn igjen
$script:filters.Clear()
Apply-Wifi $cfg
Check 'fjernet av Windows: alle sperret igjen' ((Get-Blocked) -join ',') ($want -join ',')
Check 'helsesjekk ser at alt er på plass' (@(Get-MissingProtections $cfg | Where-Object { $_ -eq (T 'Wi-Fi-filtre') }).Count) 0
$script:filters.Remove('block|Anlegg1') | Out-Null
Check 'helsesjekk merker manglende Anlegg1' (@(Get-MissingProtections $cfg | Where-Object { $_ -eq (T 'Wi-Fi-filtre') }).Count) 1
[void]$script:filters.Add('block|Anlegg1')

# 4. Håndheveren har sperret Anlegg120 (ikke synlig lenger): beholdes
'["Anlegg120"]' | Set-Content -LiteralPath $WifiStatePath
$script:visible = @('Hjemme')
Apply-Wifi $cfg
Check 'håndhevers Anlegg120 beholdes' ((Get-Blocked) -ccontains 'Anlegg120') $true
Check 'tilstandsfil ryddet' (Test-Path -LiteralPath $WifiStatePath) $false
Apply-Wifi $cfg
Check 'Anlegg120 beholdes også ved neste kjøring' ((Get-Blocked) -ccontains 'Anlegg120') $true

# 5. Bare tillatte: Hjemme tillatt, sperr alt annet, Anlegg-filtrene trengs ikke
$cfg.Wifi.Mode = 'allow'; $cfg.Wifi.Ssids = @('Hjemme')
Apply-Wifi $cfg
Check 'tillat: bare Hjemme tillatt' ((Get-Allowed) -join ',') 'Hjemme'
Check 'tillat: sperr alt annet er på' $script:filters.Contains('denyall|infrastructure') $true
Check 'tillat: Anlegg-sperrer fjernet (dekket av sperr alt annet)' (@($script:filters | Where-Object { $_ -like 'block|*' }).Count) 0

# 6. Endre listen i tillat-modus: sperr-alt fjernes aldri underveis
$cfg.Wifi.Ssids = @('Hjemme', 'Skole')
Apply-Wifi $cfg
Check 'tillat, ny liste' ((Get-Allowed) -join ',') 'Hjemme,Skole'

# 7. Sperr bestemte: Nabo + Anlegg1-50
$cfg.Wifi.Mode = 'block'; $cfg.Wifi.Ssids = @('Nabo', 'Anlegg7')
Apply-Wifi $cfg
Check 'sperr: ingen tillat-filtre, ingen sperr-alt' (@(Get-Allowed).Count + [int]$script:filters.Contains('denyall|infrastructure')) 0
# Ekstra navn håndheveren fant, glemmes i tillat-modus (der sperres alt annet uansett); håndheveren
# finner dem igjen. Nabo og Anlegg7 er valgt selv.
$wantB = @(Get-UniqueSsids $anlegg 'Nabo')
Check 'sperr: Nabo + Anlegg-navn sperret' ((Get-Blocked) -join ',') ($wantB -join ',')

# 8. Prefiks av ("ingen"): Anlegg-sperrene fjernes, Nabo og Anlegg7 (valgt selv) blir
$cfg.Wifi.BlockPrefixes = @()
Apply-Wifi $cfg
Check 'prefiks av: bare valgte sperret' ((Get-Blocked) -join ',') 'Anlegg7,Nabo'
$cfg.Wifi.BlockPrefixes = @('Anlegg')

# 9. Gammel, nestet liste fra eldre versjon
$cfg2 = Get-DefaultConfig
$script:filters.Clear()
$cfg2.Wifi.AppliedPrefixSsids = @(, @('Anlegg1', 'Anlegg2'))
Apply-Wifi $cfg2
Check 'nestet liste: ingen sammenslåtte navn' (@(Get-Blocked | Where-Object { $_ -match ' ' }).Count) 0
Check 'nestet liste: Anlegg1-50 sperret' (@(Get-Blocked | Where-Object { $anlegg -ccontains $_ }).Count) 50

# 10. Fjern alt: ingen filtre igjen
Apply-Wifi $cfg -Remove
Apply-Wifi $cfg2 -Remove
Check 'fjern: ingen filtre igjen' $script:filters.Count 0

[Console]::WriteLine('== AppLocker-ID-er ==')
$c = Get-DefaultConfig; $c.Apps.Enabled = $true
$c.Apps.DenyPackages = @(@{ Name = 'Microsoft.GamingApp'; Publisher = 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US' })
$x = [xml](New-AppLockerXml $c @('S-1-5-21-1-2-3-1001') @('S-1-5-21-1-2-3-1000') @('C:\Windows\Temp'))
$idList = @($x.SelectNodes('//*[@Id]') | ForEach-Object { $_.Id })
Check 'alle regel-ID-er er unike' ($idList.Count -eq @($idList | Sort-Object -Unique).Count) $true
$x2 = [xml](New-AppLockerXml $c @('S-1-5-21-1-2-3-1001') @('S-1-5-21-1-2-3-1000') @('C:\Windows\Temp'))
Check 'samme innstillinger gir samme XML' ($x.OuterXml -ceq $x2.OuterXml) $true

[Console]::WriteLine('== Konfigurasjonsfiler ==')
$ConfigPath = Join-Path $work 'config.json'; $InstallDir = $work
$g = Get-DefaultConfig; $g.Language = 'uk'; $g.Children = @(@{ Name = 'emma'; Sid = 'S-1-5-21-9' })
Save-ConfigReal $g
Check 'lagret og lest' ((Get-Config).Language) 'uk'
$g.Language = 'nb'; Save-ConfigReal $g
Check '.bak inneholder forrige versjon' ((Get-Content "$ConfigPath.bak" -Raw | ConvertFrom-Json).Language) 'uk'
'{ halv fil' | Set-Content $ConfigPath
Check 'skadet config.json: .bak brukes' ((Get-Config).Language) 'uk'
Check 'skadet config.json: god kopi lagt tilbake' ((Get-Content $ConfigPath -Raw | ConvertFrom-Json).Language) 'uk'
Remove-Item $ConfigPath
Check 'config.json mangler: .bak brukes, ikke standardverdier' (@((Get-Config).Children).Count) 1
'{ x' | Set-Content $ConfigPath; '{ y' | Set-Content "$ConfigPath.bak"
Check 'alle skadet: $null (ingenting overskrives)' ($null -eq (Get-Config)) $true
Remove-Item "$ConfigPath*"
Check 'ingen filer: standardverdier' ((Get-Config).Version) 1

if ($fail) { [Console]::WriteLine("$fail feil"); exit 1 } else { [Console]::WriteLine('OK') }
