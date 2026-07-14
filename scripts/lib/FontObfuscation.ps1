# fussball.de verschleiert Ergebnis-Ziffern in der Spielplan-Tabelle: statt Klartext
# ("2:1") steht im DOM ein Zeichen aus dem Private-Use-Bereich (z.B. U+E67E) mit einem
# Attribut data-obfuscation="<key>". Welche Ziffer das Zeichen tatsaechlich darstellt,
# ist nur ueber eine pro Key generierte TTF-Schriftart herauszufinden:
#   https://www.fussball.de/export.fontface/-/format/ttf/id/<key>/type/font
# Die Font enthaelt eine cmap (Format 4) codepoint -> glyphId und eine post-Tabelle
# (Format 2.0), die glyphId -> Standard-Mac-Glyphnamen ("zero".."nine","hyphen") aufloest.
# Der Key (und damit die Zuordnung) wechselt bei jedem Seitenaufruf, es muss also pro
# Abruf neu aufgeloest werden. Reverse-engineered gegen echte Font-Dateien von fussball.de.

# Standard-Macintosh-Glyphnamen-Tabelle (TrueType 'post' Format 1.0/2.0), Index 0-257.
# Wir brauchen nur einen Teilbereich (Ziffern + Bindestrich), definieren aber den relevanten
# Ausschnitt vollstaendig genug ab, um robust gegen andere Indizes zu sein.
$script:StandardMacGlyphNames = @(
  '.notdef','.null','nonmarkingreturn','space','exclam','quotedbl','numbersign','dollar',
  'percent','ampersand','quotesingle','parenleft','parenright','asterisk','plus','comma',
  'hyphen','period','slash','zero','one','two','three','four','five','six','seven','eight',
  'nine','colon','semicolon','less','equal','greater','question','at','A','B','C','D','E',
  'F','G','H','I','J','K','L','M','N','O','P','Q','R','S','T','U','V','W','X','Y','Z',
  'bracketleft','backslash','bracketright','asciicircum','underscore','grave','a','b','c',
  'd','e','f','g','h','i','j','k','l','m','n','o','p','q','r','s','t','u','v','w','x','y',
  'z','braceleft','bar','braceright','asciitilde'
)

function Get-Uint16BE {
  param([byte[]]$Bytes, [int]$Offset)
  return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]
}

function Get-Int16BE {
  param([byte[]]$Bytes, [int]$Offset)
  $v = Get-Uint16BE -Bytes $Bytes -Offset $Offset
  if ($v -ge 0x8000) { return $v - 0x10000 }
  return $v
}

function Get-Uint32BE {
  param([byte[]]$Bytes, [int]$Offset)
  return ([uint32]$Bytes[$Offset] -shl 24) -bor ([uint32]$Bytes[$Offset + 1] -shl 16) -bor
         ([uint32]$Bytes[$Offset + 2] -shl 8) -bor [uint32]$Bytes[$Offset + 3]
}

function Get-SfntTableDirectory {
  param([byte[]]$Bytes)
  $numTables = Get-Uint16BE -Bytes $Bytes -Offset 4
  $tables = @{}
  for ($i = 0; $i -lt $numTables; $i++) {
    $recOffset = 12 + ($i * 16)
    $tag = [System.Text.Encoding]::ASCII.GetString($Bytes, $recOffset, 4)
    $offset = Get-Uint32BE -Bytes $Bytes -Offset ($recOffset + 8)
    $length = Get-Uint32BE -Bytes $Bytes -Offset ($recOffset + 12)
    $tables[$tag] = [PSCustomObject]@{ Offset = [int]$offset; Length = [int]$length }
  }
  return $tables
}

# Parst eine cmap-Subtabelle im Format 4 (Segment mapping to delta values), das einzige
# Format, das fussball.de fuer diese Fonts verwendet (verifiziert gegen echte Dateien).
function Get-Cmap4CodepointToGlyphId {
  param([byte[]]$Bytes, [int]$SubtableOffset)

  $format = Get-Uint16BE -Bytes $Bytes -Offset $SubtableOffset
  if ($format -ne 4) {
    throw "Unerwartetes cmap-Format $format (erwartet: 4). fussball.de hat das Font-Format vermutlich geaendert."
  }

  $segCountX2 = Get-Uint16BE -Bytes $Bytes -Offset ($SubtableOffset + 6)
  $segCount = $segCountX2 / 2

  $endCodeOffset = $SubtableOffset + 14
  $startCodeOffset = $endCodeOffset + $segCountX2 + 2 # +2 fuer reservedPad
  $idDeltaOffset = $startCodeOffset + $segCountX2
  $idRangeOffsetOffset = $idDeltaOffset + $segCountX2

  $map = @{}

  for ($seg = 0; $seg -lt $segCount; $seg++) {
    $endCode = Get-Uint16BE -Bytes $Bytes -Offset ($endCodeOffset + ($seg * 2))
    $startCode = Get-Uint16BE -Bytes $Bytes -Offset ($startCodeOffset + ($seg * 2))
    if ($startCode -eq 0xFFFF -and $endCode -eq 0xFFFF) { continue }

    $idDelta = Get-Int16BE -Bytes $Bytes -Offset ($idDeltaOffset + ($seg * 2))
    $idRangeOffsetAddr = $idRangeOffsetOffset + ($seg * 2)
    $idRangeOffset = Get-Uint16BE -Bytes $Bytes -Offset $idRangeOffsetAddr

    for ($c = $startCode; $c -le $endCode; $c++) {
      if ($c -eq 0xFFFF) { continue }
      if ($idRangeOffset -eq 0) {
        $glyphId = ($c + $idDelta) -band 0xFFFF
      }
      else {
        $glyphIndexAddr = $idRangeOffsetAddr + $idRangeOffset + (2 * ($c - $startCode))
        $rawGlyphId = Get-Uint16BE -Bytes $Bytes -Offset $glyphIndexAddr
        if ($rawGlyphId -eq 0) { $glyphId = 0 } else { $glyphId = ($rawGlyphId + $idDelta) -band 0xFFFF }
      }
      if ($glyphId -ne 0) { $map[$c] = $glyphId }
    }
  }

  return $map
}

# Parst die 'post'-Tabelle (Format 2.0) und liefert glyphId -> Glyphname.
function Get-PostGlyphNames {
  param([byte[]]$Bytes, [int]$PostOffset, [int]$PostLength)

  $version = Get-Uint32BE -Bytes $Bytes -Offset $PostOffset
  if ($version -ne 0x00020000) {
    throw "Unerwartetes post-Tabellenformat 0x$($version.ToString('X8')) (erwartet: 2.0). fussball.de hat das Font-Format vermutlich geaendert."
  }

  $numGlyphs = Get-Uint16BE -Bytes $Bytes -Offset ($PostOffset + 32)
  $indexArrayOffset = $PostOffset + 34

  $glyphNameIndex = New-Object 'int[]' $numGlyphs
  for ($i = 0; $i -lt $numGlyphs; $i++) {
    $glyphNameIndex[$i] = Get-Uint16BE -Bytes $Bytes -Offset ($indexArrayOffset + ($i * 2))
  }

  # Pascal-Strings fuer benutzerdefinierte Namen (Index >= 258) liegen direkt danach.
  $pascalStringsOffset = $indexArrayOffset + ($numGlyphs * 2)
  $customNames = New-Object System.Collections.Generic.List[string]
  $pos = $pascalStringsOffset
  $postEnd = $PostOffset + $PostLength
  while ($pos -lt $postEnd) {
    $len = $Bytes[$pos]
    $pos++
    if ($pos + $len -gt $postEnd) { break }
    $customNames.Add([System.Text.Encoding]::ASCII.GetString($Bytes, $pos, $len))
    $pos += $len
  }

  $names = @{}
  for ($glyphId = 0; $glyphId -lt $numGlyphs; $glyphId++) {
    $idx = $glyphNameIndex[$glyphId]
    if ($idx -lt 258) {
      if ($idx -lt $script:StandardMacGlyphNames.Count) {
        $names[$glyphId] = $script:StandardMacGlyphNames[$idx]
      }
    }
    else {
      $customIdx = $idx - 258
      if ($customIdx -lt $customNames.Count) {
        $names[$glyphId] = $customNames[$customIdx]
      }
    }
  }

  return $names
}

function ConvertTo-DigitChar {
  param([string]$GlyphName)
  switch ($GlyphName) {
    'zero' { return '0' }
    'one' { return '1' }
    'two' { return '2' }
    'three' { return '3' }
    'four' { return '4' }
    'five' { return '5' }
    'six' { return '6' }
    'seven' { return '7' }
    'eight' { return '8' }
    'nine' { return '9' }
    'hyphen' { return '-' }
    default { return $null }
  }
}

# Laedt die Obfuskierungs-Font fuer einen Key und liefert eine Map [int codepoint] -> [char].
function Get-ObfuscationDigitMap {
  param([Parameter(Mandatory)][string]$Key)

  $uri = "https://www.fussball.de/export.fontface/-/format/ttf/id/$Key/type/font"
  $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 30
  $bytes = $response.Content
  if ($bytes -isnot [byte[]]) {
    # Invoke-WebRequest kann je nach Plattform string statt byte[] liefern; defensiv absichern.
    throw "Unerwarteter Content-Typ beim Laden der Obfuskierungs-Font fuer Key '$Key'."
  }

  $tables = Get-SfntTableDirectory -Bytes $bytes
  if (-not $tables.ContainsKey('cmap') -or -not $tables.ContainsKey('post')) {
    throw "Font fuer Key '$Key' enthaelt keine cmap/post-Tabelle."
  }

  $cmapOffset = $tables['cmap'].Offset
  $cmapNumTables = Get-Uint16BE -Bytes $bytes -Offset ($cmapOffset + 2)
  $subtableOffset = -1
  for ($i = 0; $i -lt $cmapNumTables; $i++) {
    $recOffset = $cmapOffset + 4 + ($i * 8)
    $platformId = Get-Uint16BE -Bytes $bytes -Offset $recOffset
    $encodingId = Get-Uint16BE -Bytes $bytes -Offset ($recOffset + 2)
    $offset = Get-Uint32BE -Bytes $bytes -Offset ($recOffset + 4)
    if ($platformId -eq 3 -and $encodingId -eq 1) {
      $subtableOffset = $cmapOffset + $offset
      break
    }
  }
  if ($subtableOffset -lt 0) {
    throw "Keine Windows-Unicode-BMP cmap-Subtabelle (Plattform 3, Encoding 1) in Font fuer Key '$Key' gefunden."
  }

  $codepointToGlyphId = Get-Cmap4CodepointToGlyphId -Bytes $bytes -SubtableOffset $subtableOffset
  $glyphIdToName = Get-PostGlyphNames -Bytes $bytes -PostOffset $tables['post'].Offset -PostLength $tables['post'].Length

  $digitMap = @{}
  foreach ($codepoint in $codepointToGlyphId.Keys) {
    $glyphId = $codepointToGlyphId[$codepoint]
    if ($glyphIdToName.ContainsKey($glyphId)) {
      $digit = ConvertTo-DigitChar -GlyphName $glyphIdToName[$glyphId]
      if ($null -ne $digit) { $digitMap[$codepoint] = $digit }
    }
  }

  return $digitMap
}

# Dekodiert einen bereits HTML-entities-dekodierten String aus PUA-Zeichen in Klartext-Ziffern.
# Gibt $null zurueck, wenn nicht alle Zeichen aufgeloest werden konnten oder das Ergebnis nur
# aus Platzhaltern ("-") besteht (= Spiel noch nicht gespielt / kein Ergebnis vorhanden).
function ConvertFrom-ObfuscatedDigits {
  param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][hashtable]$DigitMap)

  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $Text.ToCharArray()) {
    $cp = [int][char]$ch
    if (-not $DigitMap.ContainsKey($cp)) { return $null }
    [void]$sb.Append($DigitMap[$cp])
  }
  $decoded = $sb.ToString()
  if ($decoded -match '^-+$') { return $null }
  return $decoded
}
