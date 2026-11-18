<#
    Kjører det ukrainske grensesnittet med norsk, engelsk og ukrainsk Windows-kultur (nb-NO, en-US,
    uk-UA) og sjekker formatering, store/små bokstaver, ja/nei-svar og menybokstaver fra kyrillisk
    tastatur. Kjør:  pwsh -File tests/Test-Kulturer.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $env:windir) { $env:windir = 'C:\Windows'; $env:ProgramFiles = 'C:\Program Files'; ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)' }
. (Join-Path $root 'Setup-Foreldrekontroll.ps1')
$fail = 0
function Check([string]$Name, $Got, $Want) {
    if ($Got -ceq $Want) { Write-Host "  ok   $Name" } else { Write-Host "  FEIL $Name : fikk '$Got', ventet '$Want'" -ForegroundColor Red; $script:fail++ }
}
foreach ($culture in 'nb-NO', 'en-US', 'uk-UA') {
    [Threading.Thread]::CurrentThread.CurrentCulture = $culture
    [Threading.Thread]::CurrentThread.CurrentUICulture = $culture
    Write-Host "== Windows-kultur $culture, språk uk ==" -ForegroundColor Cyan
    Import-Language 'uk'
    Check 'menytittel' (T '  FORELDREKONTROLL FOR WINDOWS 11') '  БАТЬКІВСЬКИЙ КОНТРОЛЬ ДЛЯ WINDOWS 11'
    Check 'plassholder' (T "Kontoen '{0}' er laget som standardbruker." 'emma') 'Обліковий запис стандартного користувача «emma» створено.'
    Check 'tid' (Format-Limit 90) '1 год 30 хв'
    Check 'sperret, store' ((T 'sperret').ToUpper()) 'ЗАБЛОКОВАНО'
    Check 'hex' (T 'Kunne ikke lage brukerprofil for {0} (HRESULT 0x{1:X8}).' 'emma' ([int]-2147024713)) 'Не вдалося створити профіль користувача emma (HRESULT 0x800700B7).'
    Check 'dato' ((Get-Date '2026-11-18T07:05:00').ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)) '2026-11-18T07:05:00'
    foreach ($k in @(@('р', 'h'), @('Р', 'h'), @('д', 'l'), @('п', 'g'), @('і', 's'), @('ы', 's'), @('ч', 'x'), @('ь', 'm'), @('H', 'h'), @('10', '10'))) {
        Check "menytast $($k[0])" (ConvertTo-MenuKey $k[0]) $k[1]
    }
    $n = 0
    Check 'tall -30' ([int]::TryParse('-30', [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -eq -30) $true
    Check 'ingen-ord немає' (Test-NoLimitWord 'немає') $true
    Check 'ingen-ord без' (Test-NoLimitWord 'без') $true
    Check 'ingen-ord ingen' (Test-NoLimitWord 'ingen') $true
}
# Ja/nei med tastet kyrillisk (Read-Host leser fra omdirigert inndata).
[Threading.Thread]::CurrentThread.CurrentCulture = 'nb-NO'
Import-Language 'uk'
function Read-Host { param($Prompt) return $script:answers.Dequeue() }
$script:answers = New-Object System.Collections.Queue
foreach ($a in 'т', 'Т', 'так', 'ТАК', 'н', 'Н', 'ні', 'j', 'n', 'y') { $script:answers.Enqueue($a) }
$want = @($true, $true, $true, $true, $false, $false, $false, $true, $false, $true)
for ($i = 0; $i -lt $want.Count; $i++) { Check "ja/nei svar $i" (Read-YesNo 'Slå på skjermtid?' $false) $want[$i] }
if ($fail) { Write-Host "$fail feil" -ForegroundColor Red; exit 1 } else { Write-Host 'OK' -ForegroundColor Green }
