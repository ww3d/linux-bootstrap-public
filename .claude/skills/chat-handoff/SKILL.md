---
name: chat-handoff
description: 'Uebergibt eine laufende Session sauber an einen neuen Chat — bei defekter Session, Neustart oder erschoepftem Budget eines Claude-Accounts. Persist-first: alles Offene und noch nicht Festgehaltene geht nach Freigabe zuerst an einen gueltigen Traeger (offenes Issue, roadmap.md/backlog.md-Zeile, [geplant]-Marker in der Architektur-Doku) — nie in einen Kommentar —, dann erst in die Datei. Geht die Session vor der Ausgabe rueckwaerts durch und listet alles "offen, aber nirgends persistiert" zur Bestaetigung. Schreibt eine selbst-startende Handoff-Datei (`YYYY-MM-DDTHH-MM-SS-handoff.md`) mit Chatname, Resume-Anweisung, Stand, nicht persistierten Entscheidungen, Konstellation und der Liste der Dateien, die im neuen Chat anzuhaengen sind. Triggert bei "handoff", "chat wechseln", "session uebergeben", "neuer chat", "budget erschoepft", "weiter im neuen chat". Baut keinen Auftrags-Prompt und keinen Review-Prompt — dafuer ist ccweb-prompt zustaendig. Nutzt das GitHub MCP oder `gh`.'
metadata:
  version: "2.0.0"
  source: ww3d/playbook
---

# Session-Handoff in einen neuen Chat

Macht eine laufende Session in einem frischen Chat verlustfrei fortsetzbar — defekte Session,
Neustart, oder das Budget des benutzten Claude-Accounts ist aufgebraucht.

## Kernprinzip

- **Persist-first.** GitHub ist der Truth-Store. Was an ein Issue oder einen PR gehoert, wird dort
  festgehalten, **bevor** die Handoff-Datei entsteht. Die Datei traegt nur, was das Repo nicht
  hergibt — so bleibt sie klein und veraltet nicht.
- **Ein offener Punkt geht an einen Traeger, nicht in einen Kommentar.** Gueltig sind nur die drei
  Orte aus `AGENTS.md` § "Carrier Requirement": offenes Issue · Zeile in `roadmap.md`/`backlog.md` ·
  `[geplant]`/`[teilweise]`-Aussage in einer Architektur-/Baseline-Doku. Issue-Kommentar und
  PR-Body sind ausdruecklich **keine** Traeger — sie sind Chronik, die niemand als Arbeitsvorrat
  zurueckliest. Kommentare bleiben zulaessig fuer Kontext, der kein offener Punkt ist
  (Zwischenstand, Begruendung, Verweis).
- **Verifikation statt Kopie.** Die neue Session verifiziert den Stand selbst an den genannten
  Issues/PRs. Die Datei paraphrasiert nichts, was dort ohnehin steht.
- **Selbst-startend.** Datei anhaengen + "weiter" muss genuegen; die Resume-Anweisung in der Datei
  liefert den naechsten Schritt.

## Ablauf

1. **Persistieren.** Alles Offene und noch nicht Festgehaltene an einen gueltigen Traeger: ein
   offenes Issue (neu anlegen oder ein bestehendes erweitern), eine Zeile in
   `roadmap.md`/`backlog.md`, oder eine `[geplant]`/`[teilweise]`-Aussage in der Architektur-Doku.
   Kontext ohne offenen Punkt darf als Kommentar an das jeweilige Issue / den PR. **Erst nach
   Freigabe posten oder committen** — nie ungefragt. Was keinen Issue-/PR-Bezug hat, bleibt fuer
   Schritt 3.
2. **Vollstaendigkeits-Check.** Die Session rueckwaerts durchgehen und alles auflisten, was "offen,
   aber nirgends persistiert" ist — getroffene Entscheidungen ohne Log-Eintrag, ausgeraeumte
   Fehlannahmen, vertagte Punkte, laufende Auftraege. Die Liste vorlegen und bestaetigen lassen,
   dass nichts fehlt, bevor die Datei geschrieben wird.
3. **Handoff-Datei schreiben** (`create_file` + `present_files`), Struktur siehe unten.
4. **Anhaenge benennen.** Die Nicht-Repo-Dateien aus dem Chat-Output auflisten, die die neue Session
   braucht (typisch: das laufende Decision-Log, ein gebauter Prompt) — mit der Anweisung, sie im
   neuen Chat **als Datei anzuhaengen**, nicht den Inhalt hineinzukopieren.

## Handoff-Datei

- **Dateiname:** `YYYY-MM-DDTHH-MM-SS-handoff.md` — sekundengenauer ISO-Zeitstempel, Doppelpunkte
  durch Bindestriche ersetzt, `.md`-Endung bleibt dran (Typ-Erkennung beim Download).
- **Uebergabe:** herunterladen und im neuen Chat als Datei anhaengen. Nicht ueber den gerenderten
  Chat kopieren — das zerstoert das Markdown.
- **Feste Reihenfolge** der Abschnitte:

```md
<!-- transport: verbatim, do not re-render -->
# projekt(modul): thema - issue #N - pr #M

**Resume:** Lies diese Datei vollstaendig, verifiziere den Stand an den genannten Issues/PRs,
dann weiter mit: <naechster Schritt>.

## Stand
- Erledigt: <was fertig ist, mit Issue-/PR-Referenz>
- Offen: <was aussteht, mit Issue-/PR-Referenz>

## Nicht persistierte Entscheidungen und Kontext
<was in keinem Issue, PR oder Log steht>

## Konstellation und Sonderwissen
<Accounts, Rollen, ausgeraeumte Fehlannahmen, Umgebungs-Eigenheiten>

## Benoetigte Anhaenge
<Dateien, die im neuen Chat mit anzuhaengen sind>
```

- Die H1-Zeile ist der **Chatname** im Conventional-Format `projekt(modul): thema - issue #N -
  pr #M`; fehlt ein Issue oder PR, entfaellt der Teil.
- Der Marker `<!-- transport: verbatim, do not re-render -->` steht immer als erste Zeile.

## Strikte Regeln

- Nichts nach GitHub posten ohne Freigabe — auch nicht "nur schnell den Stand".
- **Kein offener Punkt in einen Kommentar.** Ein Issue-Kommentar oder Body-Update meldet den Punkt,
  traegt ihn aber nicht — er braucht einen der drei Traeger aus dem Kernprinzip.
- Die Datei dupliziert keinen Issue-/PR-Inhalt; wo etwas persistiert wurde, steht nur die Referenz.
- Kein Handoff ohne den Vollstaendigkeits-Check aus Schritt 2.
- Der Handoff baut keinen Auftrags-Prompt und keinen Review-Prompt — das ist `ccweb-prompt`
  (anderer Zweck, eigener Trigger-Raum).

## Repo-Konventionen

- `git` + `gh` sind Default fuer alle GitHub-Operationen (`AGENTS.md` § "Forge Tooling"); das
  GitHub MCP nur als Fallback oder fuer MCP-only-Tools.
- Sprache der geposteten Kommentare/Bodies nach `AGENTS.md` § "Language" (Deutsch fuer Inhalt).
