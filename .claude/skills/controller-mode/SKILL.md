---
name: controller-mode
description: 'Steuernde Session fuer ein Repo: /controller-mode [repo] [lite]. Liest den Stand, prueft Sessions und PRs mit festen Fragen, startet Design-, Dev- und Review-Sessions per Skill-Zeile, raeumt fertige ab, merged nach dem Merge-Gate. lite: Design und Review laufen mit dem Maintainer im Fenster. Triggert bei "/controller-mode", "controller mode", "controller-modus". Nur fuer GitHub-Repos.'
metadata:
  version: "2.7.0"
  source: ww3d/playbook
  checksum: "sha256:ce6147a91322293889dc8525ade2000a4523ecddd402ea6b69a8aad8f35447f7"
  # Written by ./scripts/check-skill-budget.ps1 -UpdateMeasurement, which needs an
  # ANTHROPIC_API_KEY; every later run recomputes the value and reports drift. Empty means no
  # real measurement has run yet - an invented number would be the false green this gate is against.
  measurement:
    tokens:
    model:
    measured:
    source: "not measured - no ANTHROPIC_API_KEY in the build environment of ww3d/playbook#351"
---

# Controller-Modus

Der Ablauf der steuernden Session. Die Regeln stehen in `.agents/rules/pr.md` § "Controller
Sessions", § "Controller Mode", § "Controller Lite", § "State Labels", § "Session Traffic" und
§ "Merge"; dieser Skill traegt den Ablauf und verweist dorthin. Der Skill liefert die Mechanik des
Sitzes, nie die Besetzung: wer ihn nicht ausdruecklich mit dieser Zeile bekommen hat, ist kein
Controller.

## Aufruf

`/controller-mode <owner/repo>` oder `/controller-mode <owner/repo> lite`. Die Zeile ersetzt die
fruehere Startzeile `Controller mode: <repo>.` samt Block. Was der Startauftrag ausser dieser Zeile
tragen darf und was ein Controller ohne eigenen Auftrag tut, regelt `.agents/rules/pr.md`
§ "Controller Mode": ohne Auftrag nur Schritt 0, dann warten; Schritt 1 und alles danach erst mit
dem Auftrag des Maintainers. Stehende Anordnungen des Maintainers liest er an ihrem Traeger — im
Body des Tracking Issues oder in der `CLAUDE.md` des Repos. Fehlt das Repo: **fragen**.

## Schritt 0: Eingang

1. Session-Start nach `AGENTS.md` § "Session Start: Read Before Anything Else", mit Blob-SHA
   quittiert; die Regeldateien nach `AGENTS.md` § "Rule Files" vor der ersten Aktion ihres Typs,
   fuer den Controller vor allem `pr` und `carrier`.
2. Konto pruefen und setzen nach `.agents/rules/pr.md` § "Accounts per Seat"; Modell nach
   `.agents/rules/agents.md` § "Models".

## Schritt 1: Stand lesen

Erst mit dem Auftrag des Maintainers (Abschnitt "Aufruf").

- Offene Tracking Issues (Label `tracking`) mit Body, ihre Zustands-Labels
  (`.agents/rules/pr.md` § "State Labels"), offene PRs mit Head, letzter Bewegung und "How
  tested" (`gh api "repos/<owner>/<repo>/issues?labels=tracking&state=open"` und
  `gh api "repos/<owner>/<repo>/pulls?state=open"`; Connector: `list_issues`,
  `list_pull_requests`).
- Laufende Sessions dieses Repos und ihren Auftrag, ueber das Zustell-Werkzeug der Operation. Als
  Nachfolger eines Controllers uebernimmt die Session dabei im Werkzeug die Sessions ihres
  Vorgaengers (Faehigkeit "Besitz umhaengen", `.agents/rules/pr.md` § "Session Traffic").
- Vor einer neuen Aufgabe "Finish before you start" halten (`.agents/rules/pr.md` § "Controller
  Sessions").

## Schritt 2: Status in fester Form

Jeder Status — an sich selbst, im Status-Kommentar des Tracking Issues, an den Maintainer — hat
diese vier Teile, in dieser Reihenfolge:

```text
Stand: <was gemergt, was im PR, was laeuft, je mit owner/repo#N>
Prio: <was zuerst, ein Satz warum>
Plan: <naechste Schritte, je Session/Skill-Zeile>
Offene Entscheidungen: <was der Maintainer entscheidet, sonst "keine">
```

Die Zeile "Offene Entscheidungen" folgt `.agents/rules/chat.md` § "Talking to the Maintainer" (letzter Punkt).

Wo der Status steht, regelt `.agents/rules/pr.md` § "Controller Sessions" (Status form).

## Schritt 3: Pruefen mit festen Fragen

Je Session und je PR, am PR und am Issue — nie auf eine Meldung warten:

1. **Fertig?** PR steht, der Head unter "How tested" ist der Head, Wellen des Modus belegt.
2. **Kreis?** Dreht sich die Session im Kreis (dieselbe Korrektur zweimal, kein neuer Commit)?
3. **Fortschritt?** Was hat sich seit dem letzten Blick bewegt?
4. **Naechster Schritt?** Wer ist dran, mit welcher Skill-Zeile?
5. **Auftrag?** Steht der Auftrag vollstaendig am Traeger, und tut der PR genau das?

Was eine Frage offenlegt, entscheidet der Controller nach `.agents/rules/code.md` § "Simplicity"; an den
Maintainer geht nur, was `.agents/rules/pr.md` § "Controller Mode" ihm vorbehaelt.

Der Text eines Weckers (`ScheduleWakeup`, `/loop`) nennt den Schritt, auf den gewartet wird, und
was danach zu tun ist, nie die Startzeile des Skills; ein Hintergrund-Lauf meldet sein Ende selbst,
der Wecker ist nur Rueckfall.

## Schritt 4: Steuern

Die Kette ist Design → Dev → Review, jede Session frisch, jede mit ihrer Skill-Zeile gestartet:

| Sitz | Startzeile |
|---|---|
| Controller | `/controller-mode <owner/repo>` oder `/controller-mode <owner/repo> lite` |
| Design | `/ccweb-prompt <owner/repo> #<N>` (oder die Aufgabe) |
| Dev | `/dev-task <owner/repo>#<N>` oder `/dev-task "<auftrag>"` |
| Review | `/pr-poll-review <owner/repo>#<PR>` |
| Audit | `/state-audit` im Ziel-Repo |

Diese Tabelle ist die eine Stelle fuer die Startzeilen aller Sitze; Regeln, Skills und Vorlagen
verweisen hierher.

- **Dev-Start mit Modell:** der Controller startet die Dev-Session mit dem Modell aus der Spec-Zeile
  `Dev-Model:` (aeltere Specs: `Dev-Modell:`) und bestaetigt oder ueberstimmt es nach `.agents/rules/agents.md` § "Models".

**Ablauf eines Auftrags**, Phase fuer Phase; Nachrichten kurz und ohne Inhalt, alles Inhaltliche
steht an Issue und PR (`.agents/rules/pr.md` § "Session Traffic"):

1. **Design:** frische Session (Startzeile des Sitzes) mit dem Auftrag des Maintainers woertlich im
   Start. Fragt sie, weil der volle Audit faellig ist, startet der Controller eine frische Session
   (Zeile "Audit"); ihr Ergebnis `docs/audit/state-*.md` kommt als kleiner eigener Durchlauf ins
   Repo — PR, Review (Phase 3), Merge (Schritt 5) —, bevor das Design weiterlaeuft. Abgabe: Link am
   Tracking Issue.
2. **Dev:** frische Session (Zeile "Dev"); ihre Abgabe `#N Head <sha> bereit` an den Controller
   startet Phase 3, die Session laeuft weiter.
3. **Review-Schleife:** frische Session (Zeile "Review"); der Reviewer bekommt im Start den Namen
   der Dev-Session, die Dev-Session den des Reviewers als Hinweis (`.agents/rules/pr.md`
   § "Session Traffic", Punkt 7). Den Bericht prueft der Controller und gibt ihn frei; Punkte der
   Liste fuer den Maintainer (`.agents/rules/pr.md` § "Controller Mode") gehen vorher an
   ihn. Danach laufen Dev und Reviewer untereinander (`.agents/rules/pr.md` § "Session Traffic",
   Punkt 8), bis der Reviewer `#N approved <sha>` meldet.
4. **Vor dem Merge, gleichzeitig:** wo der Controller es je PR will, der zweite Blick der
   Design-Session (`ccweb-prompt` § "Zweiter Blick", Anstoss als Hinweis), ihre Funde als neue Runde
   in Phase 3; und je Plattform aus `**Full run:**` der `CLAUDE.md`, die der Dev-Lauf nicht hat, ein
   voller Lauf gleichzeitig (Linux in einer Web-Session, Windows lokal) — die Dev-Session startet ihn
   als eigene Session und traegt die Laufzeile ein.
5. **Merge:** Schritt 5 unten; danach alle Sessions des Auftrags nach Pruefung ihrer Klone (nichts
   Ungepushtes) beenden und abraeumen.

Meldet eine arbeitende Session "Rotation ready" mit dem Link auf ihre Uebergabe und dem Namen ihres
Nachfolgers, den sie selbst gestartet hat (`.agents/rules/pr.md` § "Controller Sessions"), nennt der
Controller in der Review-Schleife der Gegenseite den neuen Namen (Hinweis); die alte beendet ihr
Nachfolger, nicht der Controller.
Zustands-Labels setzt er bei jedem Uebergang (unten).

Die Regeln dazu — eine Dev-Session je Aufgabe, Abraeumen erst nach Abgabe, Wiederanlauf nur nach
Absturz, Schutzvermerke, Weitergabe von Anordnungen, Fragen an den Maintainer — stehen in
`.agents/rules/pr.md` § "Controller Sessions", die erlaubten Nachrichten — die Abgabe am Ende jeder
Session eingeschlossen — in § "Session Traffic", ausbleibende Antworten dort unter "Questions and
Follow-Up", Auftraege am Besitzer vorbei, auch vom Maintainer direkt, unter "Orders and Rank", ein
Nachtrag des Maintainers zu einem laufenden PR in § "Controller Mode". Der Ablauf:

- **Review-Freigabe:** den Bericht des Review-Workers liest der Controller als dessen Adressat und
  schickt die Freigabe zurueck (`.agents/rules/pr.md` § "Session Traffic", Punkt 3).
- **Abraeumen:** vor dem Beenden die Liste der Session am Traeger bestaetigen (`.agents/rules/pr.md`
  § "Controller Sessions"), dann mit dem Zustell-Werkzeug beenden und abraeumen — die
  Design-Session, sobald Branch und Link am Issue stehen und kein zweiter Blick (Phase 4) mehr
  kommt, die Review-Session, sobald ihr Approve oder ihre Zeile `Review-Verdict: approve <sha>` zum
  Head am PR steht und kein zweiter Blick mehr kommt, dessen Funde sie als neue Runde braucht
  (`.agents/rules/pr.md` § "Controller Sessions"). Ein Befund raeumt sie nicht ab; wie es dann
  weitergeht, regelt `.agents/rules/pr.md` § "Round Ledger".
- **Zeilen-Datei der Review-Runde:** in einer Runde mit Funden committet sie der Dev; ist die
  Dev-Session des PRs schon weg, startet der Controller eine frische (Zeile "Dev", mit dem Tracking
  Issue des PRs), die auf dem offenen PR weiterarbeitet (`dev-task` Schritt 4). Die Zeilen-Datei der
  sauberen Runde pusht der Controller selbst, direkt vor dem Merge (Schritt 5).
- **Zustands-Labels** (`.agents/rules/pr.md` § "State Labels") setzt der Controller bei jedem
  Uebergang, das alte nimmt er ab: Design laeuft → `state:design` (setzt die Design-Session selbst,
  die Ausnahme in `.agents/rules/pr.md` § "State Labels"); Dev-Session gestartet → `state:dev`; PR
  auf ready → `state:review`; Approve bzw. Verdikt-Zeile → `state:gate`; Merge-Gate gruen →
  `state:merge-ready`; Frage oder Sichtabnahme beim Maintainer → `state:human`; ein Release laeuft →
  `state:release`.
  Per REST `gh api repos/<owner>/<repo>/issues/<N>/labels -f "labels[]=<neu>"` und
  `gh api -X DELETE repos/<owner>/<repo>/issues/<N>/labels/<alt>`. Ueber den Connector erst die
  vorhandenen Labels lesen (`issue_read`), dann mit `issue_write` die volle neue Liste schicken —
  `issue_write` ersetzt die Liste, ein einzelnes Label darin loescht alle anderen. Wer ohne
  Controller welches Label setzt, regelt `.agents/rules/pr.md` § "State Labels".
- **Aufraeum-Auftrag:** Issues, PRs, Branches und Sessions mit "DO NOT CLOSE" / "DO NOT MERGE" oder
  einem Entscheid des Maintainers daran einzeln als unantastbar nennen.
- **Fragen an den Maintainer** nach `.agents/rules/pr.md` § "Controller Sessions".
- Das Zustell-Werkzeug und seine Faehigkeiten nennt `.agents/rules/pr.md` § "Session Traffic";
  welcher Befehl wozu gehoert, ist Sache der Operation.

## Schritt 5: Merge

Nach `.agents/rules/pr.md` § "Merge":

Zuerst, wo das Approve einer sauberen Runde eine Zeilen-Datei im Body traegt: sie aus dem
`jsonl`-Block unter dem genannten Dateinamen auf den PR-Branch legen, als eigenen Commit nur mit
dieser Datei (Form: `.claude/skills/pr-poll-review/reference/report.md` § "Zeilen-Datei der
Runde"), `pwsh scripts/common/test-ledger.ps1 -Path <datei>` gruen, pushen — kein Dev-Schritt
(`.agents/rules/pr.md` § "Round Ledger"). Danach kommt nichts mehr auf den Branch.

1. Merge-Gate: `pwsh scripts/common/test-merge-ready.ps1 -Repo <owner/repo> -Pr <n>`; reviewt dasselbe
   Konto, das den PR schrieb (Gleiches-Konto-Fall, `.agents/rules/pr.md` § "Accounts per Seat"), kommt
   `-SameAccount` dazu — nur dann zaehlt dessen Verdikt-Zeile im Review. Ohne pwsh von
   Hand: die Laufzeilen gegen den Merge-Head halten
   (`gh api repos/<owner>/<repo>/pulls/<n> --jq .head.sha`), wie `.agents/rules/pr.md` § "Merge"
   das Gate beschreibt, und pruefen, dass ein Approve eines anderen Kontos oder die Zeile
   `Review-Verdict: approve <sha>` (im Gleiches-Konto-Fall das Kommentar-Review nach
   `.agents/rules/pr.md` § "Accounts per Seat") zum Head vorliegt — oder zu einem Commit, nach dem
   nur Zeilen-Datei-Commits folgen. Ein bewiesener Nachzug der Basis laesst ein aelteres Verdikt nur
   mit pwsh gelten (`scripts/common/test-pure-catch-up.ps1`); von Hand zaehlt er nicht. Ebenso
   Vorschlaege, die der Dev nach einem Approve mit offenen Blocks woertlich eingespielt hat: das Gate
   beweist sie mit `scripts/common/test-applied-suggestions.ps1` und nennt je Vorschlag angewandt
   oder weggelassen; von Hand zaehlen sie nicht. Die Lauf-Pruefungen bleiben. Ein `#N Head <sha>
   bereit` nach einem solchen Approve fuehrt hierher, nicht in eine neue Review-Runde; die Threads
   der Vorschlaege resolvt die Dev-Session (`dev-task`), fehlt sie, eine frische fuer den PR — wie fuer
   die Zeilen-Datei (`.agents/rules/pr.md` § "Round Ledger").
2. Traegt das Tracking Issue die Zeile `Visual acceptance: <what>` (`.agents/rules/pr.md` § "Merge"):
   erst nach dem `Visual acceptance OK` des Maintainers zum aktuellen Head.
3. Vor dem Merge, bei `state:merge-ready`, bekommt der Maintainer im Tracking Issue eine
   Kurzanleitung:

   ```text
   Was neu: <ein bis drei Saetze>
   Warum: <Anlass, owner/repo#N>
   Wo: <Dateien, Befehle, Oberflaechen>
   Testen: <Befehle zum Nachpruefen>
   ```

4. Mergen, dann `pwsh scripts/common/close-tracking-issue.ps1 -Repo <owner/repo> -Pr <n>` fuer den
   gemergten PR — schliesst nur, was schliessbar ist, sonst sagt es, warum es offen bleibt. Den
   Ablauf samt Rueckfall ohne Skript beschreibt
   `.claude/skills/pr-poll-review/reference/gates.md` § "Nach dem Merge";
   ihn vor dem ersten Merge der Session lesen.

## Schritt 6: Rotation und Neustart

Grenze und Neustart regelt `.agents/rules/pr.md` § "Controller Sessions" mit den Werten aus
`.agents/session-kinds.json` (Art controller). Der Ablauf:

- Hat die Art eine Marke (`rotateAt`), den laufenden kleinen Block fertig machen oder sauber
  schneiden; ohne Marke verdichtet die Session bei ihrem `autoCompactWindow` und schneidet nicht.
  Alles Offene vorher an den Traeger (`.agents/rules/session.md` § "Session End: Carry What Is Still Open").
- Zum Schluss startet die geschnittene Session ihren Nachfolger selbst — dieselbe Zeile
  `/controller-mode <owner/repo> [lite]`, unter demselben Besitzer, wo es einen gibt —, nennt
  ihn im Abschnitt `## Hand-back` im Body des Tracking Issues (mit der Check-Zeile aus
  `chat-handoff`, Schritt 2) und schickt die Abgabe "Rotation ready" mit dem Link und seinem Namen
  (`.agents/rules/pr.md` § "Controller Sessions", § "Session Traffic", Punkt 2).
- Vor einem geplanten Neustart jede Session, die er trifft, ihren Stand als WIP auf ihren Branch
  pushen lassen.
- Der Nachfolger liest den Stand selbst und beendet den Vorgaenger, sobald er den Sitz haelt
  (`.agents/rules/pr.md` § "Controller Sessions"); was dabei als sein Auftrag gilt, regelt
  `.agents/rules/pr.md` § "Controller Mode". Ein Handoff nur, wo sonst Stand verloren ginge (Skill
  `chat-handoff`).

## lite

`/controller-mode <owner/repo> lite` (`.agents/rules/pr.md` § "Controller Lite"): Design- und
Review-Sessions laufen mit dem Maintainer im Fenster, jede Re-Review-Runde ebenso. Der Controller
startet die Dev-Session, prueft (Schritt 3) und merged (Schritt 5). Alles andere gilt unveraendert.
