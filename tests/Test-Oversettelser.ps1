<#
    Sjekker at alle tekster i Setup-Foreldrekontroll.ps1 har oversettelse i lang\*.psd1,
    at plassholderne {0}, {1} ... er de samme, og at ingen tekst bygges med $variabler
    (de kan ikke oversettes). Kjør:  pwsh -File tests/Test-Oversettelser.ps1 [-ListKeys]
#>
param([switch]$ListKeys)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'Setup-Foreldrekontroll.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Parse errors: $($errors[0].Message)" }

$textCmds = @('T', 'Write-Ok', 'Write-Warn', 'Write-Err', 'Write-Info', 'Write-Title', 'Read-YesNo', 'Read-Text', 'Read-Time', 'Read-Limit', 'Read-Numbers', 'Edit-Days')
$keys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$problems = @()
$where = @{}
function Add-Key([string]$k, $node) {
    if ($node) {
        # Ikke medlemsnavn ($x.Navn), kommandonavn eller interne navn (brannmurregler).
        $par = $node.Parent
        if ($par -is [System.Management.Automation.Language.MemberExpressionAst]) { return }
        if ($par -is [System.Management.Automation.Language.CommandAst] -and $par.CommandElements[0] -eq $node) { return }
        if ($k -like 'FK-*') { return }
    }
    $k = $k.Trim()
    if ($k -match '\p{L}') { [void]$keys.Add($k); if ($node -and -not $where.ContainsKey($k)) { $where[$k] = $node.Extent.StartLineNumber } }
}

foreach ($cmd in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $cmd.GetCommandName()
    if ($textCmds -notcontains $name) { continue }
    $els = @($cmd.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
    if ($name -eq 'Edit-Days') { $arg = $els[2] } else { $arg = $els[0] }
    if ($null -eq $arg) { continue }
    if ($arg -is [System.Management.Automation.Language.StringConstantExpressionAst]) { Add-Key $arg.Value $arg }
    elseif ($arg -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        $problems += "Linje $($arg.Extent.StartLineNumber): tekst med `$variabel kan ikke oversettes: $($arg.Extent.Text)"
    }
}
# throw med ren tekst (ikke via T) blir aldri oversatt.
foreach ($t in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.ThrowStatementAst] }, $true)) {
    $e = $t.Pipeline.Extent.Text
    if ($e -match '^\s*["'']' -and $e -match '\p{L}{3,}') { $problems += "Linje $($t.Extent.StartLineNumber): throw uten T(): $e" }
}
# Tekster som sendes til T via variabler eller tabeller.
foreach ($a in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)) {
    $left = $a.Left.Extent.Text
    if ($left -eq '$q') {
        foreach ($c in $a.Right.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) { Add-Key $c.Value $c }
    }
}
foreach ($h in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $true)) {
    foreach ($pair in $h.KeyValuePairs) {
        $k = $pair.Item1.Extent.Text
        if ($k -in @('N', 'Note') -or ($k -match '^(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)$' -and $h.Parent.Extent.Text -match 'ordered')) {
            foreach ($c in $pair.Item2.FindAll({ $args[0] -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)) { Add-Key $c.Value $c }
        }
    }
}

# PowerShell-datafiler skiller ikke mellom store og små bokstaver i nøkler.
$dupes = @($keys | Group-Object { $_.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
foreach ($d in $dupes) { $problems += "Nøkler som bare skiller seg i store/små bokstaver: $($d.Group -join ' / ')" }
if ($ListKeys) { $keys | Sort-Object | ForEach-Object { '{0,5}  {1}' -f $where[$_], $_ }; return }

$failed = $false
foreach ($p in $problems) { Write-Host "FEIL: $p" -ForegroundColor Red; $failed = $true }
foreach ($f in Get-ChildItem (Join-Path $root 'lang') -Filter '*.psd1') {
    $data = Import-PowerShellDataFile -LiteralPath $f.FullName
    $tr = @{}; foreach ($k in $data.Keys) { $tr[[string]$k] = [string]$data[$k] }
    $missing = @($keys | Where-Object { -not $tr.ContainsKey($_) })
    $unused = @($tr.Keys | Where-Object { -not $keys.Contains($_) })
    foreach ($m in $missing) { Write-Host "MANGLER ($($f.Name)): $m" -ForegroundColor Red; $failed = $true }
    foreach ($u in $unused) { Write-Host "UBRUKT ($($f.Name)): $u" -ForegroundColor Yellow }
    foreach ($k in $keys) {
        if (-not $tr.ContainsKey($k)) { continue }
        $a = @([regex]::Matches($k, '\{\d+(:[^}]*)?\}') | ForEach-Object { $_.Value } | Sort-Object)
        $b = @([regex]::Matches($tr[$k], '\{\d+(:[^}]*)?\}') | ForEach-Object { $_.Value } | Sort-Object)
        if (($a -join ',') -ne ($b -join ',')) { Write-Host "PLASSHOLDERE ($($f.Name)): '$k' -> '$($tr[$k])'" -ForegroundColor Red; $failed = $true }
        if ($tr[$k] -match '[\u2012-\u2015]') { Write-Host "LANG STREK ($($f.Name)): $($tr[$k])" -ForegroundColor Red; $failed = $true }
        try { [void]($tr[$k] -f 1, 2, 3, 4, 5) } catch { Write-Host "FORMAT ($($f.Name)): $($tr[$k])" -ForegroundColor Red; $failed = $true }
    }
    Write-Host "$($f.Name): $($keys.Count) tekster, $($missing.Count) mangler"
}
if ($failed) { exit 1 } else { Write-Host 'OK' -ForegroundColor Green }
