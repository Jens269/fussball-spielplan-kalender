# Abruf und Parsing der fussball.de Ajax-Spielplan-Fragmente.
# WICHTIG: Es gibt keine offizielle API. Diese Selektoren sind gegen echtes, live abgerufenes
# Markup verifiziert (Stand: Juli 2026, Layout-Version por/8.88.0.1). Faellt der Parser bei
# einem Layout-Wechsel auf 0 Spiele zurueck, siehe README: -RawDump verwenden und Selektoren
# neu gegen das dann aktuelle Markup pruefen.

$script:FussballUserAgent = 'Mozilla/5.0 (compatible; fussball-spielplan-kalender/1.0; +https://github.com/)'

function Get-TeamGamesHtml {
  param(
    [Parameter(Mandatory)][string]$TeamId,
    [Parameter(Mandatory)][ValidateSet('prev', 'next')][string]$Direction
  )
  $uri = "https://www.fussball.de/ajax.team.$Direction.games/-/team-id/$TeamId"
  $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30 -Headers @{ 'User-Agent' = $script:FussballUserAgent }
  return $response.Content
}

# Zerlegt ein HTML-Fragment in einzelne Spiel-"Bloecke": jeweils vom Beginn einer
# row-headline-Zeile bis zum Beginn der naechsten (oder Textende). Jede row-headline
# enthaelt IMMER Datum (+ Uhrzeit, falls bekannt) und Wettbewerb im Klartext und steht in
# stabiler 1:1-Beziehung zu genau einem Spiel (verifiziert: Anzahl row-headline ==
# Anzahl Spiel-Zeilen in allen Testabrufen).
function Split-GameBlocks {
  param([Parameter(Mandatory)][string]$Html)

  $headlineRegex = [regex]'<tr class="row-headline visible-small">\s*<td colspan="6">(?<headline>.*?)</td>\s*</tr>'
  $matches = $headlineRegex.Matches($Html)

  $blocks = New-Object System.Collections.Generic.List[object]
  for ($i = 0; $i -lt $matches.Count; $i++) {
    $startIdx = $matches[$i].Index
    $endIdx = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $Html.Length }
    $blocks.Add([PSCustomObject]@{
      Headline = [System.Net.WebUtility]::HtmlDecode($matches[$i].Groups['headline'].Value.Trim())
      Body     = $Html.Substring($startIdx, $endIdx - $startIdx)
    })
  }
  return $blocks
}

# Format: "Wochentag, DD.MM.YYYY - HH:MM Uhr | Wettbewerb" oder (falls Anstoss noch nicht
# feststeht) "Wochentag, DD.MM.YYYY | Wettbewerb" ohne Uhrzeit-Teil.
function ConvertFrom-Headline {
  param([Parameter(Mandatory)][string]$Headline)

  $m = [regex]::Match(
    $Headline,
    '^[^,]+,\s*(?<day>\d{2})\.(?<month>\d{2})\.(?<year>\d{4})(?:\s*-\s*(?<hour>\d{2}):(?<minute>\d{2})\s*Uhr)?\s*\|\s*(?<competition>.+)$'
  )
  if (-not $m.Success) { return $null }

  $date = Get-Date -Year ([int]$m.Groups['year'].Value) -Month ([int]$m.Groups['month'].Value) -Day ([int]$m.Groups['day'].Value) `
    -Hour 0 -Minute 0 -Second 0

  $hasTime = $m.Groups['hour'].Success -and $m.Groups['minute'].Success
  $result = [PSCustomObject]@{
    Date        = $date
    HasTime     = $hasTime
    Hour        = if ($hasTime) { [int]$m.Groups['hour'].Value } else { 0 }
    Minute      = if ($hasTime) { [int]$m.Groups['minute'].Value } else { 0 }
    Competition = $m.Groups['competition'].Value.Trim()
  }
  return $result
}

function Get-ObfuscationKeysInHtml {
  param([Parameter(Mandatory)][string]$Html)
  $keys = [regex]::Matches($Html, 'data-obfuscation="(?<key>[^"]+)"') | ForEach-Object { $_.Groups['key'].Value } | Select-Object -Unique
  return $keys
}

# Parst ein einzelnes Spiel-Block-Fragment. Gibt $null zurueck, wenn die erwartete Struktur
# (zwei Vereinsnamen) nicht gefunden wird (z.B. "spielfrei"-Eintraege ohne Gegner) - solche
# Zeilen werden bewusst uebersprungen statt geraten zu parsen.
function ConvertFrom-GameBlock {
  param(
    [Parameter(Mandatory)]$Block,
    [Parameter(Mandatory)][string]$TeamId,
    [Parameter(Mandatory)][hashtable]$DigitMapCache
  )

  $headlineInfo = ConvertFrom-Headline -Headline $Block.Headline
  if (-not $headlineInfo) {
    Write-Warning "Konnte Headline nicht parsen: '$($Block.Headline)'"
    return $null
  }

  $clubNames = [regex]::Matches($Block.Body, '<div class="club-name">\s*(?<name>[^<]+?)\s*</div>') |
    ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups['name'].Value.Trim()) }
  if ($clubNames.Count -lt 2) {
    Write-Warning "Spiel am $($headlineInfo.Date.ToString('yyyy-MM-dd')) ($($headlineInfo.Competition)) uebersprungen: keine zwei Vereinsnamen gefunden (vermutlich spielfrei/Sonderfall)."
    return $null
  }
  $heim = $clubNames[0]
  $gast = $clubNames[1]

  $matchUrlMatch = [regex]::Match($Block.Body, 'href="(?<url>https://www\.fussball\.de/spiel/[^"]+)"')
  $matchUrl = if ($matchUrlMatch.Success) { $matchUrlMatch.Groups['url'].Value } else { $null }

  $scoreCellMatch = [regex]::Match($Block.Body, 'class="column-score">\s*<a[^>]*>(?<inner>.*?)</a>', 'Singleline')
  $isCancelled = $false
  $cancelStatus = $null
  $scoreHome = $null
  $scoreAway = $null

  if ($scoreCellMatch.Success) {
    $inner = $scoreCellMatch.Groups['inner'].Value

    $statusMatch = [regex]::Match($inner, '<span class="info-text">(?<status>[^<]+)</span>')
    if ($statusMatch.Success) {
      $isCancelled = $true
      $cancelStatus = [System.Net.WebUtility]::HtmlDecode($statusMatch.Groups['status'].Value.Trim())
    }
    else {
      $glyphMatches = [regex]::Matches($inner, '<span data-obfuscation="(?<key>[^"]+)" class="score-(?:left|right)">(?<glyphs>[^<]*)')
      if ($glyphMatches.Count -ge 2) {
        $key = $glyphMatches[0].Groups['key'].Value
        if (-not $DigitMapCache.ContainsKey($key)) {
          try {
            $DigitMapCache[$key] = Get-ObfuscationDigitMap -Key $key
          }
          catch {
            Write-Warning "Konnte Obfuskierungs-Font fuer Key '$key' nicht laden/parsen: $($_.Exception.Message)"
            $DigitMapCache[$key] = $null
          }
        }
        $digitMap = $DigitMapCache[$key]
        if ($digitMap) {
          $homeGlyphs = [System.Net.WebUtility]::HtmlDecode($glyphMatches[0].Groups['glyphs'].Value)
          $awayGlyphs = [System.Net.WebUtility]::HtmlDecode($glyphMatches[1].Groups['glyphs'].Value)
          $scoreHome = ConvertFrom-ObfuscatedDigits -Text $homeGlyphs -DigitMap $digitMap
          $scoreAway = ConvertFrom-ObfuscatedDigits -Text $awayGlyphs -DigitMap $digitMap
        }
      }
    }
  }

  $startLocal = $headlineInfo.Date.AddHours($headlineInfo.Hour).AddMinutes($headlineInfo.Minute)

  return [PSCustomObject]@{
    TeamId      = $TeamId
    Date        = $headlineInfo.Date
    StartLocal  = $startLocal
    IsAllDay    = -not $headlineInfo.HasTime
    Competition = $headlineInfo.Competition
    Heim        = $heim
    Gast        = $gast
    MatchUrl    = $matchUrl
    IsCancelled = $isCancelled
    CancelStatus = $cancelStatus
    ScoreHome   = $scoreHome
    ScoreAway   = $scoreAway
    HasResult   = ($null -ne $scoreHome -and $null -ne $scoreAway)
  }
}

function ConvertFrom-TeamGamesHtml {
  param(
    [Parameter(Mandatory)][string]$Html,
    [Parameter(Mandatory)][string]$TeamId,
    [Parameter(Mandatory)][hashtable]$DigitMapCache
  )

  $blocks = Split-GameBlocks -Html $Html
  $games = New-Object System.Collections.Generic.List[object]
  foreach ($block in $blocks) {
    $game = ConvertFrom-GameBlock -Block $block -TeamId $TeamId -DigitMapCache $DigitMapCache
    if ($game) { $games.Add($game) }
  }
  return $games
}
