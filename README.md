# Fussball.de Spielplan Kalender

Abonnierbare `.ics`-Kalender fuer fussball.de-Mannschaften. Ein GitHub-Actions-Workflow ruft
taeglich die Spielplaene ab und aktualisiert die Kalenderdateien im Ordner [`ics/`](ics/).

## Team-ID finden

1. Mannschaftsseite auf fussball.de oeffnen (z.B. ueber die Vereinssuche).
2. In der URL nach `team-id/` suchen, z.B.:
   `https://www.fussball.de/mannschaft/.../-/saison/2627/team-id/011MIC1H74000000VTVG0001VTR8C1K7`
3. Der Teil nach `team-id/` ist die Team-ID.

## Neue Mannschaft hinzufuegen

In [`config/teams.json`](config/teams.json) einen Eintrag `"Kalendername": "Team-ID"` ergaenzen.
Der Kalendername wird gleichzeitig zum Dateinamen (`ics/<Kalendername>.ics`) und zum
`X-WR-CALNAME` des Kalenders. Danach den Workflow einmal manuell ausloesen (Tab *Actions* →
*Update Spielplan* → *Run workflow*) oder auf den naechsten geplanten Lauf warten.

## Abo-URLs

```
https://raw.githubusercontent.com/Jens269/fussball-spielplan-kalender/main/ics/Biene-1.ics
https://raw.githubusercontent.com/Jens269/fussball-spielplan-kalender/main/ics/SV%20Holthausen%20Biene%20II.ics
```

(Leerzeichen im Dateinamen muessen in der URL als `%20` kodiert werden.)

**Apple Kalender:** *Ablage → Neu → Kalenderabo* mit obiger URL.
**Google Kalender:** *Weitere Kalender → Per URL* mit obiger URL.
**Outlook (Web):** *Kalender hinzufuegen → Aus dem Internet abonnieren* mit obiger URL.
**Outlook (Windows):** *Kalender → Kalender oeffnen → Aus dem Internet…* mit obiger URL.
**Outlook (Mac):** *Kalender → Ablage → Neu → Kalenderabo…* mit obiger URL.

Apple und Google rufen die Datei automatisch periodisch ab (Apple respektiert dabei u.a.
`REFRESH-INTERVAL:PT12H`); Outlook aktualisiert Internet-Kalender in eigenem, selteneren
Intervall (kein Live-Sync) - das ist eine Outlook-Einschraenkung, keine Eigenschaft der ICS-Datei.
Ein manuelles Neu-Abonnieren ist bei keiner der Apps noetig.

## Wichtiger Hinweis: GitHub deaktiviert inaktive Schedules

GitHub deaktiviert `schedule`-Workflows automatisch, wenn das Repository **60 Tage lang keine
Aktivitaet** hatte (kein Push, kein manueller Workflow-Lauf). Falls die Kalender ploetzlich
nicht mehr aktualisiert werden: im Tab *Actions* pruefen, ob der Workflow als "disabled"
markiert ist, und ihn dort wieder aktivieren (oder einmal manuell per *Run workflow* starten).

## Technischer Hintergrund

- Es gibt keine offizielle fussball.de-API; der Scraper parst die Ajax-Fragmente
  `ajax.team.prev.games` / `ajax.team.next.games`.
- fussball.de verschleiert Ergebnis-Ziffern ueber eine pro Seitenaufruf neu generierte
  Font-Datei (Private-Use-Area-Zeichen, deren tatsaechliche Ziffer nur durch Herunterladen
  und Parsen der zugehoerigen TTF-Datei bestimmbar ist). `scripts/lib/FontObfuscation.ps1`
  loest das durch einen minimalen TrueType-`cmap`/`post`-Parser.
- Aendert fussball.de das HTML-Layout grundlegend, liefert der Scraper vermutlich 0 Spiele.
  In dem Fall: `./scripts/Update-Spielplan.ps1 -RawDump` lokal ausfuehren, das rohe HTML in
  `rawdump/` gegen die aktuelle fussball.de-Seite vergleichen und die Selektoren in
  `scripts/lib/FussballScraper.ps1` nachziehen.
