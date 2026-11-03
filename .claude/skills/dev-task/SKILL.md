---
name: dev-task
description: 'Dev-Session: /dev-task [repo]#[N] liest das Issue, findet Branch und Spec-Datei der Design-Runde, arbeitet darauf und oeffnet den Draft-PR; /dev-task "[auftrag]" pusht sofort Branch und Draft-PR mit dem Auftrag woertlich. Triggert bei "/dev-task", "dev-task", "setz issue #N um", "arbeite die spec ab". Nur fuer GitHub-Repos.'
metadata:
  version: "2.9.0"
  source: ww3d/playbook
  checksum: "sha256:7926abf63efadb80519a969549057c328ce49c8ac08a21b02df7a01a717ba8c6"
  # Written by ./scripts/check-skill-budget.ps1 -UpdateMeasurement, which needs an
  # ANTHROPIC_API_KEY; every later run recomputes the value and reports drift. Empty means no
  # real measurement has run yet - an invented number would be the false green this gate is against.
  measurement:
    tokens:
    model:
    measured:
    source: "not measured - no ANTHROPIC_API_KEY in the build environment of ww3d/playbook#351"
---

# Dev-Auftrag umsetzen

Fuellt die `dev`-Rolle aus `.agents/rules/pr.md` § "PR Lifecycle": Code schreiben, Draft-PR
oeffnen, testen, auf ready stellen, Reviewer setzen. Wie weit ein Dev-Auftrag reicht, regelt
`.agents/rules/pr.md` § "Controller Sessions"; sein Inhalt steht am Traeger (Issue, Spec-Datei,
PR-Body), nie nur in der Startnachricht. Der Merge gehoert nicht dazu (`.agents/rules/pr.md`
§ "Merge").

## Aufruf

- `/dev-task <owner/repo>#<N>` — Weg A: das Issue traegt den Auftrag; die Design-Runde
  (`ccweb-prompt`) hat Branch, Spec-Datei, Decision-Log und Zeilen-Datei gepusht und im Body
  verlinkt.
- `/dev-task "<auftrag>"` — Weg B: der Auftragstext ist der Auftrag; Ziel-Repo ist das Repo der
  Session, sonst steht `<owner/repo>` davor.
- Fehlt beides oder ist das Repo unklar: **fragen**, nicht raten.

## Schritt 0: Eingang

1. Session-Start nach `AGENTS.md` § "Session Start: Read Before Anything Else": Pflichtkern lesen
   und je Datei mit Blob-SHA quittieren. Ohne Hooks ist das die erste Antwort.
2. Einsatzpunkt-Quittungen nach `AGENTS.md` § "Rule Files" vor der ersten Aktion ihres Typs; eine
   Dev-Session trifft vor allem `pr`, `code`, `docs`, `carrier` und `evidence`.
3. Konto pruefen und setzen, bevor irgendetwas geschrieben wird, nach `.agents/rules/pr.md`
   § "Accounts per Seat".
4. Modell nach `.agents/rules/agents.md` § "Models".

## Schritt 1a: Weg A — Issue

1. Den Issue-Body vollstaendig lesen (`gh api repos/<owner>/<repo>/issues/<N> --jq .body`;
   Connector: `issue_read`). Er verlinkt Branch, Spec-Datei
   `docs/tasks/<N>-<slug>.md`, Decision-Log, Zeilen-Datei und `Review-Mode: <mode>`.
2. Den Branch holen: `git fetch origin && git switch <branch>` (Connector: `get_file_contents` mit
   `ref` auf den Branch). Auf **diesem** Branch wird gearbeitet; kein neuer, kein Auto-Slug.
3. Spec-Datei, Decision-Log und Zeilen-Datei am Head des Branches **vollstaendig** lesen. Die Spec
   ist der Auftrag; bei Widerspruch zu den Docs gilt ihr Lese-Auftrag
   ([`.claude/skills/ccweb-prompt/reference/spec.md`](../ccweb-prompt/reference/spec.md)
   § "Lese-Auftrag").
4. Nennt das Issue keinen Branch oder keine Spec: nicht raten, sondern eine blockierende Frage
   (Schritt 4).
5. Den Draft-PR frueh von diesem Branch oeffnen (`gh api repos/<owner>/<repo>/pulls -f head=<branch>
   -f base=<basis> -f title=<titel> -F body=@<datei> -F draft=true`; Connector:
   `create_pull_request` mit `draft: true`), Body nach
   `.agents/rules/pr.md` § "PR / MR Description", Spec verlinkt, Anker mit `Refs #<N>` oder
   `Closes #<N>` nach den Regeln dort. Steht von diesem Branch schon ein offener PR, arbeitet die
   Session auf ihm weiter — zuerst eine Zeilen-Datei aus dem Review-Body (im Controller-Modus nur
   die einer Runde mit Funden) und offene Befunde (Schritt 4).
6. **Ohne Controller** das Tracking Issue auf `state:dev` setzen und `state:design` abnehmen
   (`.agents/rules/pr.md` § "State Labels"), mit den Befehlen aus `controller-mode` § "Schritt 4:
   Steuern" (Zustands-Labels). Ueber den Connector erst die Labels lesen, dann die volle Liste
   schicken: `issue_write` ersetzt die Liste. Im Controller-Modus setzt es der Controller.

## Schritt 1b: Weg B — Auftragstext

Weg B braucht einen Checkout: der Start-Commit ist leer, und den kann nur `git` pushen —
`push_files` des Connectors braucht Dateien, und GitHub oeffnet keinen PR ohne Commit vor der Basis.

1. Branch nach `.agents/rules/pr.md` § "Branch Naming" anlegen.
2. Leerer Start-Commit (`git commit --allow-empty`), **sofort** pushen (`git push -u origin
   <branch>`) und den Draft-PR oeffnen (REST-Form aus Schritt 1a Punkt 5; Connector:
   `create_pull_request` mit `draft: true`). Der Auftrag steht **woertlich**
   im PR-Body, als Zitat unter **What** — ungekuerzt, unveraendert.
3. Traegt der Auftrag eine nummerierte Liste: jetzt die Spec-Datei nach `.agents/rules/pr.md`
   § "Task Spec" committen und pushen; der Body verlinkt sie. Nennt der Auftragstext ein Issue, ist
   es der Anker: `docs/tasks/<issue>-<slug>.md`, im Body `Refs #<issue>`. Nur ohne Issue ist der PR
   der Anker: `docs/tasks/pr-<N>-<slug>.md` mit der PR-Nummer.
4. Nennt der Auftragstext kein Issue, entsteht eines, sobald ein Punkt offen bleibt, der einen
   Traeger braucht (`.agents/rules/carrier.md` § "Carrier Requirement"); nennt er eines, steht
   der Punkt in dessen Body.

## Schritt 2: Bauen

- Nach der Spec, REQ fuer REQ; jede REQ abhaken oder `not delivered: <reason>`. Gelieferte Punkte
  aus dem Body des Tracking Issues im selben PR dort abhaken, Weg nach `.agents/rules/carrier.md`
  § "Tracking Issue"; danach die Anker-Zeile des PR-Bodys (`Closes` oder `Refs`) nach
  derselben Stelle setzen.
- Den PR abonnieren, wo `subscribe_pr_activity` vorhanden ist (Laden nach `.agents/rules/pr.md`
  § "PR Lifecycle"); sonst weckt der Besitzer die Session nach Befunden per Weiterstart mit ihrer
  Skill-Zeile.
- Stand frueh und oft pushen; vor jedem geplanten Ende alles gepusht, WIP auf dem Branch.
  Wann die Dev-Session verdichtet und uebergibt: `.agents/session-kinds.json`, `.agents/rules/pr.md` § "Controller Sessions".
- Kein Zug endet mit einer Ankuendigung: was angekuendigt ist, geschieht im selben Zug
  (`.agents/rules/pr.md` § "Session Traffic").
- Sub-Agenten sind erlaubt, ihr Ergebnis wird vor der Uebernahme geprueft (`.agents/rules/agents.md` § "Sub-Agents"); eigene Sessions — etwa eine Web-Session fuer den Linux-Lauf — startet, besitzt
  und raeumt die Session nach `.agents/rules/pr.md` § "Controller Sessions" selbst ab.
- REQ gegen den Auftrag des Maintainers: `.agents/rules/pr.md` § "Task Spec".
- Review-Wellen nach dem Modus der Spec: den Baustein
  [`pr-poll-review/reference/review-modes.md`](../pr-poll-review/reference/review-modes.md) lesen
  und quittieren, bevor die erste Welle laeuft; der Wellen-Bericht geht in den PR-Body.

## Schritt 3: Testen

Nach `.agents/rules/pr.md` § "Test Runs" — dort stehen Zahl und Zeitpunkt der vollen Laeufe,
Korrekturrunden, Ausnahmen, Zeitvorgabe und die Form der Laufzeile. Den vollen Lauf (Befehl,
Plattformen) und die Guard classes nennt die `CLAUDE.md` des Repos im Abschnitt
`## Test Runs and Audit` (gelesen bis Playbook 26.0.0: `## Testlauf und Audit`); je Lauf eine
Laufzeile unter "How tested".

## Schritt 4: Ende

**Das Ende ist der PR und seine Abgabe**: zuerst ein Durchgang allein ueber den ganzen Diff, jedes
REQ per `git grep` am Head belegt — gesucht wird der Code, den es verlangt, nicht seine Nummer;
dann der volle Lauf, Push, Draft → ready (Weg:
`.agents/rules/pr.md` § "PR Lifecycle", Schritt 5), Reviewer nach `.agents/rules/pr.md` § "Reviewer"
gesetzt (`gh api repos/<owner>/<repo>/pulls/<n>/requested_reviewers -f "reviewers[]=<konto>"` je
Konto), Laufzeilen im Body; dann die Abgabe an den Besitzer ueber das Zustell-Werkzeug, im
Controller-Modus `#N Head <sha> bereit` (`.agents/rules/pr.md` § "Session Traffic", Punkte 2 und
8). **Ohne Controller** setzt die Session beim Schritt auf ready das Tracking Issue auf
`state:review` und nimmt `state:dev` ab, wie in Schritt 1a Punkt 6; im Controller-Modus setzt es der
Controller. Weg B ohne Tracking Issue setzt kein Label.

Welche Nachrichten sonst erlaubt sind, regelt `.agents/rules/pr.md` § "Session Traffic" — eine
ausbleibende Antwort dort "Questions and Follow-Up", ein Auftrag am Besitzer vorbei, auch vom
Maintainer direkt, "Orders and Rank"; ein Nachtrag des Maintainers zum laufenden PR: § "Controller
Mode". Eine
blockierende Frage steht in der Kurzform aus `ccweb-prompt` § "Schritt 1: Design-Runde und Tracking
Issue" (Absatz "Staffel": Worum / Empfehlung / Verworfen mit Grund), Empfehlung vorbelegt, vorgelegt
nach `.agents/rules/chat.md` § "Talking to the Maintainer" (letzter Punkt); "stuck" mit einem Satz, woran.

**Approve mit Vorschlaegen:** kommt das Approve (oder die Zeile `Review-Verdict: approve <sha>`) mit
offenen `suggestion`-Blocks, spielt die Session jeden woertlich oder gar nicht ein (ablehnen nach
`.agents/rules/pr.md` § "Controller Mode"), ohne neue Runde, testet nach `.agents/rules/pr.md`
§ "Test Runs" (ein Vorschlag in einer Codedatei ist Code), pusht, resolvt die Threads der
eingespielten und der abgelehnten Vorschlaege (ohne REST-Form: `.agents/rules/pr.md` § "Forge Tooling"; der
Ruleset verlangt geloeste Threads) und meldet wie heute `#N Head <sha> bereit` — im
Controller-Modus an den Controller. Jede andere Aenderung danach ist eine normale Runde; das
Merge-Gate beweist die Vorschlaege (`scripts/common/test-applied-suggestions.ps1`).

Review-Befunde arbeitet die Session im selben PR ab, solange sie laeuft, mit dem PR im Entwurf
(`.agents/rules/pr.md` § "PR Lifecycle", Schritt 6); eine neue Aufgabe ist eine neue Session. Im
Controller-Modus bleibt sie dafuer am Leben; den Namen des Reviewers nennt ihr der Controller als
Hinweis (`.agents/rules/pr.md` § "Session Traffic", Punkt 7). Auf `#N Review zu <sha> steht` stellt
sie den PR auf Entwurf, fixt alles — je `issue:` fuehrt sie dessen Suche selbst am Head aus und
behebt jeden Treffer der Fehlerart, nicht nur die genannten Zeilen; einen vorgegebenen Fix-Text
prueft sie am Code, statt ihn abzuschreiben —, testet nach den Regeln fuer Korrekturrunden
(`.agents/rules/pr.md` § "Test Runs"), pusht, stellt ihn wieder bereit und schickt dem Reviewer ohne
Antwort `#N Head <sha> bereit`. Die Zeilen-Datei einer Review-Runde committet sie nach
`.agents/rules/pr.md` § "Round Ledger", Name und Commit-Form nach
`.claude/skills/pr-poll-review/reference/report.md` § "Zeilen-Datei der Runde"; im
Controller-Modus pusht die einer sauberen Runde der Controller — nach deren Approve pusht die
Session nichts mehr.

## Strikte Regeln

- Nie mergen (`.agents/rules/pr.md` § "Merge").
- Nie einen anderen Branch als den des Issues bzw. den eigenen benutzen.
- Der Text eines Weckers (`ScheduleWakeup`, `/loop`) nennt den Schritt, auf den gewartet wird, und
  was danach zu tun ist, nie die Startzeile des Skills; ein Hintergrund-Lauf meldet sein Ende
  selbst, der Wecker ist nur Rueckfall.
- Es gelten ohne Ausnahme die Kernregeln 1, 4 und 9 (`AGENTS.md` § "Core Rules") und die Ansage
  eines Force-Push im Body (`.agents/rules/pr.md` § "PR / MR Description").
- GitHub-Zugriffe nach `.agents/rules/pr.md` § "Forge Tooling".
