# state-audit — Ausgabe und Gate

Wie der Bericht des vollen Audits aussieht und wann der Audit erledigt ist (`SKILL.md`, Abschnitt
"Ausgabe und Gate").

## Ausgabe

- **Datei:** `docs/audit/state-<YYYY-MM-DDTHHMMZ>.md`, Zeitstempel nach `.agents/rules/docs.md`
  § "Timestamps in File Names".
- **Eigener Branch**, nie direkt auf `main`.
- **Im Kopf der Datei** zwei Zeilen des Metadatenblocks, woertlich so:

  ```text
  - **Commit:** `<sha>`
  - **Timestamp:** <YYYY-MM-DDTHHMMZ>
  ```

  `**Commit:**` traegt den SHA, an dem der Audit genommen wurde; `get-audit-due.ps1` liest genau
  diese Zeile (Bedingung c) und rechnet ohne sie nicht. Ohne den SHA ist jedes `Datei:Zeile` darin
  wertlos — er ist der Bezugspunkt, der die Form ueberhaupt zulaessig macht. `**Timestamp:**` liest
  kein Skript, weder in dieser noch in der alten Form `**Zeitstempel:**`.
- **Direkt unter dem Titel die Selbstauskunft** als eigene Zeile:
  `<!-- audit-worklist: quoted - state audit report, describes commit <sha> -->`. Der Bericht zitiert
  Marker und `TODO`s eines vergangenen Stands, auch im Fliesstext ohne Backticks;
  `get-audit-worklist.ps1` liest die Zeile und zaehlt jeden Treffer darunter als `declared quoted`
  statt als Eintrag. Ohne sie landet jeder Bericht in der Arbeitsliste des naechsten Audits.
- **Direkt hinter dem Metadatenblock steht die Kurzfassung — als erste Sektion, vor allem
  anderen.** Metadatenblock plus Kurzfassung sind zusammen der **Audit-Kopf**, und der ist
  Pflichtlektuere jeder Session (`AGENTS.md` § "Session Start: Read Before Anything Else",
  Schritt 1, und `.agents/rules/audit.md` § "State Audit"). Eine Session liest genau diesen Kopf
  und nichts weiter; steht das Ergebnis hinter der Punkt-fuer-Punkt-Liste, liest es niemand. Die
  Kurzfassung traegt in wenigen Zeilen: Zahl der geprueften Punkte je Ausgang, das Delta in beide
  Richtungen als Zahl, und was nicht real lief.
- **Aufbau:** Titel · Selbstauskunft · Metadatenblock · **Kurzfassung** · Arbeitsliste je Quelle
  (Zahlen aus dem `source-report`) · Ergebnis je Punkt (Aussage, `Datei:Zeile`, Hash, gefahrener
  Test, Marker vorher/nachher) · Traeger-Wiedervorlage · **Eigene Abweichungen** (Tabelle:
  Abweichung, Grund, Ausgang, Messung) · Delta in beide Richtungen · **Restliste**
  (die `remaining`-Eintraege nach Datei und Abschnitt, dazu die unbestimmten `[partial]`) · was
  nicht real lief.

## Gate

**Erledigt ist der Audit, wenn jeder Punkt der Arbeitsliste einen Ausgang hat** — genau einen von
vier:

- **bestaetigt** — Aussage geprueft, Marker stimmt,
- **korrigiert** — Marker im selben Lauf gezogen,
- **an einen Traeger getragen** — der Punkt steht ab jetzt an einem gueltigen Traeger, den man
  durchzaehlen kann (`.agents/rules/carrier.md` § "Carrier Requirement"),
- **nicht verifiziert (Fremd-Repo <name>)**, Marker `[unverified]` — die Aussage ist aus diesem
  Repo heraus weder zu belegen noch zu widerlegen, weil sie ueber ein Fremd-Repo redet; das
  Fremd-Repo wird benannt.

Dazu hat jede eigene Abweichung aus Schritt 3b genau einen ihrer drei Ausgaenge. Ein Punkt ohne
Ausgang bedeutet: der Audit ist nicht fertig. "Sah unveraendert aus" ist kein Ausgang.
