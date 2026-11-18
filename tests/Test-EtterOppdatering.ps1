<#
    Tester logikken for automatisk ny bruk etter Windows-oppdateringer, med Windows-delene byttet ut
    (kan kjøres uten Windows). Sjekker også at XML-en for begge planlagte oppgaver er gyldig.
    Kjør:  pwsh -File tests/Test-EtterOppdatering.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $env:windir) { $env:windir = 'C:\Windows'; $env:ProgramFiles = 'C:\Program Files'; ${env:ProgramFiles(x86)} = 'C:\Program Files (x86)'; $env:SystemRoot = 'C:\Windows' }
. (Join-Path $root 'Setup-Foreldrekontroll.ps1')
$fail = 0
function Check([string]$Name, $Got, $Want) {
    if ($Got -eq $Want) { Write-Host "  ok   $Name" } else { [Console]::WriteLine("  FEIL $Name : fikk $Got, ventet $Want"); $script:fail++ }
}
# Bytt ut alt som rører Windows.
$script:build = '26100.2605'; $script:missing = @(); $script:applied = 0; $script:xml = @{}
function Get-WindowsBuild { $script:build }
function Get-MissingProtections { , @($script:missing) }
function Invoke-ApplyAll { $script:applied++; return $script:failNext }
$script:failNext = 0
function Save-Config { }
function Install-Files { }
function Stop-ScheduledTask { param($TaskName, $ErrorAction) }
function Start-Transcript { }
function Stop-Transcript { }
function Write-Host { }
function Register-ScheduledTask { param($TaskName, $Xml, [switch]$Force) $script:xml[$TaskName] = $Xml }
function Unregister-ScheduledTask { param($TaskName, [switch]$Confirm, $ErrorAction) $script:xml.Remove($TaskName) }
function Get-Item { [pscustomobject]@{ Length = 0 } }
function Test-Path { $false }

$cfg = Get-DefaultConfig
$cfg.AutoReapply.LastBuild = '26100.2605'
Invoke-AutoReapply $cfg
Check 'samme versjon, alt på plass: ingen ny bruk' $script:applied 0

$script:build = '26100.2894'
Invoke-AutoReapply $cfg
Check 'ny versjon: bruk på nytt' $script:applied 1
Check 'ny versjon lagret' $cfg.AutoReapply.LastBuild '26100.2894'

Invoke-AutoReapply $cfg
Check 'neste sjekk uten endring: ingen ny bruk' $script:applied 1

$script:missing = @('AppLocker-regler')
Invoke-AutoReapply $cfg
Check 'sperre mangler: bruk på nytt' $script:applied 2
$script:missing = @()

# Et steg feiler: versjonen lagres ikke, og det prøves ikke igjen samme dag.
$script:build = '26100.3000'; $script:failNext = 1
Invoke-AutoReapply $cfg
Check 'feil: bruk på nytt forsøkt' $script:applied 3
Check 'feil: versjon ikke lagret' $cfg.AutoReapply.LastBuild '26100.2894'
Invoke-AutoReapply $cfg
Check 'feil: ikke nytt forsøk samme dag' $script:applied 3
$cfg.AutoReapply.LastFailDay = '2000-01-01'; $script:failNext = 0
Invoke-AutoReapply $cfg
Check 'neste dag: nytt forsøk som lykkes' $script:applied 4
Check 'etter suksess: versjon lagret' $cfg.AutoReapply.LastBuild '26100.3000'

$cfg2 = Get-DefaultConfig
Invoke-AutoReapply $cfg2
Check 'første kjøring uten lagret versjon: bare lagre' $script:applied 4
Check 'første kjøring lagrer versjon' $cfg2.AutoReapply.LastBuild '26100.3000'

# Oppgave-XML
Register-UpdateTask $cfg
$x = [xml]$script:xml[$UpdateTaskName]
Check 'oppdateringsoppgave: gyldig XML med oppstart og daglig utløser' (($x.Task.Triggers.BootTrigger -ne $null) -and ($x.Task.Triggers.CalendarTrigger.ScheduleByDay.DaysInterval -eq '1')) $true
Check 'oppdateringsoppgave: kjører som SYSTEM' $x.Task.Principals.Principal.UserId 'S-1-5-18'
Check 'oppdateringsoppgave: argument' ($x.Task.Actions.Exec.Arguments -like '*-EtterOppdatering') $true
Check 'oppdateringsoppgave: dato i ISO-format' ($x.Task.Triggers.CalendarTrigger.StartBoundary -match '^\d{4}-\d\d-\d\dT12:00:00$') $true
Register-EnforcerTask
$e = [xml]$script:xml[$TaskName]
Check 'håndhever-oppgave: gyldig XML, hvert minutt' $e.Task.Triggers.TimeTrigger.Repetition.Interval 'PT1M'
$cfg.AutoReapply.Enabled = $false
Register-UpdateTask $cfg
Check 'av: oppgaven fjernes' $script:xml.ContainsKey($UpdateTaskName) $false

if ($fail) { [Console]::WriteLine("$fail feil"); exit 1 } else { [Console]::WriteLine('OK') }
