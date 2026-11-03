---
name: state-audit
description: 'Faehrt vor jedem neuen Design den Schnell-Check und, wenn faellig, den vollen State Audit nach `.agents/rules/audit.md` § "State Audit" — das Gate aus `ccweb-prompt` Schritt 0. Setzt Checkout, Build, Test und `git grep` voraus. Triggert bei "state audit", "ist-stand pruefen", "audit vor der scheibe", "soll-ist abgleich".'
metadata:
  version: "5.2.1"
  source: ww3d/playbook
  checksum: "sha256:8f49b954076aae251fbbf111235f631ea7a1a49b0e6f0e5f2826ff38f6810f84"
  # Written by ./scripts/check-skill-budget.ps1 -UpdateMeasurement, which needs an
  # ANTHROPIC_API_KEY; every later run recomputes the value and reports drift. Empty means no
  # real measurement has run yet - an invented number would be the false green this gate is against.
  measurement:
    tokens:
    model:
    measured:
    source: "not measured - no ANTHROPIC_API_KEY in the build environment of ww3d/playbook#210"
---

# State Audit

Prueft das Zielbild der Architektur-/Baseline-Docs gegen den tatsaechlichen Stand des Repos und
schreibt das Ergebnis fest. `.agents/rules/audit.md` § "State Audit" verlangt vor jedem neuen
Design den Schnell-Check und den vollen Audit, wenn er faellig ist; das Gate dafuer sitzt in
`ccweb-prompt` Schritt 0.

**Dieser Skill ist ein `ccweb`-Skill.** Er darf Werkzeuge voraussetzen — Checkout, Build, Test,
`git grep`. Eine Session ohne Arbeitsverzeichnis kann ihn nicht fahren: sie kann Tests nicht real
laufen lassen, und ein Audit, der Testlaeufe behauptet statt sie zu fahren, ist genau die
Beschoenigung, gegen die er steht.

## Wann

Vor jedem neuen Design, angestossen ueber diesen Skill: zuerst der Schnell-Check (Schritt 0), der
volle Audit nur, wenn er faellig ist. Der volle Audit baut sich die Arbeitsliste selbst (Schritt 1),
prueft jeden Punkt in fester Reihenfolge (Schritt 2), meldet das Delta in beide Richtungen
(Schritt 4) und schreibt das Ergebnis als `docs/audit/state-[stempel].md` auf einen eigenen Branch,
mit dem Commit-SHA im Kopf (Ausgabe).

## Kernprinzip

- **Fertige Arbeitsliste statt leerem Blatt.** Der Skill sammelt die zu pruefenden Punkte
  maschinell (Schritt 1), bevor irgendetwas beurteilt wird. Wer die Liste im Kopf zusammenstellt,
  laesst genau die Quelle aus, die niemand im Kopf hat.
- **Real fahren, nicht ableiten.** Jede Aussage wird am Code, am Build und am wirklich gelaufenen
  Test geprueft. Was nicht lief (fehlendes Docker, CLI, CI, Hardware), steht als "nicht verifiziert"
  im Bericht — nie beschoenigt.
- **`Datei:Zeile` ist hier die richtige Belegform.** Der Audit nennt den Commit, an dem er genommen
  wurde, und fixiert damit den Bezugspunkt so, wie es sonst nur ein SHA-Permalink tut
  (`.agents/rules/evidence.md` § "Evidence Requirement").
- **Das Ergebnis ist eine Datei, kein Chat-Bericht.** Sie ueberlebt die Session, den Branch und den
  Forge-Wechsel.
- **Einsatzpunkt-Quittung als Eingangsschritt.** Der Audit ist selbst ein Trigger und er fasst
  Traeger, Doku und Belege an: `.agents/rules/audit.md`, `.agents/rules/carrier.md`,
  `.agents/rules/docs.md` und `.agents/rules/evidence.md` werden vor Schritt 1 vollstaendig gelesen
  und quittiert (`AGENTS.md` § "Session Start: Read Before Anything Else", Schritt 3). Einmal je
  Session je Datei; die Regeltexte werden hier nicht gedoppelt.

## Eingabe

- Ziel-Repo und, falls mehrere existieren, das Architektur-/Baseline-Doc, gegen das geprueft wird.
- Fuer Schritt 0: das Decision-Log des Designs und die Pfade, die das Design anfassen wird.
- Fehlt eines: **fragen**, nicht raten.

## Schritt 0: Schnell-Check, dann faellig oder nicht

Vor jedem Design laeuft der **Schnell-Check** (`.agents/rules/audit.md` § "State Audit",
"Quick Check") — nur mit den vorhandenen Skripten, ohne eigenen PR und ohne Bericht-Datei:

- Skript fahren: `pwsh scripts/common/get-audit-worklist.ps1 -Repo <owner/name>` — Zahl der
  Punkte je Quelle und die `aged:`-Zeilen des Backlogs.
- Skript fahren: `pwsh scripts/common/sweep-carriers.ps1 -Repo <owner/name> -Since <Stempel des
  letzten Audits>` — der Stempel aus dem Dateinamen (`YYYY-MM-DDTHHMMZ`) oder ein Datum
  `YYYY-MM-DD`; das Skript meldet geschlossene Tracking Issues mit offenen Haken und Verweise auf
  geschlossene Traeger.
- Skript fahren: `pwsh scripts/common/find-closable-issues.ps1 -Repo <owner/name>` — schliessbare
  Issues mit Checkliste.

Ohne Skripte: dieselben drei Fragen von Hand nach Schritt 1 und Schritt 3 — Marker und offene
Punkte zaehlen, geschlossene Tracking Issues seit dem letzten Audit auf offene Haken lesen, offene
Issues mit Checkliste auf "fertig" pruefen —, und die Zeile sagt `by hand`.

**Ergebnis ist eine Zeile im Decision-Log des Designs**, etwa:

```text
Quick check 2026-10-08T0900Z @ 1a2b3c4: worklist 41 (3 aged), carrier sweep 0, closable 1 (#12); full audit: not due (a no, c 12/30)
```

Dann entscheidet ein Skript, ob der **volle Audit** faellig ist — die Bedingungen (a) und (c) und die
Schwelle stehen in `.agents/rules/audit.md` § "State Audit", "Full Audit"; Skript fahren:
`pwsh scripts/common/get-audit-due.ps1`. Ohne Skript: (a) `docs/audit/state-*.md` (alter Name
`docs/audit/ist-stand-*.md` bis Playbook 26.0.0) suchen; (c) die Merge-Commits mit `(#<n>)` seit dem
Commit in der Kopfzeile `**Commit:**` des letzten Audits (bis Playbook 26.0.0 (ww3d/playbook#356) auch in der Tabellenzeile `| **Commit** | <sha>` aelterer Audits) zaehlen
(`git log --first-parent --oneline <sha>..HEAD`) und gegen das Feld `**Audit threshold:**` der
`CLAUDE.md` halten (alte Form `Audit-Schwelle:` gilt bis Playbook 26.0.0).

Nicht faellig → der Skill endet mit der Zeile. Faellig → weiter mit Schritt 1; die Zeile nennt das.

## Schritt 1: Arbeitsliste erzeugen

Skript fahren: `pwsh scripts/common/get-audit-worklist.ps1 -Repo <owner/name>`; das Ergebnis wird
gelesen, nicht neu zusammengesucht. Spalten und Listen erklaert `scripts/common/README.md`. Ohne
Skript werden die drei Quellen unten von Hand gesammelt (`git grep` nach den Markern und nach
`TODO`/`HACK`/`FIXME`, die Bodies der offenen `tracking`-Issues am Head), und der Bericht sagt das.
Drei Quellen:

1. **Soll/Ist-Marker** — jede Aussage in den Architektur-/Baseline-Docs mit `[met]`, `[partial]`,
   `[planned]` oder `[unverified]` (alte Formen `[erfuellt]`, `[teilweise]`, `[geplant]`,
   `[nicht verifiziert]` gelten bis Playbook 26.0.0), mit Pfad und Zeile.
2. **Offene Punkte der Tracking Issues** — der Body jedes offenen Issues mit dem Label `tracking`,
   Punkt fuer Punkt, **und dessen GitHub Sub-Issues**, wohin die offenen Punkte ab der Grenze aus
   `.agents/rules/carrier.md` § "Tracking Issue" ziehen. Das Label ist der Filter; ohne es liefert die
   Quelle leer, und leer ist im Bericht nicht von "nichts offen" zu unterscheiden.
3. **`TODO` / `HACK` / `FIXME`** in Code und in der Prosa der Wahrheitsquellen, je mit der
   Traeger-Referenz, die `.agents/rules/carrier.md` § "Carrier Requirement" verlangt — ein Marker
   ohne Referenz ist selbst ein Befund.

Ist eine Quelle leer, wird das im Bericht gesagt. Eine stillschweigend uebersprungene Quelle ist
nicht von einer leeren zu unterscheiden. Die Zahlen dafuer stehen fertig im `source-report` des
Skripts (Rohtreffer, verworfen je Grund, nutzbar) und werden in den Bericht uebernommen.

Aus der Arbeitsliste kommen zusaetzlich vier Angaben, die spaetere Schritte lesen:

- **Liste `backlog`** — jede offene `backlog.md`-Zeile mit ihrem Alter: Quelle der Alterung in
  Schritt 3.

- **Spalte `Carrier` je Marker — Quelle fuer Schritt 4.** `target-missing` und `carrier-closed`
  sind Marker ohne gueltigen Traeger; `not-a-carrier` ebenso (der Verweis zeigt auf ein offenes
  Issue, das kein Traeger ist); `unverifiable` (kein Verweis, oder Issues nicht gelesen) wird von
  Hand geprueft; `covered` ist gedeckt — ob die `roadmap.md`-/`backlog.md`-Zeile den Punkt wirklich
  traegt, prueft der Audit trotzdem. Die Spalte `Hash` wird je Punkt in den Bericht uebernommen;
  ein anderer Hash als im vorigen Audit heisst: die Aussage wurde geaendert.
- **Liste `uncovered-carriers`** — offene Tracking Issues und Punkte, auf die kein Marker-Verweis
  zeigt; Eingang fuer die zweite Richtung in Schritt 4. Solange Verweise selten sind, ist sie lang
  und heisst "Verweise fehlen", nicht Delta.
- **Liste `remaining`** — jede `missing:`-Angabe (alt `fehlt:`) mit Datei, Abschnitt und Hash: die
  Restliste. Ein `[partial]` ohne `missing:` steht mit einer `Note` `… (undetermined)` in der Liste
  und wird in Schritt 4 als unbestimmt gemeldet.

## Schritt 2: Pruefreihenfolge je Punkt

Fest, in dieser Reihenfolge — kein Punkt wird uebersprungen, keine Stufe vorgezogen:

1. **Aussage lesen.** Was genau behauptet der Satz? Deckt er mehr als eine widerlegbare Aussage,
   wird er beim Korrigieren aufgeteilt (`.agents/rules/docs.md` § "Target vs. Actual").
2. **Im Code verifizieren.** Die Stelle suchen (`git grep`), lesen, `Datei:Zeile` notieren. Nicht
   der Doku glauben und nicht dem Marker.
3. **Test real fahren.** Den Test, der die Aussage traegt, wirklich starten. Gibt es keinen, ist
   das der Befund — nicht die Gelegenheit, den Marker trotzdem zu bestaetigen.
4. **Marker bestaetigen oder korrigieren.** Passt er, bleibt er stehen; passt er nicht, wird er im
   selben Lauf auf den wahren Wert gezogen. `[met]` ohne Beleg ist unzulaessig. Wann statt dessen
   `[unverified]` mit genanntem Fremd-Repo steht, regelt `.agents/rules/docs.md` § "Target vs.
   Actual".

**Zusaetzlich, wo der Punkt einen Mechanismus beschreibt:** gegen den Architektur-Abschnitt halten,
der ihn regelt (`.agents/rules/audit.md` § "State Audit") — der Code-Check in Schritt 2.2 beantwortet
nur "wurde das gebaut", nicht "tut es noch, was der Architektur-Abschnitt verspricht". Ein
Widerspruch ist ein Delta-Eintrag (Schritt 4), nie `[met]`.

## Schritt 3: Traeger-Wiedervorlage

Ein eigener Abschnitt, nicht in Schritt 2 vermischt. Hier wird der Bestand der Traeger geprueft,
den sonst niemand durchgeht:

- **Zeigt jeder Traeger-Link noch auf ein offenes Ziel?** Ein geschlossenes Tracking Issue ist der
  schlechteste Traeger, den es gibt — es sieht aus wie ein erledigter.
- **Die seit dem letzten Audit geschlossenen Tracking Issues auf offene Haken durchgehen.** Jedes
  Issue mit Label `tracking`, das seit dem Stempel des vorigen Audits geschlossen wurde (ohne
  Vorgaenger-Audit alle geschlossenen), Body Zeile fuer Zeile: jede unabgehakte Checkbox ist ein
  Befund. Sie wird an einen offenen Traeger gehoben — Nachfolge-Tracking-Issue oder
  `backlog.md`-Zeile — und der Fund im Bericht benannt. Skript fahren:
  `pwsh scripts/common/sweep-carriers.ps1 -Repo <repo> -Since <Stempel des vorigen Audits>`: das
  Skript liest ueber REST und filtert nach Schliessdatum, und es meldet zusaetzlich Referenzen auf
  inzwischen geschlossene Traeger-Issues. Ohne Skript: die geschlossenen `tracking`-Issues per REST
  (`gh api "repos/<repo>/issues?state=closed&labels=tracking"` bzw. `list_issues`) holen, nach
  Schliessdatum filtern und jeden Body lesen.
  **Das ist das Netz unter dem Gate aus `pr-poll-review` Phase 4 Punkt 5**, und die einzige Stufe,
  die einen **bereits eingetretenen** Fehler noch findet: das Gate verhindert den naechsten
  Auto-Close, gegen den letzten richtet es nichts aus. Ein falsch geschlossenes Issue meldet sich
  nicht selbst.
- **Traegt das Ziel wirklich den Punkt?** Am Head nachlesen.
- **Ist ein Issue mit Checkliste fertig?** Das gilt fuer jedes, mit oder ohne Label `tracking`.
  Dann schliessen — aber erst, nachdem geprueft ist, was darauf zeigt (`.agents/rules/carrier.md`
  § "Carrier Requirement"). **Der Regelweg laeuft vorher woanders:** zustaendig ist, wer den PR
  merged, der den letzten Punkt abgehakt hat (`.agents/rules/pr.md` § "Merge"); hakt kein PR ihn
  ab, wer ihn von Hand abhakt oder umhaengt (`.agents/rules/carrier.md` § "Tracking Issue");
  hilfsweise der `maintainer` (`.claude/skills/pr-poll-review/reference/gates.md` § "Nach dem
  Merge"). Der Audit ist der letzte Aufraeumer, nicht der erste Zustaendige — was er hier findet,
  ist liegengeblieben, und das gehoert in den Bericht.
  Skript fahren: `pwsh scripts/common/find-closable-issues.ps1 -Repo <repo>` ohne `-Pr`: es meldet
  jedes offene Issue mit Checkliste als `closable`, `open-boxes`, `still-carried-by` oder
  `claimed-by-open-pr` (ein anderer offener PR schliesst es mit dem Merge), davor
  `rehang-first` je Marker, der noch auf ein schliessbares Issue zeigt. Jedes `closable` ist ein
  Fund und steht mit seiner Nummer im Bericht; `SOURCE UNAVAILABLE` steht dort als nicht
  verifiziert. Ohne Skript: je offenem Issue mit Checkliste den Body am Head auf offene Haken lesen
  und per `git grep` nach `#N` pruefen, was noch darauf zeigt.
- **Doku-Schuld abbauen.** Die aufgeschobenen Doku-Zeilen in `backlog.md` werden hier gebuendelt
  abgearbeitet (`.agents/rules/docs.md` § "Documentation"). Ohne diesen Termin waeren sie eine Halde
  statt eines Traegers. Dazu zaehlen ausdruecklich auch Index-Dateien (`CLAUDE.md`, `README.md`,
  Verweislisten unter `docs/**`) — Produktiv- und Testcode bleiben ausserhalb des Audits; der Audit
  aendert keinen Produktivcode, er korrigiert Marker und traegt Punkte ein, alles andere wird ein
  eigener Auftrag.
  **Alterung:** eine `backlog.md`-Zeile, die zu alt ist, spuelt der Audit als Pflicht-Punkt in das
  Tracking Issue der naechsten Scheibe hoch — eine Zeile, die niemand abraeumt, ist keine
  Warteschlange mehr, sondern eine Halde. Zu alt ist eine Zeile, sobald seit ihr mehr PRs gemergt
  sind, als `**Audit threshold:**` zulaesst, oder mehr als 30 Tage vergangen sind, was zuerst
  eintritt — nicht nach Audit-Stempeln: volle Audits laufen nur noch, wenn sie faellig sind
  (Schritt 0), und eine Uhr, die nur mit ihnen tickt, bliebe stehen. Gezaehlt wird nicht von Hand: die Quelle
  `backlog` der Arbeitsliste fuehrt jede offene Zeile mit `Note` `aged: …` (hochspuelen), `ages: …`
  (liegt weiter) oder `exempt: …`. **Nicht altern** zwei Formen, weil sie absichtlich
  warten: der Vermerk `*(Queued … roadmap.md …)*` (die Zeile hat einen Platz in `roadmap.md`)
  und das Label `**Trigger:**` mit dem Ereignis, das sie faellig macht (die alten Formen
  `*(Eingereiht` und `**Ausloeser:**` gelten bis Playbook 26.0.0). Beide woertlich und mit
  Gross-/Kleinschreibung — eine Ausnahme, die man frei formulieren darf, waere eine Ermessensfrage.

## Schritt 3b: Eigene Abweichungen pruefen

`.agents/rules/audit.md` § "Divergences From a Source" verlangt von jedem Audit, die eigenen
Abweichungen des Repos von seinen Quellen nachzumessen. Der Schritt sammelt sie zuerst ein, dann
prueft er jede:

1. **Einsammeln**, je mit Fundstelle: die Ausnahmen in der `CLAUDE.md` des Repos (ihr Abschnitt
   "Project-Specific Overrides" und jede Zeile, die vom Playbook abweicht), die Abweichungen von
   einer Upstream- oder Vorlagen-Quelle, deren Grund im Code oder in einem Beleg-Dokument steht
   (`git grep` nach den Formeln, mit denen das Repo sie kennzeichnet, etwa "deviation",
   "Abweichung", "until #N", "bis #N"), und die Ausnahme-Datei der Ordner-Konventionen
   (`.agents/rules/code.md` § "Folder Conventions"). Eine leere Liste wird im Bericht als leer
   gesagt, nie weggelassen.
2. **Je Abweichung genau ein Ausgang** nach `.agents/rules/audit.md` § "Divergences From a Source"
   (die drei Ausgaenge, ihre Folgen und der zustandsgebundene Grund stehen dort). Die Messung steht
   daneben: Kommando und Ergebnis, oder `Datei:Zeile` am Audit-Commit.

## Schritt 4: Delta in beide Richtungen melden

Zwei Listen, beide Pflicht — je Richtung eine, auch wenn sie leer ist:

- **Marker ohne gueltigen Traeger** (`.agents/rules/carrier.md` § "Carrier Requirement"). Eine
  `[planned]`- oder `[partial]`-Aussage, deren Punkt an einem gueltigen Traeger steht, ist gedeckt
  und kein Delta. Delta ist nur ein Marker ohne jeden Traeger. Den **traegt der Audit an den
  Traeger nach `.agents/rules/carrier.md` § "Carrier Requirement"** (Absatz "A marker is
  covered"), und setzt am Marker den Verweis auf diesen
  Traeger, wo `.agents/rules/docs.md` § "Target vs. Actual" eine Form dafuer kennt — das ist die
  Verbindung, die der Marker allein nicht herstellt.
- **Punkt im Tracking Issue ohne Marker oder Code.** Ein Punkt, dem im Repo nichts entspricht:
  entweder ist er erledigt und niemand hat ihn gestrichen, oder die Doku hat die Aussage nie
  aufgenommen. Beides wird benannt, nicht stillschweigend geglaettet.

Nur eine Richtung zu melden ist der haeufigere Fehler und der teurere: eine Liste, die nur nach
fehlenden Markern sucht, laesst genau die Punkte stehen, die es nicht mehr gibt.

## Ausgabe und Gate

**Zuerst lesen und quittieren:** [`reference/report.md`](reference/report.md) — Datei, Branch,
Kopf mit Commit-SHA, Selbstauskunft, Kurzfassung als Audit-Kopf, Aufbau des Berichts und das
Gate, wann der Audit erledigt ist. Ohne diesen Lauf wird kein Bericht geschrieben.

## Strikte Regeln

- **Keine Aussage ohne real gefahrenen Test oder gelesene Codestelle.** Ein Audit, der die Doku
  gegen die Doku prueft, misst nichts.
- **`[met]` nie ohne Beleg setzen** — das ist die Behauptung, die am schnellsten veraltet.
- Nichts stillschweigend glaetten: was nicht stimmt, wird benannt, auch wenn es der eigene
  Vorgaenger-Lauf war.
- Der Audit **aendert keinen Produktivcode**; was er aendern darf, steht in Schritt 3
  ("Doku-Schuld abbauen").
- Nie ungefragt nach GitHub posten; das Editieren eines Tracking-Issue-Bodys ist Teil des Auftrags
  und damit Routine im Sinn von `.agents/rules/chat.md` § "Working With the Maintainer" — es braucht keine eigene Freigabe.
  Editiert wird mit `scripts/common/edit-issue-body.ps1` (`.agents/rules/carrier.md`
  § "Tracking Issue").

## Repo-Konventionen

- GitHub-Zugriffe nach `.agents/rules/pr.md` § "Forge Tooling".
- Sprache des Berichts nach `.agents/rules/docs.md` § "Language".
