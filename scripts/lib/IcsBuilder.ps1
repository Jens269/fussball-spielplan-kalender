# Baut RFC-5545-konforme .ics-Dateien: VTIMEZONE fuer Europe/Berlin, CRLF-Zeilenenden,
# UTF-8 ohne BOM, Line-Folding bei 75 Oktetten, stabile UIDs ohne Datum.

# Standard VTIMEZONE-Block fuer Europe/Berlin (CET/CEST), wie ihn die meisten Kalender-Tools
# (u.a. der IANA/tzdata-Export) verwenden. Gueltig fuer alle Jahre ab 1996 (EU-weit einheitliche
# Sommerzeit-Regel: letzter Sonntag im Maerz / Oktober).
function Get-VTimezoneBlock {
  @(
    'BEGIN:VTIMEZONE'
    'TZID:Europe/Berlin'
    'X-LIC-LOCATION:Europe/Berlin'
    'BEGIN:DAYLIGHT'
    'TZOFFSETFROM:+0100'
    'TZOFFSETTO:+0200'
    'TZNAME:CEST'
    'DTSTART:19700329T020000'
    'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU'
    'END:DAYLIGHT'
    'BEGIN:STANDARD'
    'TZOFFSETFROM:+0200'
    'TZOFFSETTO:+0100'
    'TZNAME:CET'
    'DTSTART:19701025T030000'
    'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU'
    'END:STANDARD'
    'END:VTIMEZONE'
  )
}

# Escaped Text-Werte nach RFC 5545 (Backslash, Semikolon, Komma, Zeilenumbrueche).
function ConvertTo-IcsText {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return '' }
  $v = $Value -replace '\\', '\\\\'
  $v = $v -replace ';', '\;'
  $v = $v -replace ',', '\,'
  $v = $v -replace "`r`n|`n|`r", '\n'
  return $v
}

# Faltet eine Content-Line bei 75 Oktetten (UTF-8-Bytes), Fortsetzungszeilen beginnen mit einem
# Leerzeichen (RFC 5545 Section 3.1). Es wird nicht mitten in einem Multi-Byte-Zeichen getrennt.
function Format-IcsFoldedLine {
  param([Parameter(Mandatory)][string]$Line)

  $utf8 = [System.Text.Encoding]::UTF8
  $bytes = $utf8.GetBytes($Line)
  if ($bytes.Length -le 75) { return $Line }

  $chars = $Line.ToCharArray()
  $segments = New-Object System.Collections.Generic.List[string]
  $current = New-Object System.Text.StringBuilder
  $currentByteLen = 0
  $limit = 75

  foreach ($ch in $chars) {
    $chByteLen = $utf8.GetByteCount([string]$ch)
    if ($currentByteLen + $chByteLen -gt $limit) {
      $segments.Add($current.ToString())
      $current = New-Object System.Text.StringBuilder
      $currentByteLen = 0
      $limit = 74 # Fortsetzungszeilen: 1 Byte fuer das fuehrende Leerzeichen abziehen
    }
    [void]$current.Append($ch)
    $currentByteLen += $chByteLen
  }
  if ($current.Length -gt 0) { $segments.Add($current.ToString()) }

  $result = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $segments.Count; $i++) {
    if ($i -eq 0) { [void]$result.Append($segments[$i]) }
    else { [void]$result.Append("`r`n ").Append($segments[$i]) }
  }
  return $result.ToString()
}

# Erzeugt eine stabile UID aus Team-ID + Heim + Gast + Wettbewerb (bewusst ohne Datum),
# damit eine Spielverlegung den bestehenden Termin verschiebt statt ihn zu duplizieren.
function New-StableUid {
  param(
    [Parameter(Mandatory)][string]$TeamId,
    [Parameter(Mandatory)][string]$Heim,
    [Parameter(Mandatory)][string]$Gast,
    [Parameter(Mandatory)][string]$Wettbewerb
  )
  $raw = "$TeamId|$Heim|$Gast|$Wettbewerb"
  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw))
  }
  finally {
    $sha256.Dispose()
  }
  $hex = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
  return "$hex@fussball-spielplan-kalender"
}

# Baut einen VEVENT-Block fuer ein einzelnes Spiel.
# $Game erwartet: Uid, DtStamp, Summary, Description(optional), Url(optional), StartLocal(DateTime),
#                 IsAllDay(bool), DurationMinutes(int), IsCancelled(bool)
# DtStamp wird bewusst NICHT hier auf "jetzt" gesetzt: der Aufrufer entscheidet den Wert (siehe
# Update-Spielplan.ps1), damit unveraendertes Spiel = unveraenderte Zeile = kein spurious Git-Diff.
function New-IcsEvent {
  param([Parameter(Mandatory)]$Game)

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('BEGIN:VEVENT')
  [void]$lines.Add("UID:$($Game.Uid)")
  [void]$lines.Add("DTSTAMP:$($Game.DtStamp)")

  if ($Game.IsAllDay) {
    $dtStart = $Game.StartLocal.ToString('yyyyMMdd')
    $dtEnd = $Game.StartLocal.AddDays(1).ToString('yyyyMMdd')
    [void]$lines.Add("DTSTART;VALUE=DATE:$dtStart")
    [void]$lines.Add("DTEND;VALUE=DATE:$dtEnd")
  }
  else {
    $dtStart = $Game.StartLocal.ToString('yyyyMMdd\THHmmss')
    $dtEnd = $Game.StartLocal.AddMinutes($Game.DurationMinutes).ToString('yyyyMMdd\THHmmss')
    [void]$lines.Add("DTSTART;TZID=Europe/Berlin:$dtStart")
    [void]$lines.Add("DTEND;TZID=Europe/Berlin:$dtEnd")
  }

  [void]$lines.Add("SUMMARY:$(ConvertTo-IcsText $Game.Summary)")
  if ($Game.Description) { [void]$lines.Add("DESCRIPTION:$(ConvertTo-IcsText $Game.Description)") }
  if ($Game.Url) { [void]$lines.Add("URL:$($Game.Url)") }
  if ($Game.IsCancelled) { [void]$lines.Add('STATUS:CANCELLED') }
  else { [void]$lines.Add('STATUS:CONFIRMED') }
  [void]$lines.Add('TRANSP:OPAQUE')
  [void]$lines.Add('END:VEVENT')

  return ($lines | ForEach-Object { Format-IcsFoldedLine $_ })
}

# Baut den kompletten Kalender-Text (CRLF-Zeilenenden) fuer eine Liste von Games.
function New-IcsCalendar {
  param(
    [Parameter(Mandatory)][string]$CalendarName,
    [Parameter(Mandatory)][array]$Games
  )

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('BEGIN:VCALENDAR')
  [void]$lines.Add('VERSION:2.0')
  [void]$lines.Add('PRODID:-//fussball-spielplan-kalender//DE')
  [void]$lines.Add('CALSCALE:GREGORIAN')
  [void]$lines.Add('METHOD:PUBLISH')
  [void]$lines.Add((Format-IcsFoldedLine "X-WR-CALNAME:$(ConvertTo-IcsText $CalendarName)"))
  [void]$lines.Add('X-WR-TIMEZONE:Europe/Berlin')
  [void]$lines.Add('REFRESH-INTERVAL;VALUE=DURATION:PT12H')
  [void]$lines.Add('X-PUBLISHED-TTL:PT12H')
  foreach ($tzLine in (Get-VTimezoneBlock)) { [void]$lines.Add($tzLine) }

  foreach ($game in $Games) {
    foreach ($eventLine in (New-IcsEvent -Game $game)) { [void]$lines.Add($eventLine) }
  }

  [void]$lines.Add('END:VCALENDAR')

  return ($lines -join "`r`n") + "`r`n"
}

# Schreibt Text als UTF-8 ohne BOM (wichtig fuer breite Kalender-App-Kompatibilitaet).
function Write-Utf8NoBom {
  param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

# Entfaltet Content-Lines (hebt das RFC-5545 Line-Folding wieder auf), damit Vergleiche/Extraktion
# nicht an einem Zeilenumbruch mitten im Wert scheitern.
function ConvertFrom-IcsFolding {
  param([Parameter(Mandatory)][string]$IcsText)
  return ($IcsText -replace "`r`n ", '')
}

# Liest eine bestehende .ics-Datei und liefert je UID den kompletten (entfalteten) VEVENT-Body
# mit maskiertem DTSTAMP-Wert - dient dem Alt/Neu-Vergleich, um zu erkennen, ob sich an einem
# Spiel inhaltlich etwas geaendert hat, und dem Wiederverwenden des alten DTSTAMP falls nicht.
function Get-IcsEventFingerprints {
  param([Parameter(Mandatory)][string]$IcsText)

  $unfolded = ConvertFrom-IcsFolding -IcsText $IcsText
  $result = @{}
  foreach ($m in [regex]::Matches($unfolded, 'BEGIN:VEVENT\r?\n(?<body>.*?)END:VEVENT', 'Singleline')) {
    $body = $m.Groups['body'].Value
    $uidMatch = [regex]::Match($body, 'UID:(?<uid>[^\r\n]+)')
    if (-not $uidMatch.Success) { continue }
    $dtStampMatch = [regex]::Match($body, 'DTSTAMP:(?<v>[^\r\n]+)')
    $oldDtStamp = if ($dtStampMatch.Success) { $dtStampMatch.Groups['v'].Value } else { $null }
    $maskedBody = $body -replace 'DTSTAMP:[^\r\n]+', 'DTSTAMP:MASKED'
    $result[$uidMatch.Groups['uid'].Value] = [PSCustomObject]@{ DtStamp = $oldDtStamp; MaskedBody = $maskedBody }
  }
  return $result
}
