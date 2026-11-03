---
name: pr-poll-review
description: 'Reviewt einen GitHub Pull Request iterativ bis zum Approve und fuellt die reviewer-Rolle des Playbook-PR-Lifecycles; endet mit dem Approve. Triggert bei "review und wenn ok approve", "pr pollen", "check PR [ref]", "approve sobald die changes da sind", "rere". Nicht fuer einen einmaligen Review ohne Approve. Nur fuer GitHub-PRs.'
metadata:
  version: "14.9.0"
  source: ww3d/playbook
  checksum: "sha256:7adca2e006e0a79d1ecbed59982066e4ed55c8e3dee0ec8c11ecf84cff97162f"
  # Written by ./scripts/check-skill-budget.ps1 -UpdateMeasurement, which needs an
  # ANTHROPIC_API_KEY; every later run recomputes the value and reports drift. Empty means no
  # real measurement has run yet - an invented number would be the false green this gate is against.
  measurement:
    tokens:
    model:
    measured:
    source: "not measured - no ANTHROPIC_API_KEY in the build environment of ww3d/playbook#210"
---

# PR Review & Approve Workflow

Iterativer Review-Loop fuer GitHub-PRs. Faehrt von Erstreview bis Approve durch und fuellt die
`reviewer`-Rolle aus `.agents/rules/pr.md` § "PR Lifecycle" (Schritte 6-7). Der Merge und das
Schliessen des Tracking Issues liegen bei dem, der merged (`.agents/rules/pr.md` § "Merge") — dieser
Skill merged nie und endet mit dem Approve.

## Wann

Wenn ein PR zu reviewen ist, bis zum Approve: Kontext selbst am Head beschaffen, ein Review-Prompt
existiert nicht (Phase 1, Schritt 1); klassifizieren und pruefen, jeden Punkt in Conventional
Comments (Kernprinzip, Schritte 2-3); vor jeder Veroeffentlichung Chat-Report — im claude.ai-Chat
plus Widget — zur Freigabe (Schritt 4); posten, auf Pushes warten, neu reviewen (Phasen 2-3);
approven erst mit belegtem lokalem Testlauf ohne Merge-Konflikte (Phase 4).

## Kernprinzip

- **Session-Start-Pflicht:** Vor Phase 1 gilt `AGENTS.md` § "Session Start: Read Before Anything
  Else" des Ziel-Repos — Pflichtkern (AGENTS-Kern, `CLAUDE.md`, Audit-Kopf) lesen und je Datei mit
  Blob-SHA quittieren. Der Review laeuft am Head des Repos, nie aus dem Chat-Verlauf oder dem
  Gedaechtnis.
- **Einsatzpunkt-Quittung als Eingangsschritt.** Dieser Skill loest vier Trigger aus: er postet
  einen Review, er beurteilt einen PR-Body, er prueft Traeger und er wiegt Belege. Vor Phase 1
  werden darum `.agents/rules/review.md`, `.agents/rules/pr.md`, `.agents/rules/carrier.md` und
  `.agents/rules/evidence.md` **vollstaendig gelesen und quittiert** — Format und Pflicht stehen in
  `AGENTS.md` § "Session Start: Read Before Anything Else", Schritt 3, einmal je Session je Datei.
  In ccweb erzwingt der `require-rule-read.sh`-Hook dasselbe; wo kein Hook laeuft, ist dieser
  Schritt die einzige Absicherung. Die Regeltexte werden hier **nicht** gedoppelt, sondern gelesen.
- **Dieselbe Quittung fuer die drei Referenzdateien.** `reference/checks.md`,
  `reference/report.md` und `reference/gates.md` tragen die Kasuistik dieses Skills. Jede wird
  an ihrer Einsatzstelle **vollstaendig gelesen und quittiert**, bevor der Schritt laeuft, der
  sie braucht — nicht ueberflogen, einmal je Session je Datei, in der Zeilenform aus `AGENTS.md`
  § "Session Start: Read Before Anything Else", Schritt 3 (die Referenzdatei mit ihrem Pfad).
- **Freigabe-Standard und Out of Scope** stehen in `.agents/rules/review.md` § "Review Comments"
  (freigeben, sobald der PR eindeutig verbessert; Out of Scope blockt nicht und wird gebaut, die
  drei nicht baubaren Faelle nach `.agents/rules/carrier.md` § "Carrier Requirement").
- **Beyond the diff bleibt Suchmethode, nicht Blocking-Grund.** Verwandte Files, Configs und Tests
  werden mitgelesen — dort liegt die Fehlerklasse, die sonst niemand sieht.
- **Modell dieser Session und ihrer Sub-Agenten nach `.agents/rules/agents.md` § "Models"**, in jedem
  Review-Modus (`.agents/rules/review.md` § "Review Comments").
- **Agent-Autor-Annahme:** Der Author (ein Coding-Agent, z.B. Claude Code oder Copilot) produziert
  Code, der sauber aussieht, aber leise mehr Redundanz und Tech-Debt traegt als menschlicher. Nicht
  vom Oberflaechen-Eindruck taeuschen lassen — gezielt nach den Agent-typischen Fehlerklassen
  suchen (Phase 1, Red-Flags).
- **Conventional Comments sind das Vokabular.** Labels, Dekoration, Trennstrich ("wer antworten
  muss") und Nit-Regeln stehen in `.agents/rules/review.md` § "Review Comments" und werden hier
  nicht gedoppelt. Im Zweifel, ob eine Korrektur wirklich eindeutig ist, ist es eine `question:` —
  praeskriptiv als `issue:` posten nur, wenn sie es ist.
- **Ein `nitpick:` geht als `suggestion`-Codeblock** im `body` des Inline-Kommentars, mit `path` und
  `line` (Postform: `reference/report.md` § "Suggested Change als Postform").
- **Ein `issue:` traegt im geposteten Kommentar** die drei Zeilen Fehlerart, Suche (der Befehl,
  woertlich) und Fundstellen, nicht nur im Bericht — der Dev wiederholt dieselbe Suche
  (`reference/checks.md` § "Fehlerart je Befund").
- **Jede `question: (blocking)` in der Form aus `reference/report.md` § "Stufe A —
  Chat-Report" (Offene Fragen), die Empfehlung vorbelegt.** Die uebrigen Labels brauchen diese
  Form nicht — ihre Korrektur steht im Text selbst.
- **Freigabe-Gate:** Kein Kommentar wird gepostet, bevor der Adressat die gesammelten Punkte
  gesehen und freigegeben hat (Phase 1, Schritt 4); die saubere Runde braucht keine
  (`.agents/rules/pr.md` § "Round Ledger"). Adressat ist der Mensch — oder im
  Controller-Modus der Controller (`.agents/rules/pr.md` § "Controller Mode"): dann geht Stufe A
  als Text-Datei an ihn, als Review-Bericht nach `.agents/rules/pr.md` § "Session Traffic" — lokal
  nennt die Nachricht den Pfad, im Web liegt die Datei auf dem Branch `review/<N>-report`
  (`.agents/rules/pr.md` § "Branch Naming") und die Nachricht nennt ihren Pfad; die Freigabe kommt
  als Text zurueck, und das Widget entfaellt. Faellt der Nachrichtenweg aus, gilt
  `.agents/rules/pr.md` § "Session Traffic" (Delivery and Change of Owner).
- **Review-Schleife im Controller-Modus** mit der Dev-Session, deren Namen der Start nennt
  (`.agents/rules/pr.md` § "Session Traffic", Punkt 8): jede Runde findet alle Punkte, auch die
  nicht blockierenden; nach dem Posten geht ohne Antwort `#N Review zu <sha> steht` an den Dev, und
  auf sein `#N Head <sha> bereit` laeuft Phase 3 fuer das Delta.
- **Author-Loop:** Jeder Review-Kommentar fordert den Author explizit auf, nach dem Fix am PR
  zurueckzumelden.
- **Doku-only-PR:** was als doku-only zaehlt und dass er kein Review-Gate braucht, steht in
  `.agents/rules/docs.md` § "Documentation"; gruene Gates genuegen, der Review darf nachlaufen.

## Eingabe

PR-Referenz, Pflicht (sonst danach **fragen**, nicht raten):

- `owner/repo#123` oder URL `https://github.com/owner/repo/pull/123`.
- Ausnahme `rere`: Re-Review des zuletzt in dieser Session per `/pr-poll-review` gereviewten PRs,
  ohne die Referenz erneut zu nennen. Ohne vorherigen Review in der Session weiterhin **fragen**.

Optional (nur fuer den Polling-Fallback relevant):

- `poll_interval` — Sekunden zwischen Polls (Default: 30; Remote-API-Rate-Limits beachten).
- `max_iterations` — Review-Runden bevor abgebrochen wird (Default: 10).
- `timeout_minutes` — Gesamttimeout (Default: 60).

Werkzeuge: jeder GitHub-Zugriff steht hier als `gh api` (REST; Grund und Wahl des Wegs:
`.agents/rules/pr.md` § "Forge Tooling"); die Namen des GitHub-MCP stehen daneben fuer Umgebungen ohne `gh`,
etwa den claude.ai-Chat.

## Phase 1: Erstreview

1. **Kontext selbst beschaffen — es gibt keinen Review-Prompt.** Der Review-Chat startet mit seiner
   Startzeile (Tabelle in `controller-mode` § "Schritt 4: Steuern"); alles Weitere wird am Head
   gelesen, nie aus dem Chat uebernommen. Zu holen, in dieser Reihenfolge:

   - Diff via `gh api repos/<repo>/pulls/<n> -H "Accept: application/vnd.github.diff"` bzw.
     `pull_request_read` (method=`get_diff`); bestehende Threads via
     `gh api repos/<repo>/pulls/<n>/comments` bzw. `get_review_comments`, um Doppel-Kommentare zu
     vermeiden.
   - **Spec-Datei** `docs/tasks/<issue>-<slug>.md`, **Tracking Issue** und **Decision-Log** — je am
     Head lesen (`gh api repos/<repo>/contents/<pfad>?ref=<sha>` bzw. `get_file_contents` am
     Head-SHA), nicht dem PR-Body glauben. Der PR-Body verlinkt sie.
   - **CI-Status** via `gh api repos/<repo>/commits/<sha>/check-runs` bzw. `get_check_runs`,
     **Default-Branch** aus dem PR-Objekt.
   - **Review-Modus** aus der Spec-Datei am Head, Zeile `Review-Mode: <mode>` (`hard vN` / `light` /
     `soft`; die alte Form `Review-Modus:` gilt bis Playbook 26.0.0), nie aus dem PR-Body. Traegt
     die Spec keine Zeile oder gibt es keine Spec, gilt kein Wellen-Bericht-Gate. Die Wellen werden
     gegen den Baustein des Modus geprueft:
     [`reference/review-modes.md`](reference/review-modes.md).
   - **Konstellation am PR messen.** `gh api user --jq .login` bzw. `get_me` zuerst gegen das Konto
     des menschlichen Inhabers des `maintainer`-Sitzes halten: ist es dieses Konto, wird auf diesem
     Weg nichts gepostet (`.agents/rules/pr.md` § "Accounts per Seat"). Dann gegen den PR-Autor:
     verschiedene Accounts → `APPROVE` erlaubt; gleicher Account → GitHub sperrt `APPROVE` am
     eigenen PR, das Verdikt geht als `COMMENT` mit der Zeile `Review-Verdict: approve <head-sha>`
     (`.agents/rules/review.md` § "Review Comments", Phase 4).

2. **Scan & Classify.** Filelist + Diff-Groesse ueberblicken, Review-Tiefe festlegen: kleine
   Touch-PRs duerfen knapp bleiben, grosse/breite PRs bekommen die volle Tiefe.
   Ab rund 300 geaenderten Zeilen (ohne reine Verschiebungen und generierte Dateien) wird je Commit
   oder je Datei getrennt geprueft, die Funde danach zusammengefuehrt; die Suche je Fehlerart laeuft
   weiter ueber den ganzen PR (`.agents/rules/review.md` § "Review Comments").
   Wie parallelisiert und welches Modell je Pass: [`reference/checks.md`](reference/checks.md).

3. **Code durchgehen, Punkte sammeln.** **Zuerst lesen und quittieren:**
   [`reference/checks.md`](reference/checks.md) — der Pruefkatalog, nach dem gesucht wird,
   und was pro Punkt festzulegen ist. **Mechanisch vorweg, in jeder Runde — Skript fahren:**
   `pwsh scripts/common/find-moved-fixes.ps1 -Repo <repo> -Pr <n>` — jeder `moved-fix` ist ein
   `issue: (blocking)` ohne Ermessen. Ohne Skript: jede waehrend des PRs neu in den Body des
   Tracking Issues, in `roadmap.md` oder `backlog.md` gekommene Zeile von Hand gegen die Dateiliste
   des Diffs halten (`reference/checks.md` § "Backlog-Gegencheck"). Dann: Zeile fuer Zeile, kein
   Sampling; verwandte Files/Configs/Tests mitpruefen, nicht nur den Diff-Rand.
   **Verhaltensaenderung ohne Doku-Delta** ist ein `issue: (blocking)` (`reference/checks.md`
   § "Doku-Delta").
   Conventional Commits der Commit-Messages mitbewerten; den Default-Branch aus dem PR-Objekt
   lesen, nicht `master`/`main` annehmen.

4. **Freigabe-Gate (vor jeder Veroeffentlichung).** **Zuerst lesen und quittieren:**
   [`reference/report.md`](reference/report.md) — Stufe A, Stufe B, die Widget-Befuellung, die
   beiden Invarianten und die Zeilen-Datei der Runde. **Dann den Review-Head festhalten**, nach dem
   Holen des Heads und vor Bericht und Freigabe-Bitte, mit einem eigenen Befehl — der Hook
   `require-rule-read.sh` liest diese Zeile, genau in dieser Form (voller 40-stelliger SHA):

   ```bash
   echo "review-head | <owner>/<repo>#<n> | $(gh api repos/<owner>/<repo>/pulls/<n> --jq .head.sha)"
   ```

   Ohne `gh`: den vollen Head-SHA aus `pull_request_read` (method=`get`) in derselben Zeilenform
   ausgeben. Bewegt sich der Head, wird die Zeile neu ausgegeben. Posten soll nur die Session, die
   die Freigabe empfangen hat; ein Sub-Agent bekommt sie nicht zu sehen. Dann: zweistufig — erst
   lesbarer Chat-Report, dann erst die Freigabe. Nie direkt in die Freigabe springen. **Das Widget gibt es
   nur im claude.ai-Chat mit dem Maintainer.** Dort wird die VORLAGE-Zone, die Stufe B 1:1
   uebernimmt, aus dem Playbook geholt — ueber die Contents-API, nicht ueber eine Raw-URL (das Repo
   ist privat):
   `gh api repos/ww3d/playbook/contents/.claude/skills/pr-poll-review/reference/widget-reference.html -H "Accept: application/vnd.github.raw"`
   (oder ohne den Header `--jq .content` und das Base64 dekodieren) bzw. `get_file_contents` (owner
   `ww3d`, repo `playbook`, gleicher Pfad). In Claude Code gibt es
   keinen Widget-Host und keine Datei im Consumer-Repo; dort traegt der Text-Pfad die Freigabe
   allein. Im Controller-Modus ist der Controller der Adressat, ohne Widget (Kernprinzip
   "Freigabe-Gate"). Gepostet wird erst nach der Freigabe des Adressaten — ausser in der
   sauberen Runde, die keine braucht (`.agents/rules/pr.md` § "Round Ledger"); der Hook prueft
   sie nicht, der Reviewer wartet auf sie und prueft ihren Absender (`.agents/rules/review.md`
   § "Review Comments").

5. **Zeilen-Datei der Runde** schreiben und pruefen, bevor gepostet wird — wie sie zum PR kommt,
   steht in `.agents/rules/pr.md` § "Round Ledger"; Ort, Status je Ausgang und Pruefung:
   `reference/report.md` § "Zeilen-Datei der Runde".

6. **Review-Head pruefen**, direkt vor dem Posten: den Head erneut holen. Nur wenn er sich seit
   Schritt 4 bewegt hat, kommt die Zeile neu, und der Post braucht eine neue Freigabe nach ihr. Der
   Hook sperrt den Post ausserdem, solange `reference/checks.md` und `reference/gates.md` in dieser
   Session nicht vollstaendig gelesen sind — der Read selbst zaehlt, die
   Quittungszeile ist zweite Quelle.

7. **Review posten** via `gh api` auf den Reviews-Endpunkt bzw. `pull_request_review_write` (nur
   freigegebene + custom Punkte + entschiedene Fragen):
   - `event`: `REQUEST_CHANGES` wenn ein blockierender Punkt dabei ist, sonst `COMMENT` — ausser im
     Fall "Approve mit offenen Vorschlaegen" unten. Ein Review
     aus lauter Nits ist nie `REQUEST_CHANGES`. Bei gleichem Account immer `COMMENT`, mit
     ausdruecklichem Blocking-Vermerk im Body — GitHub lehnt Request Changes am eigenen PR ab.
   - **Approve mit offenen Vorschlaegen:** blockiert kein Punkt, traegt jeder aendernde einen
     `suggestion`-Block und haelt das Hard-Gate aus Phase 4, geht `APPROVE` mit den Blocks als
     Inline-Kommentaren in **einem** Review-Event, der Body mit der Zeile `Review-Verdict: approve
     <head-sha>`; im Gleiches-Konto-Fall dasselbe als `COMMENT` (`.agents/rules/review.md`
     § "Review Comments"). Das Einspielen danach kostet keine Runde; das Merge-Gate prueft es.
   - Inline-Comments mit `path` + `line` bevorzugen, jeder mit dem Label als Prefix (`issue:
     (blocking)` …); Body mit knapper, nach Blocking-Wirkung geordneter Zusammenfassung **plus
     expliziter Aufforderung an den Author, nach dem Fix zurueckzumelden**.
   - **Jeder `nitpick:` geht als Suggested Change**, und eine entschiedene offene Frage geht
     als Anweisung an den Author statt als Frage. Beide Formen:
     [`reference/report.md`](reference/report.md).

8. Den Lifecycle-Trigger setzen: bei `REQUEST_CHANGES` den Autor anstossen; den Entwurfs-Schalter
   stellt nur der Autor (`.agents/rules/pr.md` § "PR Lifecycle", Schritt 6). HEAD-SHA des
   aktuellen Stands merken (`reviewed_sha`); Thread-IDs der eigenen Inline-Comments notieren (fuer
   spaeteres Resolve).

## Phase 2: Auf Aenderungen warten

Neu reviewt wird erst der Head, an dem der PR wieder bereit ist; ein Push auf den Entwurf ist noch
kein Stand zum Reviewen.

- **Im Controller-Modus:** auf `#N Head <sha> bereit` der Dev-Session warten (Kernprinzip
  "Review-Schleife"); bleibt es aus, gilt `.agents/rules/pr.md` § "Session Traffic" (Questions and
  Follow-Up).
- **Bevorzugt (Claude Code Web/Remote):** `subscribe_pr_activity` aufrufen und den Turn beenden.
  Neue Pushes und Kommentare kommen als `[github-webhook-activity]`-Events zurueck; je Event Head
  und Entwurfs-Zustand nachladen wie im Fallback. **Nicht** mit `sleep` aktiv pollen.
- Der Text eines Weckers (`ScheduleWakeup`, `/loop`) nennt den Schritt, auf den gewartet wird, und
  was danach zu tun ist, nie die Startzeile des Skills; ein Hintergrund-Lauf meldet sein Ende
  selbst, der Wecker ist nur Rueckfall.
- **Fallback (ohne Webhooks):** alle `poll_interval` Sekunden Head und Entwurfs-Zustand abfragen
  (`gh api repos/<repo>/pulls/<n> --jq '{sha: .head.sha, draft: .draft}'` bzw. `pull_request_read`,
  method=`get`), bis der Head von `reviewed_sha` abweicht und der PR nicht Entwurf ist, oder
  `max_iterations` / `timeout_minutes` erreicht sind. Transiente API-Fehler tolerieren.

Webhooks liefern CI-Erfolg, neue Pushes und Merge-Konflikt-Uebergaenge nicht zuverlaessig — bei
Unsicherheit den PR-Zustand aktiv nachladen.

## Phase 3: Re-Review

1. **Erst den Beweis pruefen**, im Checkout nach `git fetch origin <default-branch> <head-branch>`
   (das Skript braucht `reviewed_sha`, den neuen Head und den Basis-Head):
   `pwsh scripts/common/test-pure-catch-up.ps1 -Reviewed <reviewed_sha> -Head <head_sha> -Base origin/<default-branch>`;
   kam das Verdikt mit offenen Vorschlaegen, stattdessen
   `pwsh scripts/common/test-applied-suggestions.ps1 -Repo <repo> -Pr <n> -Verdict <reviewed_sha> -Head <head_sha> -Base origin/<default-branch>`,
   das den Nachzug mit prueft; Reviews des PR-Autors zaehlen dort nie, im Gleiches-Konto-Fall fuehrt
   den Beweis darum das Merge-Gate (`test-merge-ready.ps1 -Repo <repo> -Pr <n> -SameAccount`,
   Pruefung `review-verdict`). `PURE` bzw. `PROVEN` heisst, seit `reviewed_sha` kam nur
   nachgezogener Basis-Branch, Zeilen-Dateien und — bei `PROVEN` — woertlich eingespielte Vorschlaege
   dieses Reviews dazu: keine neue Runde, ein Approve oder eine Zeile `Review-Verdict: approve <sha>`
   bleibt stehen, das Merge-Gate prueft den Beweis selbst (`.agents/rules/review.md` § "Review
   Comments"). Hatte die Runde davor noch blockierende Punkte, steht nichts, das bleiben koennte:
   dann weiter mit Schritt 2. Ebenso bei `NOT PURE`, `NOT PROVEN` und ohne Checkout oder pwsh.
2. Diff zwischen `reviewed_sha` und neuem `head_sha` holen.
3. Pro vorherigem Comment pruefen: Stelle geaendert? Punkt adressiert? Fuer jedes fruehere
   `issue:` dieselbe Suche wie im Bericht am neuen Head wiederholen; der Fix gilt erst, wenn sie
   keine Fundstelle der Fehlerart mehr findet (`reference/checks.md` § "Fehlerart je Befund").
   Zusaetzlich die Red-Flag-/Doku-Integritaets-/Doku-Delta-/Beyond-the-diff-Checks aus Phase 1 auf
   das neu Dazugekommene anwenden — ein Fix-Commit kann ein Decision-Log kaputt-pasten oder einen
   Beleg tot machen, der vorher stimmte.
4. Auswertung (nach Blocking-Wirkung):
   - **Alle blockierenden adressiert, keine neuen** → Phase 4. Nicht blockierende Punkte mit
     `suggestion`-Block halten das Approve nicht auf, auch im Controller-Modus: sie gehen mit ihm
     (Phase 1, Schritt 7), der Autor spielt sie danach woertlich oder gar nicht ein
     (`.agents/rules/pr.md` § "Controller Mode"). Ein aendernder Punkt ohne Block haelt es auf.
   - **Rest- oder Neu-Punkte** → sammeln → **Freigabe-Gate, Zeilen-Datei, Review-Head (Phase 1,
     Schritte 4-6)** → posten → **die in dieser Runde adressierten Threads sofort resolven**
     (`resolve_thread` mit `threadId=PRRT_...`; mit `gh` die Mutation `resolveReviewThread` per
     `gh api graphql` — warum, steht in `.agents/rules/pr.md` § "Forge Tooling") → `reviewed_sha`
     aktualisieren, zurueck zu Phase 2.

**Resolven passiert in jeder Runde, nicht erst am Ende** — wer bis Phase 4 wartet, laesst den Author
raten, was schon erledigt ist, und haengt die Restpunkte in einer Wand alter Threads.

## Phase 4: Resolve + Abschluss

[HARD-GATE]
Vor jedem **positiven Abschluss-Verdikt**, ausnahmslos — jeder Punkt muss erfuellt sein.

**Zuerst lesen und quittieren:** [`reference/gates.md`](reference/gates.md) — was ein
positives Abschluss-Verdikt ueberhaupt ist, die Kasuistik zu den Punkten 4, 5 und 7, die
STOP-Tabelle und die Gegenpruefung. Ohne diesen Lauf faellt das Verdikt nicht.

1. **Laufzeile statt CI-Status.** CI zaehlt als tot (`.agents/rules/pr.md` § "CI Counts as Dead
   Org-Wide"); es zaehlt die Laufzeile unter "How tested", die `.agents/rules/pr.md` § "Test Runs"
   fuer diesen Diff verlangt — dort auch die Faelle ohne vollen Lauf oder ohne Laufzeile. Fehlt die
   verlangte Zeile, **nicht** approven. Was der Reviewer selbst faehrt, steht ebenda; er nennt seine
   gefilterten Tests und Mutationsproben im Review-Body.
2. Keine Merge-Konflikte — bei `mergeable`/`mergeable_state` nicht clean **nicht** approven,
   Status melden. (`blocked` = pending Required-Review, **kein** Konflikt — haelt nichts auf;
   ebenso `behind`: ein reiner Nachzug danach kostet keine Runde, Phase 3 Schritt 1.)
3. Kein CI-Gaming — wurden Tests/Coverage/Trigger manipuliert, um gruen zu werden, **nicht**
   approven, unabhaengig vom CI-Signal.
4. **Eigene Threads nach Blocking-Wirkung — Vorbedingung des Schreibens, keine Nachpruefung.** Erst
   resolven, dann schreiben: die Review-Kommentare frisch abrufen (`get_review_comments` bzw.
   `gh api`), die **selbst eroeffneten** Threads durchgehen, jeden am Head adressierten Punkt jetzt
   resolven. Wie im Einzelfall gerechnet wird: `reference/gates.md`.
5. **Anker-Issue, Auto-Close-Zeile und Tracking Issue — eine Pruefung, am Head.**
   - **Nennt der Body sein Anker-Issue ueberhaupt — mit `Closes` oder mit `Refs`?** Fehlt beides,
     ist das ein eigener `issue: (blocking)` (`.agents/rules/pr.md` § "PR / MR Description") —
     ausser beim PR aus Auftragstext ohne Issue, der sein eigener Anker ist (`.agents/rules/pr.md`
     § "Task Spec").
   - **Auto-Close-Zeile:** geprueft wird die **Zeile**, nicht das Vorkommen — eine eigene Zeile,
     Schliess-Keyword am Zeilenanfang, mit Nummer. Fehlt sie, wo das Ziel keinen offenen Punkt
     mehr hat — **nicht** approven (blocken, oder vom Merger per Skript schliessen lassen).
   - **Existiert das Tracking Issue des Designs und ist es offen?** · **Stehen die in diesem PR
     zurueckgestellten Punkte in seinem Body — und ist keiner davon ein verschobener Fix
     (`find-moved-fixes.ps1` am Head: null `moved-fix`)?** · **Zeigt eine Auto-Close-Zeile auf ein
     Issue mit Checkliste, waehrend in dessen ganzem Body noch ein offener Punkt steht?** Gerechnet
     wird gegen die Zeile, nie gegen ein Vorkommen im Fliesstext.
   - **Ergebnis muss null ungetragene Punkte sein** — sonst **nicht approven**. Keywords, Ausnahme
     fuer ein Issue mit offener Checkliste, was als zurueckgestellt zaehlt, und die vierte Frage:
     `reference/gates.md`.
6. Zwei getrennte Verdikte, beide gruen: **Spec** (tut der Diff genau das Bestellte, nichts zu
   viel/zu wenig?) und **Quality** (handwerklich sauber: Tests, Struktur, keine Magic Numbers?).
7. Beleg-Pflicht — behauptet der PR-Body **etwas, das der Reviewer nicht im Diff sieht**
   (Testlauf, Benchmark, "verifiziert") ohne stabilen Anker, **nicht** approven (blockt,
   analog zum Auto-Close-Zeilen-Check aus Punkt 5). Welcher Anker zaehlt: `reference/gates.md`.
[/HARD-GATE]

Wenn sauber (keine neuen Punkte), ohne Freigabe (`.agents/rules/pr.md` § "Round Ledger"); vor
jedem Post laeuft der Review-Head (Phase 1, Schritt 6), die eigenen Threads sind hier bereits
aufgeloest (Punkt 4), fremde bleiben unberuehrt:

- **Im Controller-Modus** sofort `APPROVE` (Lifecycle-Schritt 7), ohne Zusatzrunde. Der Body
  traegt Kurzfassung, Laeufe, die Zeilen-Datei als `jsonl`-Block mit Dateinamen und die eigene
  Zeile `Review-Verdict: approve <head-sha>` — Pflicht: der Ruleset verwirft das Approve, sobald
  die Zeilen-Datei gepusht wird, die Zeile im Body bleibt, und das Merge-Gate liest sie. Die
  Zeilen-Datei pusht der Controller allein und direkt vor dem Merge. Danach `#N approved <sha>`
  ohne Antwort an den Controller, als Abgabe.
- **Ohne Controller** zuerst Report und Zeilen-Datei als Kommentar-Review; hat der Dev die
  Zeilen-Datei committet, laeuft der Skill am neuen Head erneut, und das `APPROVE` mit knappem
  Body braucht keine neue Freigabe, solange der Head gegenueber dem geprueften nur die Zeilen-Datei
  hinzufuegt oder bewiesen nur nachzieht (Phase 3, Schritt 1) — sonst Report und Freigabe neu.
  Auch dieses Approve traegt die Zeile `Review-Verdict: approve <head-sha>`
  (`.agents/rules/review.md` § "Review Comments").

- **Mit offenen Vorschlaegen:** bleiben nur nicht blockierende Punkte, jeder aendernde mit
  `suggestion`-Block, ist die Runde nicht sauber, endet aber positiv: Freigabe, Zeilen-Datei und
  Review-Head wie Phase 1, Schritte 4-6, dann das Approve mit den Blocks in einem Review-Event
  (Phase 1, Schritt 7). Der Body nennt je Vorschlag `beruehrt Code: ja/nein`
  (`reference/report.md` § "Suggested Change als Postform"); im Controller-Modus folgt
  `#N approved <sha>` wie oben.

Eine Runde mit blockierenden Funden bleibt beim Weg ueber den Dev (Phase 1, Schritte 4-7). Bei einem
self-authored PR sperrt GitHub `APPROVE`, dann `event: COMMENT` mit der eigenen Zeile
`Review-Verdict: approve <head-sha>`, die das Merge-Gate liest (die alte Form `Review-Verdikt:`
liest es bis Playbook 26.0.0). Lag der Bericht im Web auf `review/<N>-report`, loescht der
Reviewer diesen Branch nach dem Approve
(`gh api -X DELETE repos/<repo>/git/refs/heads/review/<N>-report`).

**Ohne Controller** setzt der Skill mit dem Approve bzw. der Verdikt-Zeile das Tracking Issue auf
`state:gate` und nimmt `state:review` ab (`.agents/rules/pr.md` § "State Labels";
`gh api repos/<repo>/issues/<N>/labels -f "labels[]=state:gate"`,
`gh api -X DELETE repos/<repo>/issues/<N>/labels/state:review`; Connector: erst die Labels lesen,
dann mit `issue_write` die volle Liste schicken, denn `issue_write` ersetzt sie — `controller-mode`
Schritt 4); im Controller-Modus setzt es der Controller.

Den Nutzer informieren, die Nummer als Link: "owner/repo#N (Titel) abgeschlossen. Merge **nicht**
ausgefuehrt — wer merged, faehrt vorher `scripts/common/test-merge-ready.ps1` und schliesst danach
das Tracking Issue mit `scripts/common/close-tracking-issue.ps1` (`.agents/rules/pr.md` § "Merge")."

## Phase 5: Funktionale Zusammenfassung

Nach dem Abschluss-Verdikt im **Chat** liefern — im Controller-Modus als Abschnitt im Body des
Approves, denn der Controller prueft am PR, und die Abgabe am Ende traegt nur den Link
(`.agents/rules/pr.md` § "Session Traffic"):

- Vorher/Nachher-Zustand
- Happy Path
- Edge Cases
- Was bewusst unberuehrt bleibt
- Architektonischer Beitrag

**Damit endet der Skill.** Er wartet nicht auf den Merge; was nach dem Merge zu tun ist und warum
es beim Merger liegt: [`reference/gates.md`](reference/gates.md) § "Nach dem Merge".

## Strikte Regeln

Nur was nirgends sonst in dieser Datei oder in `reference/` steht:

- **Das Widget wird, wo ein Mensch im claude.ai-Chat der Adressat ist, immer inline gerendert**
  (Visualizer/`show_widget`) — in Claude Code und im Controller-Modus gibt es keins; nie als
  Datei-Anhang, nie als Code-Block, nie als Beschreibung dessen, was es enthielte. Die
  VORLAGE-Zone rechnet mit den Host-Variablen; ausserhalb des Hosts ist sie ungestyltes Markup und
  damit wertlos. Aufwand ist kein Grund, den Kanal zu wechseln.
- **Nie einen Thread resolven, dessen Punkt noch aussteht.**
- Rotationsmarke des Reviews: Art review in `.agents/session-kinds.json`; Uebergabe als PR-Kommentar nach `.agents/rules/pr.md` § "Controller Sessions".
- **Niemals** einen PR im Review schliessen/wieder oeffnen. Dieser Skill merged nie — wer merged,
  regeln `.agents/rules/pr.md` § "PR Lifecycle" und § "Controller Mode".
- Bei Force-Push oder Branch-Reset: Loop pausieren, beim Nutzer nachfragen.
- Spiegeln von Antworten zwischen Chat und GitHub-Thread: `.agents/rules/pr.md` § "Mirroring GitHub
  Conversations".

## Repo-Konventionen

- Falls via MCP gereviewt wird: Inline-Comments in drei Schritten — `create` (pending) →
  `add_comment_to_pending_review` → `submit_pending` (`event: COMMENT`/`REQUEST_CHANGES`); sonst
  scheitert der Inline-Review still. Bei `gh` entfaellt das.
- Bei Backport-relevanten Punkten pruefen, ob im betroffenen Upstream-/Nachbar-Repo ein
  Tracking-Issue vorliegt.
