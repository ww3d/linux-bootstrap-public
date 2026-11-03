---
name: ccweb-prompt
description: 'Design-Session: fuehrt die Design-Runde, schreibt Decision-Log, Zeilen-Datei und Spec-Datei, legt das Tracking Issue an und pusht alles auf einen Branch; die Spec ist der Auftrag, Startzeile /dev-task [repo]#[N]. Triggert bei "prompt fuer ccweb", "bau mir einen task", "prompt fuer issue #N", "prompt generieren", "task.md bauen", "design-runde". Nur fuer GitHub-Repos.'
metadata:
  version: "11.4.0"
  source: ww3d/playbook
  checksum: "sha256:100e0fe8e9b13e9294cdb2b9decb051292701105cc7af3af705189bc7518bdd5"
  # Written by ./scripts/check-skill-budget.ps1 -UpdateMeasurement, which needs an
  # ANTHROPIC_API_KEY; every later run recomputes the value and reports drift. Empty means no
  # real measurement has run yet - an invented number would be the false green this gate is against.
  measurement:
    tokens:
    model:
    measured:
    source: "not measured - no ANTHROPIC_API_KEY in the build environment of ww3d/playbook#210"
---

# Design-Runde und Spec (TASK) bauen

Fuehrt die Design-Runde zu einer Aufgabe und liefert, was die Dev-Session braucht: Decision-Log,
Zeilen-Datei, Tracking Issue und die Spec-Datei `docs/tasks/<issue>-<slug>.md`, gepusht auf einen
Branch, der Link im Tracking Issue. **Die Spec-Datei ist der Auftrag** — einen getrennten
Auftrags-Prompt gibt es nicht mehr. Die Dev-Session startet mit der Zeile
`/dev-task <owner/repo>#<N>` (Skill `dev-task`) und oeffnet den Draft-PR von diesem Branch
(`.agents/rules/pr.md` § "PR Lifecycle"). Dieser Skill oeffnet keinen PR und schreibt keinen Code.

**Im Controller-Modus laeuft er in einer eigenen, frischen Designsession**, nie im Controller: der
Controller beauftragt und entscheidet, die Designsession fuehrt Runde, Log, Zeilen-Datei, Tracking
Issue und Spec (`.agents/rules/pr.md` § "Controller Mode"). Ihr Ende ist der gepushte Branch mit
dem Link im Tracking Issue und die Abgabe dieses Links an den Besitzer (`.agents/rules/pr.md`
§ "Session Traffic").

**Es gibt keinen Review-Prompt.** `pr-poll-review` beschafft seinen Kontext selbst am Head
(Spec-Datei, Tracking Issue, Decision-Log, CI, Konstellation); der Review-Chat startet mit einer
Zeile. Ein Artefakt traegt nur Zustand, den das Repo nicht liefert.

## Kernprinzip

- **Environment, nicht Framework:** Die Spec setzt Kontext + Aufgabe. Alles, was in AGENTS.md /
  CLAUDE.md steht (Workflow, Commit-/PR-Konvention), gehoert NICHT hinein — der Agent kennt es. Es
  gilt die Artefakt-Regel aus `.agents/rules/docs.md` § "Generated Artifacts"; sie deckt
  Spec-Datei, Decision-Log, Zeilen-Datei und Handoff gleichermassen ab.
- **Docs gewinnen:** bei Widerspruch Spec vs. Repo-Docs gilt der Lese-Auftrag der Spec samt seiner
  Ausnahme ([`reference/spec.md`](reference/spec.md) § "Lese-Auftrag"). Das gilt beim Bauen genauso
  — Repo-Fakten werden am Repo verifiziert, nicht aus dem Gedaechtnis gesetzt.
- **Discussion before artifacts:** Keine Spec vor finalen Entscheidungen. Erst klaeren, dann Log,
  dann Spec.
- **Datei-Transport:** Jedes Artefakt geht als Commit auf den Branch, nie als Chat-Block; nur ohne
  Schreibzugang als Output-Datei ([`reference/decision-log.md`](reference/decision-log.md)).
- **Modell:** die Design-Session laeuft nach `.agents/rules/agents.md` § "Models".

## Eingabe

- Ziel-Repo (`owner/repo`) und die Aufgabe (frei oder Issue-Referenz `#N`).
- Fehlt eines: **fragen**, nicht raten.

## Schritt 0: Gates

**Projekt-Typ.**

- **Code-Repo mit Coding-Flow:** normale Spec, weiter mit Schritt 1.
- **Reines Design-/Infra-/Doku-Projekt** ohne Coding-Agent-Flow: KEINE Spec. Stattdessen
  Design-Diskussion + Decision-Log. Hier stoppen und das klarstellen.

**Audit** (`.agents/rules/audit.md` § "State Audit"): vor jedem Design der Schnell-Check, der volle
Audit nur, wenn er faellig ist — beides samt Faelligkeits-Pruefung, Rueckfall ohne pwsh und
Log-Zeile nach Skill `state-audit`.

- **Faellig** → der volle Audit ist der erste Auftrag, nicht das Design. Ausfuehrender ist `ccweb`,
  nicht `cweb`: der Audit verlangt Checkout, Build und real gefahrene Tests. Im Controller-Modus
  fragt die Design-Session den Controller; er startet eine frische Session `/state-audit`, und das
  Design liest ihr Ergebnis `docs/audit/state-*.md` am Head.
- **Nicht faellig** → kein eigener PR; das Design beginnt.

## Schritt 1: Design-Runde und Tracking Issue

**Vor der ersten Frage** gilt `.agents/rules/audit.md` § "Design Round" (Referenzen ganz lesen und
listen, Schwester-Repos, abgelehnte Punkte, schon Entschiedenes). Dazu:

- Was es in einem Schwester-Repo schon gibt, ist Vorbild oder Abweichung mit Grund.
- Die abgelehnten Punkte liefert `pwsh scripts/common/get-rejected-points.ps1`, mit dem Argument,
  das jeden wieder aufmachen darf (`reopen_only_with`). Ohne pwsh: die `rejected`- und
  `deferred`-Zeilen der `docs/decisions/*-ledger.jsonl` lesen (in aelteren Dateien `verworfen` und
  `zurueckgestellt`).

**Die Runde.** Nicht-triviale Aufgaben erst durchentscheiden:

- Ein Thema pro Turn, am Ende "gibt es noch was?". Nicht selbststaendig weiterspringen. Im
  Controller-Modus ist der Controller der Adressat; die Frage geht als blockierende Frage ueber das
  Zustell-Werkzeug an ihn (`.agents/rules/pr.md` § "Session Traffic"), nicht in den Chat.
- **Sechs Abschnitte je offener Entscheidung, in dieser Reihenfolge — die Pflichtform:**
  1. Worum es geht.
  2. Stand der Technik — recherchiert, nicht aus dem Gedaechtnis.
  3. Was andere machen — mehrere Vergleichsprojekte, nicht nur eins oder zwei.
  4. Ideen, naheliegende und unkonventionelle, verworfene mit Grund. **Die Vorgabe des Users ist
     hier eine Option unter anderen und wird gleich kritisch geprueft:** was spricht dagegen, welche
     Regel oder fruehere Entscheidung sie verletzt, welchen Preis sie hat, was besser waere.
  5. Empfehlung — eine klare Ansage, keine Auswahl zum Selbstentscheiden.
  6. Was uns abheben koennte — **faellt nie weg**, auch als "hier nichts". Methode, Abheber und
     Grenze: `.agents/rules/audit.md` § "Design Round", Punkt "Every design question".

  Dazu am Ende jeder Runde die Liste **"nicht nachgelesen"**. **Staffel:** volle Form fuer
  Architektur-, Regel- und Schnitt-Entscheidungen; **Kurzform** (Worum / Empfehlung / Verworfen mit
  Grund) fuer Kleines — die gewaehlte Stufe wird genannt. Laesst sich ein Abschnitt (Stand der
  Technik, Vergleichsprojekte) nicht sauber belegen, entfaellt der Slot statt geraten zu werden.
  Wie die Fragen dem Maintainer vorgelegt werden: `.agents/rules/chat.md` § "Talking to the Maintainer"
  (letzter Punkt).
- **Architektur-Abgleich, wo eine Entscheidung einen Mechanismus anlegt, verlegt oder aendert.** Ihre
  Semantik — was er tut, was er darf, was er nie darf — wird gegen den Architektur-Abschnitt
  gehalten, der ihn regelt, und dieser Abschnitt wird im Decision-Log genannt. "Eine Backlog-Zeile
  dazu abarbeiten" ersetzt diese Frage nicht — sie prueft nicht, ob der neue Mechanismus dem
  Abschnitt noch entspricht, sondern nur, ob irgendwas notiert wurde.
- Ergebnis als Decision-Log plus Zeilen-Datei, festgeschrieben **bevor** die Spec entsteht.
  **Zuerst lesen und quittieren:** [`reference/decision-log.md`](reference/decision-log.md), in der
  Zeilenform aus `AGENTS.md` § "Session Start: Read Before Anything Else", Schritt 3.

**Das Tracking Issue entsteht hier**, im selben Zug wie das Decision-Log und **bevor** die Spec
geschrieben wird, mit den Labels `tracking` und `state:design` — Regeln in
`.agents/rules/carrier.md` § "Tracking Issue". Die Spec verlinkt das Issue.

**Feste Ueberschriften des Bodys**, in dieser Reihenfolge und woertlich, weil
`scripts/common/edit-issue-body.ps1 -Section` sie sucht: `## Order` (der Auftrag des Maintainers
woertlich, Form nach `.agents/rules/pr.md` § "Task Spec"), `## Design` (Branch, Spec-Datei,
Decision-Log, Zeilen-Datei, `Review-Mode:`, Startzeile), `## Open points` (die offenen Punkte als
Kaestchen), `## Unclear, to measure`, `## Corrected`, `## Done`. Diese Liste ist die eine Stelle
dafuer. Verlangt der Auftrag eine Sichtabnahme, setzt die Design-Session unter `## Design` die Zeile
`Visual acceptance: <what>` (Form und Wirkung: `.agents/rules/pr.md` § "Merge").

## Schritt 2: Repo-Kontext laden

Am echten Repo verifizieren (`gh api` oder GitHub-Connector: `get_file_contents`, `issue_read`),
nicht annehmen:

- Pflichtkern und laufende Scheibe nach `AGENTS.md` § "Session Start: Read Before Anything Else",
  Schritte 1 und 2 — je mit Blob-SHA quittiert; Roadmap, Backlog und Architektur-Dokument nur on
  demand vor der Aussage, die sie betrifft.
- Einsatzpunkt-Quittungen nach `AGENTS.md` § "Rule Files": dieser Skill schreibt einen Auftrag,
  zeitgestempelte Dateien und ein Tracking Issue, trifft also vor allem `carrier`, `pr`, `audit`
  und `docs`.
- Issue-/Label-Konvention und den Decision-Log-Ort des Repos (`docs/decisions/README.md`).
- Betroffene Quell-Files, damit die Spec sie gezielt benennen kann.
- **Uebernahme-Check — was frueheren Scheiben hierher zugewiesen wurde:** vor dem Schnitt pruefen,
  ob eine Vorgaenger-Scheibe dieser Scheibe Punkte zugewiesen hat. Quelle ist **das Issue dieser
  Scheibe und ihre `roadmap.md`-/`backlog.md`-Zeile** — nicht der PR-Body des Vorgaengers, den
  niemand zurueckliest. Jeder gefundene Punkt wird in der Spec entweder als Vorgabe gefuehrt oder
  ausdruecklich als bewusst nicht gebaut benannt; stillschweigendes Uebergehen ist genau der
  Fehler, gegen den dieser Check steht.
- **Quellen-Erreichbarkeits-Check:** Jede Quelle, die die Spec referenziert (Issues, Decision-Logs,
  Konventions-Docs, fremde Repos), pruefen: existiert sie, ist sie gemergt/synced, und kann die
  **Ziel-Session** sie erreichen (Repo-Scope, Sandbox-Whitelist der Agent-Umgebung)? Was dann gilt:
  [`reference/spec.md`](reference/spec.md) § "Quellen in der Spec".

## Schritt 3: Spec bauen

**Zuerst den Review-Modus abfragen — Pflicht, keine Spec ohne diese Abfrage.** Der Skill schlaegt
selbst einen Modus vor (Heuristik in [`reference/spec.md`](reference/spec.md)) und fragt mit
vorbelegtem Vorschlag: "Review-Mode: hard / light / soft?". Im Controller-Modus ist der Controller
der Adressat, als blockierende Frage (`.agents/rules/pr.md` § "Session Traffic"). Die Spec nennt nur
die Zeile `Review-Mode: <mode>`; der Wortlaut steht in
[`pr-poll-review/reference/review-modes.md`](../pr-poll-review/reference/review-modes.md).

**Zuerst lesen und quittieren:** [`reference/spec.md`](reference/spec.md) — Lese-Auftrag, die acht
Bloecke, REQ-Schnitt, Doku-Nachzug, Baubar-Pflicht und Abhaken, was nicht hineingehoert. Dann die
Spec-Datei nach `.agents/rules/pr.md` § "Task Spec" schreiben.

## Schritt 4: Pushen und verlinken

1. Decision-Log, Zeilen-Datei und Spec-Datei auf einen Branch committen und pushen
   ([`reference/decision-log.md`](reference/decision-log.md) § "Ablage per Push"); vorher
   `scripts/common/test-ledger.ps1` gruen.
2. Unter `## Design` im Body des Tracking Issues verlinken: Branch, Spec-Datei, Decision-Log,
   Zeilen-Datei, `Review-Mode: <mode>` und die Startzeile `/dev-task <owner/repo>#<N>`; den Body
   aendern nach `.agents/rules/carrier.md` § "Tracking Issue".
3. Das Zustands-Label des Issues pruefen: es steht auf `state:design` (Schritt 1), auch wenn das
   Issue schon vor der Runde bestand; die Design-Session setzt es selbst, nach der Ausnahme in
   `.agents/rules/pr.md` § "State Labels".

Damit endet die Runde, mit der Abgabe nach `.agents/rules/pr.md` § "Session Traffic": der Link
auf das Tracking Issue an den Besitzer. Die Startzeile liest der Controller am Issue; ohne Controller
nennt die Session sie dem Maintainer mit. Will der Controller vor dem Merge den zweiten Blick, bleibt
die Session bis dahin bestehen.

## Zweiter Blick

Auf Anstoss des Controllers (ein Hinweis, `.agents/rules/pr.md` § "Session Traffic", Punkt 7), am
approvten Head: jede Festlegung des Decision-Logs und jeder Satz des
Auftrags (`## Order`) gegen den Diff. Funde gehen als Bericht-Datei an den Controller, wie ein
Review-Bericht (`.agents/rules/pr.md` § "Session Traffic", Punkt 3); er macht daraus eine neue
Review-Runde. Ohne Fund geht nur die Abgabe, der Link auf das Tracking Issue.

## Strikte Regeln

- Nie ungefragt etwas nach GitHub posten ausser Branch, Tracking Issue samt Body und Zustands-Label
  aus diesem Ablauf. Reine Status-Reads (PR/CI) sind ohne Freigabe ok. Eine Fix-Anweisung fuer
  einen offenen PR geht als PR-Review-Kommentar nach expliziter Freigabe.
- Keine Spec fuer ein neues Design ohne Schritt 0 und ohne das angelegte Tracking Issue aus
  Schritt 1.
- Wann diese Design-Session rotiert, sagt ihre Art in `.agents/session-kinds.json`; die Uebergabe regelt `.agents/rules/pr.md` § "Controller Sessions".
- Neue Namen recherchiert die Runde und legt sie zur Abstimmung vor (`.agents/rules/code.md`
  § "New Names and Dependencies"). Bestehende (Fork-)Identifier nie unaufgefordert umbenennen.
- Verifizieren statt spekulieren: Repo-Fakten kommen aus dem Repo, nicht aus dem Gedaechtnis — und
  jede referenzierte Quelle muss fuer die Ziel-Session erreichbar sein (Schritt 2), sonst inline.
- Keine Spec ohne die Review-Modus-Abfrage aus Schritt 3, ohne den Uebernahme-Check aus Schritt 2
  und ohne einzeln aufgezaehlte Doku-Nachzugs-Quellen.
- Der Text eines Weckers (`ScheduleWakeup`, `/loop`) nennt den Schritt, auf den gewartet wird, und
  was danach zu tun ist, nie die Startzeile des Skills; ein Hintergrund-Lauf meldet sein Ende
  selbst, der Wecker ist nur Rueckfall.

## Repo-Konventionen

- GitHub-Zugriffe nach `.agents/rules/pr.md` § "Forge Tooling".
- Rollen getrennt: die Dev-Session oeffnet Draft-PRs (`dev`), gemergt wird nach
  `.agents/rules/pr.md` § "Merge".
