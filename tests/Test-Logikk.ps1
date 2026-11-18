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
$script:ops = New-Object System.Collections.ArrayList
function Invoke-Native([string]$Exe, [string]$Arguments) {
    $out = ''
    if ($Arguments -match '^wlan (add|delete) filter permission=(allow|block) ssid="([^"]*)" networktype=infrastructure$') {
        $script:calls++
        $k = "$($Matches[2])|$($Matches[3])"
        [void]$script:ops.Add("$($Matches[1])|$k")
        if ($Matches[1] -eq 'add') { [void]$script:filters.Add($k) } else { [void]$script:filters.Remove($k) }
        if ([Text.Encoding]::UTF8.GetByteCount($Matches[3]) -gt 32) { return [pscustomobject]@{ ExitCode = 1; Output = 'SSID too long' } }
    } elseif ($Arguments -match '^wlan (add|delete) filter permission=denyall networktype=(\w+)$') {
        $k = "denyall|$($Matches[2])"
        [void]$script:ops.Add("$($Matches[1])|$k")
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
$nums = @(1..50 | ForEach-Object { [string]$_ }) + @(1..9 | ForEach-Object { '0' + $_ })
$anlegg = @(Get-UniqueSsids @(foreach ($v in 'Anlegg', 'ANLEGG', 'anlegg') { foreach ($n in $nums) { "$v$n" } }))

Write-Host ''
[Console]::WriteLine('== Anlegg og Wi-Fi-filtre ==')
$cfg = Get-DefaultConfig
Check 'Get-PrefixSsids: 3 skrivemåter x 59 tall = 177 enkeltnavn' (@(Get-PrefixSsids $cfg).Count) 177
Check 'Get-PrefixSsids har Anlegg1, Anlegg50, ANLEGG3, anlegg7, Anlegg01' (@('Anlegg1', 'Anlegg50', 'ANLEGG3', 'anlegg7', 'Anlegg01' | Where-Object { @(Get-PrefixSsids $cfg) -ccontains $_ }).Count) 5
Check 'Get-UniqueSsids uten navn gir tom liste' (@(Get-UniqueSsids).Count) 0

# 1. Standard (Wi-Fi-filter av): Anlegg1-50 + synlige Anlegg77 og anlegg3 sperres
$script:visible = @('Hjemme', 'Anlegg77', 'anlegg3', 'AnleggX', 'MinAnlegg5')
Apply-Wifi $cfg
$want = @(Get-UniqueSsids $anlegg 'Anlegg77')
Check 'av: nøyaktig Anlegg1-50 + synlige Anlegg-navn sperret' ((Get-Blocked) -join ',') ($want -join ',')
Check 'av: AnleggX og MinAnlegg5 ikke sperret' ((Get-Blocked) -ccontains 'AnleggX' -or (Get-Blocked) -ccontains 'MinAnlegg5') $false
Check 'av: ingen tillat-filtre eller sperr-alt' (@(Get-Allowed).Count + [int]$script:filters.Contains('denyall|infrastructure')) 0
Check 'av: lagret liste er flat (bare tekst)' (@($cfg.Wifi.AppliedPrefixSsids | Where-Object { $_ -isnot [string] }).Count) 0
Check 'av: lagret liste har 178 navn' (@($cfg.Wifi.AppliedPrefixSsids).Count) 178

# 2. Ny kjøring uten endring: ingen netsh-endringer
$script:calls = 0
Apply-Wifi $cfg
Check 'uendret: ingen filtre lagt til eller fjernet' $script:calls 0

# 3. Windows har fjernet alle filtrene: de legges inn igjen
$script:filters.Clear()
Apply-Wifi $cfg
Check 'fjernet av Windows: alle sperret igjen' ((Get-Blocked) -join ',') ($want -join ',')
Check 'helsesjekk ser at alt er på plass' (@(Get-MissingProtections $cfg | Where-Object { $_ -eq (T 'Wi-Fi-filtre') }).Count) 0
$script:filters.Remove('block|Anlegg37') | Out-Null
Check 'helsesjekk merker manglende Anlegg37 (ikke bare Anlegg1)' (@(Get-MissingProtections $cfg | Where-Object { $_ -eq (T 'Wi-Fi-filtre') }).Count) 1
[void]$script:filters.Add('block|Anlegg37')

# 4. Håndheveren har sperret Anlegg120 (ikke synlig lenger): beholdes
'["Anlegg120"]' | Set-Content -LiteralPath $WifiStatePath
$script:visible = @('Hjemme')
Apply-Wifi $cfg
Check 'håndhevers Anlegg120 beholdes' ((Get-Blocked) -ccontains 'Anlegg120') $true
Check 'tilstandsfil ryddet' (Test-Path -LiteralPath $WifiStatePath) $false
Apply-Wifi $cfg
Check 'Anlegg120 beholdes også ved neste kjøring' ((Get-Blocked) -ccontains 'Anlegg120') $true

# 5. Bare tillatte: Hjemme tillatt, sperr alt annet; Anlegg3 kan ikke tillates, og Anlegg-sperrene blir
$cfg.Wifi.Mode = 'allow'; $cfg.Wifi.Ssids = @('Hjemme', 'Anlegg3')
$script:ops.Clear()
Apply-Wifi $cfg
Check 'tillat: bare Hjemme tillatt (Anlegg3 avvist)' ((Get-Allowed) -join ',') 'Hjemme'
Check 'tillat: sperr alt annet er på' $script:filters.Contains('denyall|infrastructure') $true
Check 'tillat: Anlegg-sperrene står fortsatt' (@(Get-Blocked | Where-Object { $anlegg -ccontains $_ }).Count) 177
Check 'tillat: Anlegg3 sperret' ((Get-Blocked) -ccontains 'Anlegg3') $true

# 6. Endre listen i tillat-modus: sperr-alt fjernes aldri underveis
$cfg.Wifi.Ssids = @('Hjemme', 'Skole')
Apply-Wifi $cfg
Check 'tillat, ny liste' ((Get-Allowed) -join ',') 'Hjemme,Skole'

# 7. Sperr bestemte: Nabo + Anlegg-navn. Ingen glipp: sperr-alt fjernes først etter at alt nytt er lagt inn.
$cfg.Wifi.Mode = 'block'; $cfg.Wifi.Ssids = @('Nabo', 'Anlegg7')
$script:ops.Clear()
Apply-Wifi $cfg
$iDeny = $script:ops.IndexOf('delete|denyall|infrastructure')
$lastAdd = -1; for ($i = 0; $i -lt $script:ops.Count; $i++) { if ($script:ops[$i] -like 'add|*') { $lastAdd = $i } }
Check 'tillat til sperr: alt nytt lagt inn før sperr-alt fjernes' ($iDeny -gt $lastAdd -and $iDeny -ge 0) $true
Check 'sperr: ingen tillat-filtre, ingen sperr-alt' (@(Get-Allowed).Count + [int]$script:filters.Contains('denyall|infrastructure')) 0
# Anlegg-sperrene (også Anlegg77 og Anlegg120 som håndheveren fant) står gjennom tillat-modus.
$wantB = @(Get-UniqueSsids $anlegg 'Anlegg77' 'Anlegg120' 'Nabo')
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
Check 'nestet liste: alle Anlegg-navn sperret' (@(Get-Blocked | Where-Object { $anlegg -ccontains $_ }).Count) 177

# 10. Skadet tilstandsfil: tas vare på som .feil, sperrene virker
'{ halv' | Set-Content -LiteralPath $WifiStatePath
Apply-Wifi $cfg
Check 'skadet tilstandsfil: lagt til side' (Test-Path -LiteralPath "$WifiStatePath.feil") $true
Check 'skadet tilstandsfil: sperrene står' (@(Get-Blocked | Where-Object { $anlegg -ccontains $_ }).Count) 177

# 11. Fjern alt: ingen filtre igjen, også et sperrefilter uten bokføring (Anlegg999)
[void]$script:filters.Add('block|Anlegg999')
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
