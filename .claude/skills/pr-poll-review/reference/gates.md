# pr-poll-review — Gate-Kasuistik (Phase 4 und nach dem Merge)

## Inhalt

- [Was ein positives Abschluss-Verdikt ist](#was-ein-positives-abschluss-verdikt-ist)
- [Hard-Gate Punkt 4 — eigene Threads](#hard-gate-punkt-4--eigene-threads)
- [Hard-Gate Punkt 5 — Form der Auto-Close-Zeile](#hard-gate-punkt-5--form-der-auto-close-zeile)
- [Hard-Gate Punkt 5 — Vorkommen, Umkehrung, Ausnahme](#hard-gate-punkt-5--vorkommen-umkehrung-ausnahme)
- [Hard-Gate Punkt 5 — was zurueckgestellt zaehlt](#hard-gate-punkt-5--was-zurueckgestellt-zaehlt)
- [Hard-Gate Punkt 5 — ganzer Body, vierte Frage](#hard-gate-punkt-5--ganzer-body-vierte-frage)
- [Hard-Gate Punkt 7 — welcher Anker zaehlt](#hard-gate-punkt-7--welcher-anker-zaehlt)
- [Diese Gedanken bedeuten STOP — du rationalisierst](#diese-gedanken-bedeuten-stop--du-rationalisierst)
- [Gegenpruefung des Hard-Gates — Empfehlung, keine Pflicht](#gegenpruefung-des-hard-gates--empfehlung-keine-pflicht)
- [Nach dem Merge](#nach-dem-merge)
- [Nach dem Merge — wenn das Skript `SOURCE UNAVAILABLE` meldet](#nach-dem-merge--wenn-das-skript-source-unavailable-meldet)

Die Kasuistik des Gates — die Faelle, an denen frueher etwas durchgerutscht ist — und was nach dem
Merge zu tun ist. Das Gate selbst steht als Regel-Kurzform in der `SKILL.md`; hier steht, wie seine
Punkte im Einzelfall zu rechnen sind.

## Was ein positives Abschluss-Verdikt ist

**Positives Abschluss-Verdikt** heisst: jede Aussage, die den PR als fertig, sauber, passend,
approve-faehig oder mergebar bezeichnet — auch relativiert („aus meiner Sicht", „im Grunde", „bis
auf Kleinigkeiten"). **Kanal egal:** `APPROVE`-Event, `COMMENT`-Review, Issue-Kommentar, Satz im
Chat sagen dem, der merged, alle „du kannst mergen" und binden dieses Gate, auch wo GitHub keins
zulaesst; „nicht approven" unten heisst dasselbe. **Nicht** gebunden: Zwischenverdikte `Blockiert` /
`Approvebar nach Fixes` — dort sind die Threads der Grund.

## Hard-Gate Punkt 4 — eigene Threads

- **Die blockierenden Punkte muessen null sein** — `issue: (blocking)` und
  `question: (blocking)`. Ein offener eigener Thread dieser Art haelt das
  Verdikt auf; das Verdikt zu *formulieren*, bevor die Zaehlung null ergibt, ist selbst schon
  der Verstoss — nicht erst das Absenden.
- **Ein `nitpick:` haelt weder Verdikt noch Merge auf, solange er als `suggestion`-Block gepostet
  ist**, und braucht keinen Traeger; der Autor spielt ihn woertlich ein oder nicht. Ebenso eine
  `suggestion: (non-blocking)` mit Block. Offene Blocks duerfen mit dem Approve in einem
  Review-Event kommen (`.agents/rules/review.md` § "Review Comments"); ein aendernder nicht
  blockierender Punkt **ohne** Block haelt das Approve auf: er ist eine normale Runde.
- **Vor dem Merge ist auch der Nit-Thread resolved.** Das ist kein Gate dieses Skills, sondern
  Mechanik: `docs/common/ci.md` § "Ruleset fuer `main`" setzt "Require conversation resolution"
  in jedem ww3d-Repo, GitHub laesst sonst nicht mergen. Den Thread resolven der PR-Autor und jedes
  Konto mit Schreibrecht, nicht nur der Reviewer
  ([GitHub-Doku](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/commenting-on-a-pull-request)).
  Ein resolvter Thread beweist darum nichts: ob ein Vorschlag woertlich kam, beweist
  `scripts/common/test-applied-suggestions.ps1`, sonst jeden Thread am Head nachpruefen und einen
  zu frueh geschlossenen wieder oeffnen.
- Threads *anderer* Reviewer werden nie selbst resolved, aber im Verdikt benannt.

## Hard-Gate Punkt 5 — Form der Auto-Close-Zeile

Die Form ist in `.agents/rules/pr.md` § "PR / MR Description" definiert (das englische Keyword in
einer eigenen Zeile) und wird hier nur benutzt. Keywords sind `Closes` / `Fixes` /
`Resolves` und die uebrigen Formen derselben Verben, die GitHub ebenfalls parst
(`close`/`closed`, `fix`/`fixed`, `resolve`/`resolved`).

## Hard-Gate Punkt 5 — Vorkommen, Umkehrung, Ausnahme

- **Ein Vorkommen ist keine Zeile.** Im Fliesstext, in einem Zitat, in Backticks oder nach einer
  Verneinung zaehlt das Keyword weder als Anwesenheit noch als Abwesenheit. Eine Textsuche zaehlt
  Nennung und Anweisung gleich und laesst damit genau den Body durch, der erklaert, warum er kein
  Keyword setzt. Mechanisch pruefbar ist nur "steht dort eine Anweisung", nicht "kommt
  das Wort irgendwo vor".
- **Die Umkehrung gilt genauso.** Eine Auto-Close-Zeile bleibt eine, auch wenn der Body sie
  erkennbar nicht als Anweisung meint — der Parser liest die Form, nicht die Absicht. Der billige
  Vorlauf dazu — Skript fahren: `pwsh scripts/common/check-terminology.ps1 -BodyPath <datei>`; es
  meldet jedes Keyword-mit-Nummer, das **nicht** auf einer eigenen Zeile steht (`.agents/rules/pr.md`
  § "PR / MR Description"). Ohne Skript: den Body nach jedem Schliess-Keyword mit `#` und Nummer
  absuchen und je Treffer pruefen, ob er am Anfang einer eigenen Zeile steht. Das Skript sieht nur
  den Text, den man ihm uebergibt, und ersetzt dieses Gate nicht.
- **Eine Ausnahme, und nur diese:** das einzige in Frage kommende Ziel ist ein **Issue mit
  Checkliste** — mit oder ohne Label `tracking` —, in dessen Body noch eine unabgehakte Checkbox
  steht. Dann gehoert die Zeile nach `.agents/rules/carrier.md` § "Tracking Issue" ausdruecklich
  **nicht** in den Body, und ihr
  Fehlen ist korrekt statt ein Befund. Der Body nennt das Issue trotzdem, nur ohne Keyword;
  geschlossen wird nach dem Merge von dem, der merged, per Skript (§ "Nach dem Merge" unten).
- Zeigt die Auto-Close-Zeile auf ein Issue mit Checkliste, ist umgekehrt ihre blosse Anwesenheit
  nicht genug: die dritte Frage rechnet sie gegen dessen Body. Anwesenheit und Abwesenheit sind hier
  dieselbe Frage von zwei Seiten — sie wird einmal beantwortet, in Punkt 5.

## Hard-Gate Punkt 5 — was zurueckgestellt zaehlt

Zurueckgestellt sind: die Punkte unter „Open questions" /
„Observations" / „Deliberately not changed" des PR-Bodys (alte Ueberschriften „Offene Fragen" /
„Bewusst nicht" ebenso, bis Playbook 26.0.0) und jede eigene F-Nummer, die der User auf „offen
lassen" gesetzt hat. **Nicht** mitgezaehlt: ausdruecklich verworfene Punkte, jeder `nitpick:`,
und reine Umgebungsfeststellungen. Die gueltigen Orte stehen in `.agents/rules/carrier.md`
§ "Carrier Requirement".

Jeder zurueckgestellte Punkt wird zusaetzlich gefragt, **ob er baubar ist** — in diesem Repo
umsetzbar und ohne offene Entscheidung des Maintainers. Was baubar dann heisst (im selben PR oder
ein eigener PR), steht in `.agents/rules/carrier.md` § "Carrier Requirement"; ein eigener PR
traegt bis dahin die Zeile `**Own PR:** <owner/repo#N>`, und geprueft wird, dass `#N` ein offener
PR oder ein offenes Tracking Issue ist, das die Arbeit beauftragt — nie ein Session-Name. Mit
diesem Ziel ist es eine Reihenfolge, ohne es ein Aufschub. Nicht baubar ist er nur in einem
der drei Faelle aus `.agents/rules/carrier.md` § "Carrier Requirement", je mit seiner Form: Zeile
`**Foreign repo only:** <owner/repo#N>` mit offenem Fremd-Issue (und Meldung an den Maintainer),
Zeile `**No known fix:**` mit belegter Recherche samt Quellen, oder — bei offener Entscheidung —
keine Zeile, sondern eine Frage an den Maintainer bzw. Controller. Eine Traeger-Zeile, die nur
"ausserhalb des Scopes" als Grund hat, eine `**Own PR:**`-Zeile ohne offenes Ziel oder eine
liegende Zeile statt der Frage ist ein `issue: (blocking)`.

## Hard-Gate Punkt 5 — ganzer Body, vierte Frage

- **Die dritte Frage geht ueber den GANZEN Body, nicht ueber die Punkte dieses PRs.** Genau
  das war die Luecke: die Zaehlung aus Frage zwei kennt nur, was *dieser* PR zurueckstellt, und
  ein Punkt, der vorher schon drin stand, kommt darin nicht vor. Gelesen wird der Body am Head
  (`gh api repos/<repo>/issues/<n> --jq .body` bzw. `issue_read`), Zeile fuer Zeile: jede
  unabgehakte Checkbox zaehlt, egal aus welcher Runde sie stammt.
- **Offene Haken plus Auto-Close-Zeile = `issue: (blocking)`**, ohne Ermessen. Der Merge wuerde
  den Traeger schliessen, ohne irgendetwas zu pruefen, und ein geschlossener Traeger sieht aus
  wie ein erledigter (`.agents/rules/carrier.md` § "Tracking Issue", § "Carrier Requirement").
  Die Korrektur ist eindeutig und darum kein `question:`: entweder die offenen Punkte wandern
  vorher an einen anderen gueltigen Traeger, oder die Zeile faellt aus dem Body und der Merger
  schliesst per Skript.
- **Die dritte Frage gilt fuer jedes Issue mit Checkliste, auf das eine Auto-Close-Zeile zeigt**,
  mit oder ohne Label `tracking` — die Bedingung haengt an der Checkliste, nicht am Label und nicht
  am Keyword (`.agents/rules/carrier.md` § "Tracking Issue").
- **Vierte Frage: steht im Body noch ein Punkt offen, den dieser PR liefert?** Jede unabgehakte
  Checkbox gegen den Diff halten — ist sie gebaut, muss der PR sie im selben Zug abhaken
  (`.agents/rules/carrier.md` § "Tracking Issue"). Nicht abgehakt trotz geliefert → `issue:
  (blocking)`. Der "Backlog-Gegencheck (beide Richtungen)" aus Phase 1 Schritt 3 sagt inhaltlich
  dasselbe und hat nicht getragen: er steht als Fliesstext zwischen zehn anderen Checks, und was
  nicht im Gate steht, wird nicht abgearbeitet. Die Kosten des Durchrutschens traegt nicht dieser
  PR, sondern die naechste Design-Runde, die den Body liest und Gebautes erneut beauftragt.

## Hard-Gate Punkt 7 — welcher Anker zaehlt

Welcher Anker gilt und welcher nicht, steht einmal in `.agents/rules/evidence.md` § "Evidence
Requirement" (Kurzreferenz dort); das Gate selbst ist Punkt 7 im HARD-GATE von `SKILL.md`. **Was im
Diff steht, braucht keinen Anker** — und wird hier nicht geprueft.

## Diese Gedanken bedeuten STOP — du rationalisierst

| Gedanke | Realitaet |
|---|---|
| "Key-Files reichen, der Rest ist Boilerplate" | Zeile fuer Zeile, kein Sampling. |
| "Sieht fertig aus, den Auto-Close-Check kann ich sparen" | Erst Punkt 5, dann Urteil. |
| "Spec passt schon, muss den Diff nicht gegenpruefen" | Spec-Verdikt ist eigenstaendig. |
| "Tests sind gruen, also passt der Fix" | Hallucinated Correctness — kritischen Pfad tracen. |
| "Ich hab die Threads doch resolved" | Nachzaehlen, nicht erinnern — Review-Kommentare frisch abrufen, die blockierenden auf null. |
| "Die Zaehlung lief, aber ein offenes `issue: (blocking)` haelt das Fazit nicht auf" | Genau das haelt es auf — erst resolven, dann schreiben (Punkt 4). |
| "Der Punkt ist ausserhalb des Scopes, also blockt er" | Out-of-Scope blockt nicht — baubar folgt er `.agents/rules/carrier.md` § "Carrier Requirement", sonst einer der drei Faelle (Kernprinzip). |
| "Ausserhalb des Scopes, also ab in den Backlog" | Ausserhalb des Scopes ist kein Grund zum Tragen — baubar wird gebaut (Punkt 5). |
| "Perfekt ist er noch nicht, also noch keine Freigabe" | Freigabe-Standard ist "eindeutig besser", nicht "nichts mehr zu finden". |
| "Steht doch im PR-Body, damit ist es gemeldet" | Ein gemergter Body ist ein Archiv — Tracking-Issue-Frage in Punkt 5. |
| "Der Autor sagt, das laeuft woanders schon" | Am Head nachlesen; ein geschlossenes Issue traegt nichts. |
| "Die Zeile ist da, Auto-Close abgehakt, weiter" | Zeigt sie auf ein Issue mit Checkliste, entscheidet dessen ganzer Body — Punkt 5, dritte Frage. |
| "Das Keyword steht im Body, also blockt Punkt 5" | Nur eine Auto-Close-Zeile zaehlt. Eine Nennung im Fliesstext ist keine. |
| "Die Punkte dieses PRs stehen alle drin, also passt der Auto-Close" | Der Auto-Close schliesst auch die Punkte der Runden davor. Ganzer Body, nicht nur die eigene Liste. |
| "Nur Kleinigkeiten offen, ich approve und der Autor macht den Rest" | Nur mit fertigem `suggestion`-Block je aenderndem Punkt, in einem Review-Event mit dem Approve; ein Punkt ohne Block oder ein blockierender haelt es auf (Punkt 4). |
| "Der Thread ist resolved, also ist der Vorschlag drin" | Resolven kann der Autor selbst — der Beweis ist `test-applied-suggestions.ps1`, nicht der Thread-Status (Punkt 4). |
| "Ich habe approved, damit bin ich fertig" | Erst mit Zeilen-Datei der Runde (in der sauberen Runde samt Zeile `Review-Verdict: approve <sha>` im Approve-Body, mit und ohne Controller) und Review-Head (Phase 1, Schritte 4-6) — das Schliessen des Tracking Issues ist dann Sache dessen, der merged (§ "Nach dem Merge"). |
| "Der Head hat sich seit meinem Approve bewegt, also neue Runde" | Erst `scripts/common/test-pure-catch-up.ps1` gegen `reviewed_sha`, nach einem Approve mit offenen Vorschlaegen `scripts/common/test-applied-suggestions.ps1` (SKILL.md, Phase 3, Schritt 1): `PURE` bzw. `PROVEN` laesst das Verdikt stehen; den zweiten vollen Lauf nach Code-Bewegung von `main` ersetzt der Beweis nie (`.agents/rules/pr.md` § "Test Runs"). |

## Gegenpruefung des Hard-Gates — Empfehlung, keine Pflicht

Nach dem eigenen Durchlauf des Hard-Gates und **vor** dem positiven Abschluss-Verdikt: einen
**frischen** ccweb-Sub-Agenten ansetzen, der ausschliesslich die sieben Punkte des `[HARD-GATE]` in
der `SKILL.md` nachrechnet —
**nicht den Code**. Er bekommt PR-Referenz und Repo, liest am Head selbst nach und meldet je Punkt
`checked` / `not checked` / `finding`, in Conventional Comments.

- **Warum ein eigener Agent.** Er hat Checkout und `git grep`, die einer reinen Chat-Session
  fehlen. Rechenfehler — eine falsche Zahl, ein abgehaktes REQ, dessen Zahlen nie gegen den
  Basis-Branch gerechnet wurden — findet er damit in Sekunden.
- **Frisch heisst frisch:** nie der Autoren-Agent und nie der Agent, der den Review geschrieben
  hat. Wer die eigene Zaehlung nachzaehlt, bestaetigt sie.
- **Warum Empfehlung.** Als Pflicht waere es mehr Prozess, und das Playbook haelt Prozess
  knapp. Ob der Lauf etwas findet, misst `scripts/common/measure-review-comment.ps1` ueber
  die naechsten Schnitte; findet er nichts, faellt die Empfehlung wieder weg.
- **Wo es nicht geht** — eine Umgebung ohne Sub-Agenten —, entfaellt der Lauf ersatzlos. Er ist
  keine Bedingung des Verdikts, und ein nicht gefahrener Lauf wird als solcher benannt, nicht
  verschwiegen (`.agents/rules/evidence.md` § "Evidence Requirement").

## Nach dem Merge

**Das Tracking Issue — oder jedes andere Issue mit Checkliste, dessen letzten Punkt der PR abhakt —
schliesst, wer merged**, nach gruenem Merge-Gate (`.agents/rules/pr.md` § "Merge",
`.agents/rules/carrier.md` § "Tracking Issue"). Die Review-Session wartet nicht darauf.

**Warum es beim Merger liegt:** der Merge passiert Stunden nach dem Approve, und eine
Reviewer-Session, die auf ihn wartet, haelt einen Sitz offen oder ist nicht mehr da, wenn er
passiert. Wer merged, ist im Moment des Merges da — der Ausloeser und der Zustaendige fallen
zusammen.

Skript fahren: vor dem Merge `pwsh scripts/common/test-merge-ready.ps1 -Repo <repo> -Pr <n>` (im
Gleiches-Konto-Fall nach `.agents/rules/pr.md` § "Accounts per Seat" mit `-SameAccount`), nach
dem Merge `pwsh scripts/common/close-tracking-issue.ps1 -Repo <repo> -Pr <n>` (mit `-WhatIf` zur
Vorschau). Das zweite schliesst nur, was `find-closable-issues.ps1` als `closable` meldet, und sagt
sonst, warum das Issue offen bleibt. Ohne Skript, je Issue aus dem PR-Body: die Bedingungen
aus `.agents/rules/carrier.md` § "Tracking Issue" (Body am Head nachgezaehlt, ohne offenen Punkt)
und die Pruefungen vor dem Schliessen aus § "Carrier Requirement" (Checkboxen, Name im Repo, andere
Repos, Vermerk des Maintainers) von Hand fahren; dazu pruefen, ob ein anderer offener PR das Issue
mit Schliess-Schluesselwort nennt — dann schliesst dessen Merge es, und es bleibt offen
(`claimed-by-open-pr`). Jede `rehang-first`-Stelle wird vorher umgehaengt.
Sauber → schliessen, mit dem Schliess-Kommentar. Sonst **offen lassen** und in **einer Zeile**
sagen, warum und was noch aussteht.

Kann der Merger nicht schliessen (Rechte, gesperrte Forge), geht es mit derselben einen Zeile an
den `maintainer` — als Frage am Tracking Issue, nicht als stiller Abbruch.

## Nach dem Merge — wenn das Skript `SOURCE UNAVAILABLE` meldet

`find-closable-issues.ps1` endet dann mit Exit 1 und liefert keine Ergebnisse fuer die Issues, die es
nicht lesen oder nicht durchsuchen konnte. Das ist **keine leere Liste** — nichts ist damit
schliessbar. Von Hand nachzaehlen, was das Skript sonst liefert: die Issue-Nummern aus dem PR-Body
sammeln, je Issue den Body am Head auf offene Checkboxen und offene Sub-Issues lesen, `git grep`
nach `#N` und jede Fundstelle mit Traeger-Formel lesen, und die offenen PRs ausser diesem auf ein
Schliess-Schluesselwort mit `#N` ansehen (gefunden: offen lassen). Am Tracking Issue sagen, dass
das Skript nicht lief und die Pruefung von Hand gefahren wurde; nie so tun, als haette es gruen
gemeldet.
Meldet nur die Marker-Pruefung `SOURCE UNAVAILABLE`, stehen die Ergebnisse, und der
Schliess-Kommentar sagt selbst, dass die Marker nicht geprueft sind — dann diese Pruefung von Hand
(`git grep` nach `#N]` und `TODO`/`HACK`/`FIXME` mit `#N`).
