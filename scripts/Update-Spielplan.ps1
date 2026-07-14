<#
.SYNOPSIS
  Laedt die Spielplaene mehrerer fussball.de-Mannschaften und schreibt je Mannschaft eine
  RFC-5545-konforme .ics-Datei.

.PARAMETER TeamsConfigPath
  Pfad zur JSON-Datei mit Kalendername -> Team-ID Zuordnung.

.PARAMETER OutputPath
  Zielverzeichnis fuer die erzeugten .ics-Dateien (eine Datei pro Mannschaft, Dateiname = Kalendername).

.PARAMETER RawDump
  Wenn gesetzt, wird das roh abgerufene HTML zusaetzlich unter RawDumpPath abgelegt (Fehlersuche).

.PARAMETER RawDumpPath
  Zielverzeichnis fuer die Rohdaten, wenn -RawDump gesetzt ist.

.PARAMETER DurationMinutes
  Standard-Spieldauer in Minuten fuer Termine mit bekannter Anstosszeit.
#>
[CmdletBinding()]
param(
  [string]$TeamsConfigPath = (Join-Path $PSScriptRoot '../config/teams.json'),
  [string]$OutputPath = (Join-Path $PSScriptRoot '../ics'),
  [switch]$RawDump,
  [string]$RawDumpPath = (Join-Path $PSScriptRoot '../rawdump'),
  [int]$DurationMinutes = 105
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib/FontObfuscation.ps1')
. (Join-Path $PSScriptRoot 'lib/IcsBuilder.ps1')
. (Join-Path $PSScriptRoot 'lib/FussballScraper.ps1')

if (-not (Test-Path $TeamsConfigPath)) {
  throw "Teams-Konfiguration nicht gefunden: $TeamsConfigPath"
}
$teams = Get-Content $TeamsConfigPath -Raw | ConvertFrom-Json -AsHashtable

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
if ($RawDump -and -not (Test-Path $RawDumpPath)) { New-Item -ItemType Directory -Path $RawDumpPath -Force | Out-Null }

# Wird ueber alle Teams hinweg wiederverwendet - jede Obfuskierungs-Font muss nur einmal
# pro Key geladen werden, auch wenn derselbe Key (selten) mehrfach vorkaeme.
$digitMapCache = @{}

function ConvertTo-GameKey {
  param($Game)
  if ($Game.MatchUrl) { return $Game.MatchUrl }
  return "$($Game.Heim)|$($Game.Gast)|$($Game.StartLocal.ToString('o'))|$($Game.Competition)"
}

function New-CalendarGameEntry {
  param($Game, [int]$DurationMinutes)

  $uid = New-StableUid -TeamId $Game.TeamId -Heim $Game.Heim -Gast $Game.Gast -Wettbewerb $Game.Competition

  $summary = "$($Game.Heim) - $($Game.Gast)"
  if ($Game.HasResult) { $summary = "$summary ($($Game.ScoreHome):$($Game.ScoreAway))" }
  if ($Game.IsCancelled) {
    $prefix = if ($Game.CancelStatus) { $Game.CancelStatus } else { 'Abgesagt' }
    $summary = "[$prefix] $summary"
  }

  $descriptionParts = New-Object System.Collections.Generic.List[string]
  [void]$descriptionParts.Add("Wettbewerb: $($Game.Competition)")
  if ($Game.IsCancelled -and $Game.CancelStatus) { [void]$descriptionParts.Add("Status: $($Game.CancelStatus)") }
  if ($Game.MatchUrl) { [void]$descriptionParts.Add($Game.MatchUrl) }

  return [PSCustomObject]@{
    Uid              = $uid
    Summary          = $summary
    Description      = ($descriptionParts -join "`n")
    Url              = $Game.MatchUrl
    StartLocal       = $Game.StartLocal
    IsAllDay         = $Game.IsAllDay
    DurationMinutes  = $DurationMinutes
    IsCancelled      = $Game.IsCancelled
  }
}

$anyTeamProducedGames = $false
$results = @()

foreach ($teamName in $teams.Keys) {
  $teamId = $teams[$teamName]
  Write-Host "== $teamName (team-id: $teamId) =="

  try {
    $prevHtml = Get-TeamGamesHtml -TeamId $teamId -Direction 'prev'
    $nextHtml = Get-TeamGamesHtml -TeamId $teamId -Direction 'next'
  }
  catch {
    Write-Error "Abruf fuer '$teamName' fehlgeschlagen: $($_.Exception.Message)"
    $results += [PSCustomObject]@{ Team = $teamName; GameCount = 0; Written = $false }
    continue
  }

  if ($RawDump) {
    Set-Content -Path (Join-Path $RawDumpPath "$teamName.prev.raw.html") -Value $prevHtml -NoNewline
    Set-Content -Path (Join-Path $RawDumpPath "$teamName.next.raw.html") -Value $nextHtml -NoNewline
  }

  $prevGames = ConvertFrom-TeamGamesHtml -Html $prevHtml -TeamId $teamId -DigitMapCache $digitMapCache
  $nextGames = ConvertFrom-TeamGamesHtml -Html $nextHtml -TeamId $teamId -DigitMapCache $digitMapCache

  $seen = @{}
  $allGames = New-Object System.Collections.Generic.List[object]
  foreach ($g in @($prevGames) + @($nextGames)) {
    $key = ConvertTo-GameKey -Game $g
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      $allGames.Add($g)
    }
  }

  $sortedGames = $allGames | Sort-Object StartLocal

  Write-Host "   $($sortedGames.Count) Spiele gefunden."

  if ($sortedGames.Count -eq 0) {
    Write-Warning "Keine Spiele fuer '$teamName' gefunden - bestehende .ics-Datei wird NICHT ueberschrieben."
    $results += [PSCustomObject]@{ Team = $teamName; GameCount = 0; Written = $false }
    continue
  }

  $anyTeamProducedGames = $true

  $calendarGames = $sortedGames | ForEach-Object { New-CalendarGameEntry -Game $_ -DurationMinutes $DurationMinutes }
  $icsContent = New-IcsCalendar -CalendarName $teamName -Games $calendarGames

  $outFile = Join-Path $OutputPath "$teamName.ics"
  Write-Utf8NoBom -Path $outFile -Content $icsContent
  Write-Host "   -> $outFile geschrieben."

  $results += [PSCustomObject]@{ Team = $teamName; GameCount = $sortedGames.Count; Written = $true }
}

Write-Host ''
Write-Host '== Zusammenfassung =='
$results | Format-Table -AutoSize

if (-not $anyTeamProducedGames) {
  throw 'Fuer KEINE Mannschaft konnten Spiele geladen werden. Vermutlich hat sich das fussball.de-Markup geaendert oder der Abruf schlaegt fehl. Es wurde nichts geschrieben.'
}
