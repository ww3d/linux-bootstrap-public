# Review-Modus-Bausteine

Die eine Stelle fuer den Wortlaut der Review-Modi. Die Spec-Datei eines Auftrags nennt nur die Zeile
`Review-Mode: <mode>` (`.agents/rules/pr.md` § "Task Spec"; die alte Form `Review-Modus: <modus>`
gilt bis Playbook 26.0.0); der Autor (`dev-task`) faehrt die Wellen nach dem Baustein hier, der
Reviewer (`pr-poll-review`) liest die Zeile aus der Spec-Datei am Head und prueft die Wellen gegen
denselben Baustein. Den Modus waehlt die Design-Runde (`ccweb-prompt`, Schritt 3).

Drei feste Bausteine. **Wortlaut nie umformulieren** — so driftet die Wellen-Regel nicht von Session
zu Session weg.

**In allen drei Modi gilt zusaetzlich, ausserhalb der Bausteine:** das Modell jedes Pruefers richtet
sich nach `.agents/rules/agents.md` § "Models" (`.agents/rules/review.md` § "Review Comments").

## hard

Traegt eine Versions-Kennung. Aktuell `hard v4`; sie wird hochgezaehlt, sobald sich Schwerpunkte,
Loop-Regel oder Cap aendern; eine Aenderung der Modellwahl zeigt `/VERSION` an. Die Spec-Zeile
traegt die Kennung, damit der Reviewer weiss, gegen welche Fassung er prueft.
`v4` loest `v3` ab, weil die Modellwahl an einer Stelle steht (`.agents/rules/agents.md` § "Models") statt im
Baustein.

```md
Review-Mode: `hard v4`

Vor dem PR und vor jeder Fix-Runde eine parallele Welle von 3-4 Review-Sub-Agenten: frische
Sessions, verschiedene Schwerpunkte (Korrektheit/Randfaelle, Performance/Hot Paths, Vertraege/Docs,
Test-Luecken), alle auf demselben Commit-Stand. Befunde mergen/dedupen, fixen; die naechste Welle
verifiziert erst die Fixes.

Jede Welle meldet in Conventional Comments: je Punkt `issue:` / `nitpick:` / `question:` mit
`(blocking)` oder `(non-blocking)`, bei Altcode zusaetzlich `(pre-existing)`
(`.agents/rules/review.md` § "Review Comments"). Das
Zusammenfuehren wird damit mechanisch statt Ermessen, und der Coordinator sieht sofort, was
ueberhaupt blocken kann.

Modelle je Welle nach `.agents/rules/agents.md` § "Models".

Ab Welle 2 wird der Diff nach Bereich unter den Agenten geteilt, nicht viermal vollstaendig
gelesen: Welle 1 traegt den Ertrag, weil ein systemischer Fehler nur auffaellt, wenn jemand alles
liest — danach ist der Diff bekannt.

Abbruch, sobald eine Welle nur noch `nitpick:` findet. **Hard-Cap 2 Wellen, und der Cap geht der
Abbruch-Bedingung vor. Der Cap begrenzt die Wellen, nicht das Fixen:** was nach der zweiten Welle
offen ist, in einer Datei liegt, die der PR anlegt oder aendert, und einen bekannten Fix hat, wird
im PR gefixt. Alles andere Baubare: `.agents/rules/carrier.md` § "Carrier Requirement". In den
Body des Tracking Issues — nie in den PR-Body — geht nur, was keinen bekannten Fix hat oder nur im
Fremd-Repo zu fixen ist, je in seiner festen Form aus `.agents/rules/carrier.md` § "Carrier
Requirement"; eine offene Entscheidung wird eine Frage, keine Zeile. Jede andere Zeile ist ein
verschobener Fix und blockt den Review.

Reine Loesch-Diffs bekommen keine Welle. Dort traegt ein Waechter-Test, der rot wird, sobald das
Geloeschte wieder auftaucht.

Wellen-Bericht im PR-Body ist Pflicht: je Welle eine Zeile mit Nummer, Modellen, Schwerpunkten und
Befundzahl je Label (auch `0`).
```

## light

Eine einzige Gegen-Welle. Fuer mittlere Aufgaben: 80% des Wertes zum Bruchteil der Kosten. Kein
Wellen-Bericht-Gate.

```md
Review-Mode: `light`

Eine einzige Gegen-Welle: 1 frischer Sub-Agent, voller Gegencheck, Modell nach `.agents/rules/agents.md` § "Models". Befunde fixen. Kein Wellen-Bericht noetig.
```

## soft

Nur die Schleifen-Formel. Kein Bericht, kein Gate.

```md
Review-Mode: `soft`

Autonom bis zum Ende, Schleife bis perfekt und ohne Befunde: Self-Review + Refactoring-Runden,
Annahmen dokumentieren. Kein Wellen-Bericht noetig.
```
