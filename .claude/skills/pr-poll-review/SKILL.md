---
name: pr-poll-review
description: 'Reviewt einen GitHub Pull Request iterativ bis zum Approve und fuellt die reviewer-Rolle des Playbook-PR-Lifecycles. Klassifiziert den PR, faehrt Agent-Red-Flag- und Beyond-the-diff-Checks, sammelt Punkte mit Severity und trennt Findings (klare Maengel -> posten/streichen) von offenen Fragen (Entscheidung noetig -> User stimmt ab, mit a) SOTA b) andere c) Empfehlung, Empfehlung vorbelegt). Legt beides vor jeder Veroeffentlichung erst als lesbaren Chat-Report plus Widget zur Freigabe vor, postet dann den Review, wartet auf Pushes, reviewt neu und approved erst wenn alle Punkte adressiert sind, CI gruen ist und keine Merge-Konflikte offen sind. Merged nie selbst. Triggert, wenn der User einen PR reviewen UND bei OK approven lassen will: "review und wenn ok approve", "pr pollen", "check PR [ref]", "approve sobald die changes da sind", "rere" (Re-Review des zuletzt gereviewten PRs). Nicht fuer einen einmaligen Review ohne Approve. Nur fuer GitHub-PRs (nicht GitLab/Forgejo).'
metadata:
  version: "3.0.1"
  source: ww3d/playbook
---

# PR Review & Approve Workflow

Iterativer Review-Loop fuer GitHub-PRs. Faehrt von Erstreview bis Approve durch und fuellt die
`reviewer`-Rolle aus `AGENTS.md` § "PR Lifecycle" (Schritte 9-11). Der Merge (Schritt 12) bleibt
beim `maintainer` — dieser Skill merged nie.

## Kernprinzip

- **Ziel:** Alle mit dem PR zusammenhaengenden Punkte werden im selben PR sauber gefixt und
  geradegezogen — nicht nur das Angefasste, sondern auch verwandte Files, Configs und Tests
  (beyond-the-diff).
- **Agent-Autor-Annahme:** Der Author (ein Coding-Agent, z.B. Claude Code oder Copilot) produziert
  Code, der sauber aussieht, aber leise mehr Redundanz und Tech-Debt traegt als menschlicher. Nicht
  vom Oberflaechen-Eindruck taeuschen lassen — gezielt nach den Agent-typischen Fehlerklassen
  suchen (Phase 1, Red-Flags).
- **Zwei Punkte-Arten:** Jeder gesammelte Punkt ist entweder ein **Finding** (klarer Mangel mit
  eindeutiger Korrektur — Bug, CI-Gaming, fehlender Test, God-Class; Interaktion: posten/streichen)
  oder eine **offene Frage** (Entscheidung ohne eindeutig richtige Loesung, mehrere valide Wege, oder
  abhaengig von Kontext/Praeferenz, den nur der User hat; Interaktion: der User stimmt ab). Im Zweifel
  ist es eine offene Frage — praeskriptiv posten nur, wenn die Korrektur wirklich eindeutig ist.
- **a/b/c bei offenen Fragen:** Jede offene Frage wird mit drei Perspektiven zur Auswahl aufbereitet:
  **a) SOTA/modern** (der State-of-the-Art-Ansatz), **b) was andere / die Grossen machen** (verbreitete
  Praxis grosser Projekte), **c) Empfehlung** (Claudes konkreter Rat fuer genau diesen PR) — **c) ist
  vorbelegt**. Wo a) oder b) sich nicht sauber belegen laesst, den Slot weglassen statt raten. Findings
  brauchen kein eigenes a/b/c — ihre Korrektur/Empfehlung steht im Finding-Text selbst.
- **Freigabe-Gate:** Kein Kommentar wird gepostet, bevor der User die gesammelten Punkte gesehen und
  freigegeben hat (Phase 1, Schritt 4).
- **Author-Loop:** Jeder Review-Kommentar fordert den Author explizit auf, nach dem Fix am PR
  zurueckzumelden.

## Eingabe

PR-Referenz, Pflicht (sonst danach **fragen**, nicht raten):

- `owner/repo#123` oder URL `https://github.com/owner/repo/pull/123`.
- Ausnahme `rere`: Re-Review des zuletzt in dieser Session per `/pr-poll-review` gereviewten PRs,
  ohne die Referenz erneut zu nennen. Ohne vorherigen Review in der Session weiterhin **fragen**.

Optional (nur fuer den Polling-Fallback relevant):

- `poll_interval` — Sekunden zwischen Polls (Default: 30; Remote-API-Rate-Limits beachten).
- `max_iterations` — Review-Runden bevor abgebrochen wird (Default: 10).
- `timeout_minutes` — Gesamttimeout (Default: 60).

## Phase 1: Erstreview

1. Diff holen via `pull_request_read` (method=`get_diff`); bestehende Threads via
   `get_review_comments` lesen, um Doppel-Kommentare zu vermeiden.

2. **Scan & Classify.** Filelist + Diff-Groesse ueberblicken, Review-Tiefe festlegen: kleine
   Touch-PRs duerfen knapp bleiben, grosse/breite PRs bekommen die volle Tiefe.
   - **Sub-Agent-Parallelisierung bei grossen/breiten PRs:** parallele Spezial-Passes starten
     (Security, Quality+Reuse, Tests, Docs), jeder gegen die Kriterien aus Schritt 3 (Red-Flags,
     Test-Evidence, Konsistenz). Als Coordinator: Findings deduplizieren, echte
     Severity bewerten, false positives filtern, **einen** konsolidierten Punkte-Satz bilden.
   - **Modellwahl pro Sub-Agent selbst nach Aufgabe treffen (soweit der Harness Modellwahl
     exponiert):** jeweils das *kleinste und schnellste* Modell waehlen, mit dem die Teilaufgabe
     noch 100% praezise, sauber und SOTA geloest wird. Leichte, textlastige Passes (Docs, einfache
     Konsistenz-Checks) klein/schnell; anspruchsvolle Logik-/Security-Passes und die
     Coordinator-Rolle das staerkste Modell.

3. **Code durchgehen, Punkte sammeln.** Zeile fuer Zeile, kein Sampling; verwandte Files/Configs/
   Tests mitpruefen, nicht nur den Diff-Rand. Conventional Commits der Commit-Messages mitbewerten;
   den Default-Branch aus dem PR-Objekt lesen, nicht `master`/`main` annehmen. Dabei gezielt:
   - **Agent-Red-Flags (zuerst, harte Sachen):**
     - **CI-Gaming** — Tests entfernt/geskippt/umbenannt, Coverage-Threshold gesenkt, `|| true`
       angehaengt, Workflow-Trigger eingeschraenkt. **Harter Blocker**, immer.
     - **Reuse-Blindness** — pro neuer Util/Helper/Klasse kurz im Repo nach einem bestehenden
       Aequivalent suchen. Dupliziert der PR vorhandene Logik: Konsolidierung im selben PR
       erzwingen, nicht nur kommentieren. Hoechster Review-ROI bei Agent-Code.
     - **Hallucinated Correctness** — kompiliert + Tests gruen heisst nicht korrekt. Einen
       kritischen Pfad end-to-end tracen; Boundary-Conditions und Permission-Checks auf den
       *nicht* getesteten Branches pruefen.
     - **Prompt-Injection** — bei jedem Pfad, der untrusted Input (Webhook-Payload, Issue-/PR-Text)
       in einen LLM-/Shell-Aufruf fuehrt.
   - **Doku-Integritaet (mit den vorhandenen Tools pruefen, nicht nur ueberfliegen):** aendert der
     PR Docs oder legt er ein mitgeliefertes Dokument ab, wird dessen Ist-Stand am PR-Head
     verifiziert (`get_file_contents` am Head-SHA bzw. `gh`), nicht dem PR-Body geglaubt.
     - **Mitgeliefertes Decision-Log / uebergebenes Dokument verbatim?** Behauptet der PR
       "verbatim / unveraendert uebernommen", die Datei am Head aber gegen die Quelle pruefen:
       zerstoertes Markdown (Header/`##`/`---`/Bold kollabiert, Zeilen zusammengezogen), fehlende
       Abschnitte, halbierte Zeilenzahl → Finding. Uebergeben wird per Datei-Anhang, der die Bytes
       identisch haelt; zerstoertes Markdown ist genau das Signal, dass doch der Chat-Weg
       (Rendering + Copy-Paste) genommen wurde. Pruefpunkt dafuer: eine Transport-Datei traegt als
       erste Zeile den Marker `<!-- transport: verbatim, do not re-render -->` — fehlt er in einer
       als verbatim deklarierten Uebernahme, ist das ein Indiz und wird mitgemeldet.
     - **Belege leben am Head?** Zitiert eine geaenderte Doc-Stelle einen Beleg-Anker
       (Symbol-/Testname, SHA-Permalink) oder einen
       Marker (`[erfuellt]`/`[teilweise]`/`[geplant]`), stichprobenartig gegen den Head-Stand
       gegenpruefen: verweist der Beleg auf in diesem PR geloeschten/umbenannten Code
       (tote Belegstelle), oder widerspricht der Marker dem Gebauten → Finding. Besonders bei
       Retire-/Umzugs-PRs und Soll/Ist-markierten Architektur-Docs.
     - **`[erfuellt]`-Marker gegen Dateiliste.** Wird im Diff ein Marker von `[geplant]`/
       `[teilweise]` auf `[erfuellt]` gezogen, gegen die Dateiliste des PRs halten: deckt die
       Aussage eine Oberflaeche oder Komponente ab, zu der der Diff keine Datei enthaelt →
       Finding, auch wenn der danebenstehende Beleg plausibel klingt.
     - **`REQ`-Checkliste im PR-Body.** Enthaelt der PR-Body eine nummerierte `REQ-NN`-Tasklist
       (aus einem `ccweb-prompt`-Handoff oder manuell uebernommen), auf Vorhandensein und interne
       Konsistenz pruefen: lueckenlose Nummerierung, jeder Haken mit einem Beleg auf **stabilem
       Anker** (Test-/`It`-Name, Funktions-/Symbolname, Variablenname, Kommentar-Ueberschrift oder
       Permalink mit Commit-SHA — `AGENTS.md` § "Evidence Requirement"), jeder unchecked Punkt mit
       `nicht geliefert: <Grund>`. Haken ohne Beleg, unchecked ohne Grund oder eine ganz fehlende
       Liste bei einem Prompt, der eine Vorgabenliste enthielt → Finding. Ein Beleg, der nur aus
       branch-relativem `file:line` besteht, ist ebenfalls ein Finding — die naechste Fix-Runde
       verschiebt die Zeile. `file:line` innerhalb eines SHA-Permalinks ist in Ordnung.
       **Der Auftragsprompt selbst ist kein Review-Input:** Referenz fuer die Richtigkeit bleiben
       Decision-Log und Architektur-Doku, Referenz fuer die Vollstaendigkeit ist ausschliesslich
       die `REQ`-Liste im PR-Body.
     - **Wellen-Bericht (konditional).** Nur pruefen, wenn der PR-Body Review-Wellen behauptet oder
       der Auftrag den Review-Modus `hard vN` trug (der Prompt reicht die Kennung in den PR-Body
       durch). Dann gilt: je Welle eine Zeile mit Nummer, Modellen, Schwerpunkten und Findings-Zahl
       (auch `0`), letzte Welle sauber oder die Restpunkte nach Cap 4 benannt; fehlender oder
       unplausibler Bericht → Finding. Traegt der PR `light` oder `soft` — oder gar keinen
       Modus — und behauptet keine Wellen, ist ein fehlender Bericht **kein** Finding.
   - **Test-Evidence:** jede nicht-triviale Logikaenderung braucht einen Test, der auf dem
     Pre-Change-Verhalten fehlgeschlagen waere. Fehlt der: als Punkt aufnehmen — kann der Author
     keinen schreiben, ist der Fix unvollstaendig.
   - **Beleg-Pflicht:** behauptet der PR-Body "gebaut / gruen / schnell / verifiziert" ohne einen
     stabilen Anker (Test-/Symbolname, SHA-Permalink) als Beleg — Finding; nacktes
     branch-relatives `file:line` zaehlt nicht als Beleg. Was nicht real lief (Docker / CLI / CI /
     Hardware fehlt) muss der Body als "nicht verifiziert" deklarieren, nicht beschoenigen;
     "schnell" ohne Benchmark ist kein Beleg.
   - **Klassengroesse:** neue oder gewachsene Klasse ueber 300 Zeilen oder mit mehr als ~15
     Instanzfeldern / mehr als einer Verantwortlichkeit ohne Begruendung im PR-Body — Finding
     (God-Class-Faenger; ein mechanischer Datei-Split zaehlt nicht als Loesung). Reine
     Schema-/DTO-/Config-Klassen und stateless Helfer sind ausgenommen.
   - **PR-Body-vs-Diff-Konsistenz:** auf Phantom Changes (Body behauptet Aenderungen, die nicht im
     Diff sind), Scope-Understatement (Diff tut mehr als der Body sagt) und Placeholder-
     Descriptions pruefen.
   - **Backlog-Gegencheck (beide Richtungen).** Erledigt der PR einen Eintrag, der in
     `backlog.md`, `roadmap.md` oder einem Issue als offen gefuehrt wird, **muss er ihn im selben
     PR streichen** (durchstreichen, nicht loeschen) — sonst taucht er in der naechsten
     Design-Runde wieder als offen auf und beschreibt womoeglich einen Stand, den es nicht mehr
     gibt. Umgekehrt gilt die Zaehlregel oben: was der PR offen laesst, braucht einen Traeger. Bei
     Doku-Nachzuegen die Wahrheitsquellen **einzeln** gegenpruefen — `architecture.md`,
     `roadmap.md`, `backlog.md`, betroffene Nutzer-Docs; eine Sammelformel ("die Doku nachziehen")
     laesst genau die Quelle durchfallen, die niemand im Kopf hat.
   - **Mitgeliefertes Log gegen die Review-Runden gelesen?** Ein Decision-Log, das **in diesem PR
     neu entsteht**, traegt dessen Endstand — die Review-Runden liegen nach seiner Niederschrift.
     Pruefen: steht dort ein Punkt noch als ungetragen, der inzwischen einen Traeger hat?
     Beschreibt es einen Scope, den der reale Diff nicht mehr hat? Dann fehlt der Abschnitt
     `## Nachtraege aus den Review-Runden` am Ende des Files → Finding. **Das hebt den
     Verbatim-Check oben nicht auf:** der uebergebene Entscheidungstext bleibt byte-identisch, der
     Nachtrag steht abgesetzt darunter (`docs/decisions/README.md` § Immutabilitaet).
   - **Zeigen die Belege auf den Stand, der gemergt wird?** Nach jedem Push und jedem Rebase
     wandern sie mit. Beleg-Stand-Zeile, SHA-Permalinks **und jede Mengenangabe im Body** (Zeilen-,
     Test-, Datei-, Funktionszahlen) gegen den aktuellen Head pruefen — was auf einen anderen Stand
     zeigt, ist ein Finding. Mengenangaben sind Teil des Diffs, nicht der Vorgeschichte: die Regel
     gilt nicht nur beim Schreiben einer Zahl, sondern **rueckwirkend bei jedem Commit, der eine
     schon geschriebene Zahl bewegt**.

   **Beim Sammeln pro Punkt festlegen (fuer die Freigabe in Schritt 4):**
   - **Art:** Finding oder offene Frage (Kernprinzip "Zwei Punkte-Arten"). Ein klarer Bug ohne
     Ermessensspielraum ist ein Finding; wo mehrere Wege valide sind oder die Wahl an Kontext haengt,
     den nur der User hat, ist es eine offene Frage — nicht praeskriptiv als Finding verkleiden. Zu den
     offenen Fragen zaehlen **beide Quellen**: was der Autor im PR selbst offen gelassen hat
     (Stufe-A-Autor-Kontext) **und** was Claude im Review als offen erkennt.
   - **Zaehlregel fuer Autor-Punkte:** jeder abgesetzte Punkt (nummeriert oder als Bullet), den der
     PR-Body offen laesst (Abschnitte "Offene Fragen", "Observations", "Bewusst nicht"), bekommt
     **genau eine eigene F-Nummer**. Die Form ist nirgends vorgeschrieben — `AGENTS.md`
     § "PR / MR Description" verlangt fuenf Ueberschriften, keine Listenform; eine Zaehlmenge, die
     an der Nummerierung haengt, laesst sich durch Bullets umgehen. Kein Buendeln mehrerer Punkte
     zu einer Frage, kein Weglassen mit der Begruendung "ausserhalb des Auftrags" oder "vom Autor
     korrekt eingeordnet" — **ob ein Punkt ausserhalb bleibt, entscheidet der User, nicht der
     Review**. Die Zahl der F-Nummern aus Autor-Quelle muss
     der Zahl der Punkte im PR-Body entsprechen; die eigenen Funde zaehlen zusaetzlich. Behauptet
     der Body, ein Punkt sei anderswo bereits getrackt (Issue, Roadmap-/Pool-Zeile, Backlog), wird
     dieser **Traeger am Head verifiziert** wie jeder andere Beleg — traegt er den Punkt nicht, ist
     das ein Finding.
   - **Traeger-Pflicht — jeder Punkt, der offen bleibt.** Ein **Traeger** ist der Ort, an dem ein
     zurueckgestellter Punkt so steht, dass man ihn wiederfindet (`AGENTS.md` § "Carrier
     Requirement"). Gueltig sind **nur** drei Orte: offenes Issue · Zeile in
     `roadmap.md`/`backlog.md` · Aussage in einer Architektur-/Baseline-Doku mit Marker
     `[geplant]`/`[teilweise]`. **Nicht** gueltig: PR-Body, Review-Kommentar, Issue-Kommentar, Chat
     — und **kein Decision-Log**: das ist das Protokoll eines Tages, gelesen fuers Warum, nie als
     Liste des Offenen. Steht eine Auflage im Log, braucht sie zusaetzlich Issue oder Roadmap-Zeile.
     Unmarkierte Prosa in einer Architektur-Doku zaehlt ebenfalls nicht — sie sagt nicht, dass
     etwas offen ist. Pro offenem Punkt pruefen:
     - **Existiert der Traeger und ist er offen?** Ein geschlossenes Issue ist kein Beleg, sondern
       ein Finding — es sieht aus wie ein erledigter. Roadmap-/Backlog-Zeilen und Status-Marker
       haben keinen Zustand; sie zaehlen, bis der Punkt durchgestrichen ist bzw. der Marker auf
       `[erfuellt]` wechselt.
     - **Traegt er wirklich diesen Punkt?** Am Head nachlesen, nie der Angabe im Body glauben.
     - **Weitergabe an eine kuenftige Scheibe gilt erst, wenn sie am Ziel steht** — im Issue der
       Ziel-Scheibe oder in deren `roadmap.md`-Zeile. Der Satz im Absender-PR ist eine Notiz an
       niemanden: der Empfaenger liest sein eigenes Issue, nicht fremde PR-Bodies. Gibt es das Ziel
       noch nicht, gehoert der Punkt in den Backlog — nie an eine Scheibe, die niemand kennt.
     - **Wer ihn anlegt:** der Autor, im selben PR, als Anweisung aus dem Review. Nur wenn der PR
       keine dieser Dateien anfasst, legt der Reviewer das Issue selbst an.
   - **a/b/c fuer offene Fragen:** zu jeder offenen Frage kurz a) SOTA/modern, b) was andere machen,
     c) Empfehlung recherchieren/formulieren. Nicht spekulieren — laesst sich a) oder b) nicht sauber
     belegen, den Slot weglassen statt raten. c) ist immer Claudes eigener, begruendeter Rat.

4. **Freigabe-Gate (vor jeder Veroeffentlichung).** Zweistufig — erst lesbarer Chat-Report, dann
   erst die Freigabe. Nie direkt in die Freigabe springen.

   **Stufe A — Chat-Report zuerst, immer, vor jeder Freigabe.** In dieser festen Reihenfolge im Chat
   ausgeben:
   **Der obere Teil ist neu und komplett in einfacher Alltagssprache (kein Fachjargon) — er soll den
   ganzen PR abdecken, damit der Leser nicht mehr in den PR wechseln muss. Der technische
   Detail-Report darunter bleibt unveraendert und ist nur fuer den Fall da, dass jemand reingehen
   will.**

   - **Mergebarkeit** (allererste Zeile) — die Ein-Blick-Antwort: kann der PR gemergt werden, und wenn
     nicht, was steht im Weg. Faltet Verdikt, CI-Status, Merge-Konflikte und offene Findings/Fragen in
     einen Satz, z.B. „Approvebar — blockt: nichts" oder „Blockt noch: CI laeuft, 1 Merge-Konflikt, 2
     offene Blocker". Das ist die konsolidierte Kurzantwort; der ausfuehrliche Verdikt steht unten im
     Detail-Teil.
   - **Kurzfassung** — der ganze PR in 2-4 Saetzen Klartext: was macht der PR, ist er ok, gibt es etwas
     zu tun.
   - **Was der Autor entschieden hat** — die wichtigsten Design-/Umsetzungsentscheidungen des PRs,
     einfach zusammengefasst (keine woertlichen Zitate, kein Jargon), 2-5 kurze Punkte. Gibt der PR
     dazu wenig her, entsprechend kurz — nichts erfinden.
   - **Changes-Tabelle** (optional, nur bei breiten PRs mit vielen Dateien) — verwandte Aenderungen zu
     Zeilen **gruppiert** (nie file-by-file; eine Quelldatei + 20 Uebersetzungsdateien sind zwei
     Zeilen), je Zeile eine Beschreibung in Alltagssprache. Bei kleinen/schmalen PRs entfaellt sie —
     die Kurzfassung reicht dann.
   - **Ablauf-Diagramm** (optional, nur wenn die Aenderung einen echten Fluss hat — API-Aufrufe,
     Event-/Async-Flow, Zustandsuebergaenge) — ein kompaktes Mermaid-Sequenz- oder Flussdiagramm des
     geaenderten Ablaufs (rendert in GitHub und vielen Chat-Clients; sonst bleibt der Mermaid-Block als
     Rohtext lesbar). Kein Diagramm um des Diagramms willen — hat der PR keinen nennenswerten Fluss,
     entfaellt es.
   - **Offene Fragen** (nur wenn es welche gibt) — je Frage ein Satz Klartext, worum es geht, dann
     a) SOTA/modern · b) was andere machen · c) Empfehlung; **c) ist vorbelegt**. Quelle: was der Autor
     im PR offen liess + was Claude im Review sieht. Dieselben Fragen stehen zur Auswahl im Widget.
     Gibt es keine, wird das gesagt.

   ─── ab hier der bestehende Detail-Report, **unveraendert** (nur zum Reingehen); mit einer sichtbaren
   Trennung davor ───

   - **Verdikt**, als erste Zeile des Detail-Teils: `Blockiert` / `Approvebar nach Fixes` / `Sauber` —
     danach erst die Begruendung.
   - **Severity-Counts als Kopfzeile** (z.B. `3 Blocker, 2 Major, 4 Minor`), damit der Aufwand ohne
     Zaehlen sichtbar ist.
   - eine **kurze Prosa-Zusammenfassung des Reviews — hart auf max. 3 Saetze**: was geprueft wurde und
     der Gesamteindruck. **Keine Beleg-Aufzaehlung hier** — keine Anker-Listen, keine
     Test-Namen, kein „ich habe X, Y, Z getraced". Belege gehoeren an das jeweilige Finding, nicht in
     den Verdikt-Absatz. Wird der Absatz laenger als 3 Saetze oder zaehlt er Belege auf, ist er falsch.
   - darunter eine **vollstaendige, nummerierte** Findings-Liste. Pro Punkt: Nummer, **Severity-Tag
     `[Blocker]` / `[Major]` / `[Minor]`**, Datei/Zeile, ein Satz.
   - **Vollstaendigkeit ist Pflicht:** alles ab `[Minor]` wird gemeldet — reine Stilnotizen zaehlen
     nicht als Finding, in Schritt 2 aussortierte false positives bleiben draussen. Ordnung/
     Priorisierung nach Severity ist erwuenscht, aber nichts wird weggelassen oder still gefiltert.
   - **Coverage-Statement zum Schluss:** in einem Satz, was bewusst *nicht* geprueft wurde und warum
     (`Nicht geprueft: X, weil Y.`); gibt es keine Luecke, wird auch das gesagt. Ein Review, das
     seine Luecken verschweigt, liest sich vollstaendiger als es ist.

   **Stufe B — Freigabe** (referenziert die Nummern aus Stufe A). Default: **alle Findings werden
   gepostet**; der User streicht nur einzelne.

   - **Immer:** eine Zeile unter der Liste — der User nennt die Finding-Nummern, die gestrichen
     werden sollen, und fuer die offenen Fragen nur die, bei denen er von der vorbelegten Empfehlung
     abweicht (`F2: b`, `F3: custom …`). Ohne Angaben gilt jede kurze Bestaetigung (`k`, `ok`, `los`,
     `posten`, `machen`, `gut`) als „alle Findings posten, bei jeder Frage die Empfehlung". Custom-
     Punkte im selben Zug. Der Pfad, der nie ausfaellt.
   - **Zwei getrennte Ausstiege, beide ausdruecklich waehlbar** (sonst rutscht jeder Punkt in den
     bequemeren): `F3: offen lassen` — nicht als Anweisung posten, **Traeger Pflicht**; oder
     `F3: verwerfen` — der Punkt endet ersatzlos, kein Traeger, und wird im Review-Body einzeilig
     als verworfen protokolliert, damit die Entscheidung nachvollziehbar bleibt. Fehlt die Angabe,
     gilt „offen lassen"; „verwerfen" wird nie unterstellt.
   - **Immer mitliefern:** ein Widget als Eingabehilfe — in jeder Runde, unabhaengig davon, ob ein
     Visualizer verfuegbar ist (rendert es nicht, ist es folgenlos; siehe Invarianten). **Nur die
     VORLAGE-Zone von `widget-reference.html` (neben dieser Datei) 1:1 uebernehmen** — das dort
     markierte GERUEST (Dokumentrahmen, `:root`, `body`/`.wrap`, `.widget`-Container, `.out`) bleibt
     draussen, es macht die Datei nur standalone lauffaehig. Masse, Farben (ueber Host-Variablen)
     und Logik stehen in der Referenz und werden hier bewusst nicht gedoppelt, damit Referenz und
     Spec nicht auseinanderlaufen. Zwei Injection-Points, beide aus dem Stufe-A-Report befuellen:
     `FINDINGS` (die Findings) und `QUESTIONS` (die offenen Fragen; leer lassen, wenn es keine gibt —
     dann entfaellt der Fragen-Bereich sichtbar). Was der Referenz-Code nicht selbst begruendet:
     - Die rechte Spalte des Kopf-Grids bleibt leer — sie haelt die Mitte zentriert und die obere
       rechte Ecke frei, wo Chat-Clients ihr eigenes Menue einblenden.
     - Die Legende bleibt immer vollstaendig, auch fuer Stufen ohne Findings: sonst ist der neutrale
       Badge nicht als „Minor" (statt „deaktiviert") erkennbar, und dass keine roten Badges
       dastehen, ist selbst ein Signal.
     - Die Severity der Findings ist im Widget **read-only** — sie ist die Aussage des Reviews und
       nicht hier umzustellen (nur posten/streichen), sonst widerspraeche der Badge dem
       Finding-Text und das Widget triebe von Stufe A weg. Frei waehlbare Prio gibt es nur bei den
       eigenen Custom-Punkten, weil die dem User gehoeren.
     - **Offene Fragen sind ein eigener, vom Findings-Block klar abgetrennter Bereich** mit anderer
       Interaktion: nicht posten/streichen, sondern **eine Wahl pro Frage** — `a) SOTA`, `b) Grosse`,
       `c) Empfehlung`, eine eigene (Custom-)Antwort, und darunter abgesetzt die beiden Ausstiege
       `offen lassen` und `verwerfen`. Die Ausstiege stehen fest und kommen nicht aus dem
       Injection-Point; abgesetzt stehen sie, weil sie die Frage beenden statt sie zu beantworten.
       **c) ist vorbelegt**; der User uebersteuert nur, wo er anders entscheidet — dasselbe
       Default-Prinzip wie „alle Findings posten". Der a/b/c-Text ist read-only (die recherchierte
       Aussage aus Stufe A), waehlbar ist nur, welche Option gilt. Unter dem Frage-Titel steht die
       `→ heisst:`-Klartext-Zeile (Feld `explain` je Frage), damit die Entscheidung ohne Jargon
       verstaendlich ist — gleiche Aussage wie in Stufe A.

   Zwei Invarianten:
   - Das Widget **ersetzt** die Textaufforderung nie — es wird zwar immer mitgeliefert, aber die
     Visualizer-Verfuegbarkeit ist vorab nicht pruefbar (derselbe Client rendert je nach Plattform
     oder nicht). Rendert es nicht, ist das folgenlos, und der Text-Pfad traegt die Freigabe allein.
   - Das Widget ist reine Eingabehilfe, nie Informationsquelle: es traegt nie mehr, weniger oder
     andere Inhalte als der Report aus Stufe A — gleiche Findings-Nummern, gleiche Severity, gleiche
     Fragen (`F1`, `F2`, …) mit denselben a/b/c-Optionen und derselben Vorbelegung, nur kuerzer. Was
     nur im Widget stuende, waere fuer jeden verloren, bei dem es nicht rendert.

   `ask_user_input_v0` wird hier nicht benutzt: `multi_select` laesst sich nicht leer absenden,
   `single_select` sendet beim ersten Klick ab, beide deckeln bei 4 Optionen.
   - Erst nach Freigabe durch den User posten.

5. **Review posten** via `pull_request_review_write` (nur freigegebene + custom Punkte + entschiedene
   Fragen):
   - `event`: `REQUEST_CHANGES` wenn ein Blocker dabei ist, sonst `COMMENT`.
   - Inline-Comments mit `path` + `line` bevorzugen, jeder mit Severity-Prefix; Body mit knapper,
     nach Severity geordneter Zusammenfassung **plus expliziter Aufforderung an den Author, nach
     dem Fix zurueckzumelden**. Suggested-Code-Changes auf Englisch.
   - **Entschiedene offene Fragen** werden als konkrete Anweisung an den Author gepostet — der vom
     User gewaehlte Ansatz (a/b/c oder seine Custom-Antwort), nicht die Frage. Ab hier ist es fuer
     den Author eine Vorgabe wie ein Finding; die verworfenen Optionen nur nennen, wenn die
     Begruendung dem Author hilft. Eine Frage, bei der der User „offen lassen / nicht in diesem PR"
     waehlt, wird nicht als Anweisung gepostet — **„offen lassen" ist eine Ablage, kein
     Verwerfen**: der Punkt bekommt trotzdem seinen Traeger, bevor der Review abgeschlossen wird.
     Nur „verwerfen" beendet einen Punkt ersatzlos, und das ist eine ausdrueckliche Entscheidung
     des Users, keine Nebenwirkung.

6. Den Lifecycle-Trigger setzen: bei `REQUEST_CHANGES` den Autor anstossen, den PR auf Draft
   zuruecksetzen zu lassen (Schritt 10). HEAD-SHA des aktuellen Stands merken (`reviewed_sha`);
   Thread-IDs der eigenen Inline-Comments notieren (fuer spaeteres Resolve).

## Phase 2: Auf Aenderungen warten

- **Bevorzugt (Claude Code Web/Remote):** `subscribe_pr_activity` aufrufen und den Turn beenden.
  Neue Pushes und Kommentare kommen als `[github-webhook-activity]`-Events zurueck. **Nicht** mit
  `sleep` aktiv pollen.
- **Fallback (reiner Chat-Kontext ohne Webhooks):** alle `poll_interval` Sekunden
  `pull_request_read` (method=`get`) abfragen und `head_sha` mit `reviewed_sha` vergleichen, bis er
  sich aendert oder `max_iterations` / `timeout_minutes` erreicht sind. Transiente API-Fehler
  tolerieren.

Webhooks liefern CI-Erfolg, neue Pushes und Merge-Konflikt-Uebergaenge nicht zuverlaessig — bei
Unsicherheit den PR-Zustand aktiv nachladen.

## Phase 3: Re-Review

1. Diff zwischen `reviewed_sha` und neuem `head_sha` holen.
2. Pro vorherigem Comment pruefen: Stelle geaendert? Punkt adressiert? Zusaetzlich die Red-Flag-/
   Doku-Integritaets-/Beyond-the-diff-Checks aus Phase 1 auf das neu Dazugekommene anwenden — ein
   Fix-Commit kann ein Decision-Log kaputt-pasten oder einen Beleg tot machen, der vorher stimmte.
3. Auswertung (nach Severity):
   - **Alle adressiert, keine neuen Issues** → Phase 4.
   - **Rest- oder Neu-Issues** → sammeln → **Freigabe-Gate (Phase 1, Schritt 4)** → posten →
     **die in dieser Runde adressierten Threads sofort resolven** (`resolve_thread`) →
     `reviewed_sha` aktualisieren, zurueck zu Phase 2.

**Resolven passiert in jeder Runde, nicht erst am Ende.** Sobald ein Punkt adressiert ist, wird sein
Thread aufgeloest — auch wenn der PR insgesamt noch nicht durch ist. Wer bis Phase 4 wartet, laesst
den Author raten, was schon erledigt ist, und haengt die Restpunkte in einer Wand alter Threads.

## Phase 4: Resolve + Approve

[HARD-GATE]
Vor dem Approve, ausnahmslos — jeder Punkt muss erfuellt sein:

1. CI gruen — `pull_request_read` method=`get_check_runs`.
2. Keine Merge-Konflikte — bei `mergeable`/`mergeable_state` nicht clean **nicht** approven,
   Status melden. (`blocked` = pending Required-Review, **kein** Konflikt — kein Blocker.)
3. Kein CI-Gaming — wurden Tests/Coverage/Trigger manipuliert, um gruen zu werden, **nicht**
   approven, unabhaengig vom CI-Signal.
4. **Threads verifiziert leer (nicht aus dem Gedaechtnis, sondern nachgezaehlt).**
   `get_review_comments` frisch abrufen und die **selbst eroeffneten** Threads durchzaehlen: jeder
   muss `resolved` sein. Ist einer offen und sein Punkt am Head adressiert → jetzt `resolve_thread`.
   Ist einer offen und *nicht* adressiert → **kein** Approve/kein "passt"-Verdikt, zurueck in den
   Loop. Ergebnis der Zaehlung muss **null offene eigene Threads** sein; das ist eine gepruefte
   Vorbedingung, keine Erinnerung. Offene Threads *anderer* Reviewer werden nie selbst resolved,
   aber vor dem Approve benannt.
5. PR-Body woertlich nach `Closes #` / `Fixes #` / `Resolves #` durchsuchen. Fehlt es — **nicht**
   approven (blocken, oder nach dem Merge manuell schliessen).
6. Self-authored PR (Autor = eigener Reviewer-Account): nur `event: COMMENT` erlaubt — APPROVE
   ist gesperrt. **Das entbindet nicht von Punkt 4:** auch wenn kein echtes APPROVE gesetzt werden
   kann, zieht das abschliessende "approve-faehig / passt"-COMMENT-Verdikt dieselbe verifizierte
   Thread-Leere wie ein Approve. Kein "passt" mit offenen eigenen Threads.
7. Zwei getrennte Verdikte, beide gruen: **Spec** (tut der Diff genau das Bestellte, nichts zu
   viel/zu wenig?) und **Quality** (handwerklich sauber: Tests, Struktur, keine Magic Numbers?).
8. Beleg-Pflicht — behauptet der PR-Body Erfuellung ("gebaut / gruen / verifiziert / schnell")
   ohne stabilen Anker (Test-/`It`-Name, Funktions-/Symbolname, Variablenname,
   Kommentar-Ueberschrift oder SHA-Permalink), **nicht** approven (blockt, analog zum
   `Closes #`-Check aus Punkt 5). Ein Beleg, der nur aus branch-relativem `file:line` besteht,
   erfuellt die Pflicht nicht — die Zeile wandert mit dem naechsten Push; als Teil eines
   SHA-Permalinks ist sie in Ordnung. Was nicht real lief, muss als "nicht verifiziert" dastehen.
9. **Traeger-Gate — nachgezaehlt, nicht erinnert.** Die zu zaehlende Menge ist fest: jeder
   **abgesetzte** Punkt (nummeriert oder als Bullet) aus den PR-Body-Abschnitten „Offene Fragen" /
   „Observations" / „Bewusst nicht", **plus** jede eigene F-Nummer, die der User auf „offen lassen"
   gesetzt hat. Ausdruecklich verworfene Punkte zaehlen nicht mit. Zu jedem verbleibenden Punkt am
   Head die Traeger-Referenz nachlesen (Liste in Phase 1, Schritt 3) und pruefen, dass sie ihn
   wirklich traegt und offen ist.
   **Ergebnis muss null traegerlose Punkte sein** — sonst **nicht approven**, dieselbe Haerte wie
   der `Closes #`-Check aus Punkt 5.
[/HARD-GATE]

Diese Gedanken bedeuten STOP — du rationalisierst:

| Gedanke | Realitaet |
|---|---|
| "Key-Files reichen, der Rest ist Boilerplate" | Zeile fuer Zeile, kein Sampling. |
| "Sieht fertig aus, Closes-Check kann ich sparen" | Erst Punkt 5, dann Urteil. |
| "Spec passt schon, muss den Diff nicht gegenpruefen" | Spec-Verdikt ist eigenstaendig. |
| "Tests sind gruen, also passt der Fix" | Hallucinated Correctness — kritischen Pfad tracen. |
| "Ich hab die Threads doch resolved" | Nachzaehlen, nicht erinnern — `get_review_comments`, Ergebnis null. |
| "Kann eh nicht approven (self-authored), Threads egal" | Das "passt"-COMMENT zieht dieselbe Thread-Leere (Punkt 6). |
| "Steht doch im PR-Body, damit ist es gemeldet" | Ein gemergter Body ist ein Archiv — Traeger-Gate, Punkt 9. |
| "Der Autor sagt, das laeuft woanders schon" | Am Head nachlesen; ein geschlossenes Issue traegt nichts. |

Wenn sauber: zuerst behandelte Threads aufloesen (`resolve_thread` `threadId=PRRT_...`, unbehandelte
offen lassen), dann `pull_request_review_write` mit `event`: `APPROVE` und knappem Body (Schritt 11).
Den Nutzer informieren: "PR #N approved. Merge **nicht** ausgefuehrt — der `maintainer` merged."

## Phase 5: Funktionale Zusammenfassung

Nach dem Approve im **Chat** liefern (nicht im PR):

- Vorher/Nachher-Zustand
- Happy Path
- Edge Cases
- Was bewusst unberuehrt bleibt
- Architektonischer Beitrag

## Strikte Regeln

- **Niemals** ohne Freigabe des Users einen Kommentar posten (Freigabe-Gate ist Pflicht in jeder
  Runde).
- **Das Findings-Widget wird in jeder Runde immer mitgeliefert**, unabhaengig von der
  Visualizer-Verfuegbarkeit — es ersetzt aber nie den Text-Pfad (rendert es nicht, folgenlos).
- **Das Widget wird immer inline gerendert** (Visualizer/`show_widget`) — nie als Datei-Anhang, nie
  als Code-Block, nie als Beschreibung dessen, was es enthielte. Die VORLAGE-Zone rechnet mit den
  Host-Variablen; ausserhalb des Hosts ist sie ungestyltes Markup und damit wertlos. Aufwand ist
  kein Grund, den Kanal zu wechseln.
- **Kein offener Punkt ohne Traeger** — was dieser PR bewusst nicht loest, steht vor dem Approve
  an einem offenen Issue, in `roadmap.md`/`backlog.md` oder als `[geplant]`/`[teilweise]`-Aussage
  in einer Architektur-Doku. PR-Body, Kommentare und Decision-Logs zaehlen nicht; eine Weitergabe
  zaehlt erst am Ziel.
- **Offene Fragen nie einseitig als Finding entscheiden** — wo mehrere Wege valide sind oder die Wahl
  an User-Kontext haengt, wird abgestimmt (Empfehlung vorbelegt), nicht praeskriptiv gepostet.
- **CI-Gaming ist immer ein harter Blocker** — nie approven, wenn Tests/Coverage/Trigger
  manipuliert wurden, um gruen zu werden.
- **Behandelte Threads werden in jeder Runde resolved**, nicht erst vor dem Approve — der am
  haeufigsten vergessene Schritt. Unbehandelte bleiben offen; nie einen Thread resolven, dessen
  Punkt noch aussteht.
- **Vor jedem Abschluss die eigenen Threads nachzaehlen, nicht erinnern** (Phase 4 Punkt 4): frisch
  `get_review_comments`, Ergebnis muss null offene eigene Threads sein — auch beim
  self-authored-COMMENT-"passt", das kein echtes Approve setzen kann. Der am haeufigsten
  uebersprungene Schritt, weil sich das "passt"-Verdikt wie der Abschluss anfuehlt.
- Reuse-Blindness aktiv suchen, nicht passiv abwarten.
- **Niemals** automatisch mergen — `merge_pull_request` nur auf separate, explizite Anweisung; der
  Merge ist `maintainer`-only.
- **Niemals** approven bei rotem CI oder Merge-Konflikten.
- **Niemals** einen PR im Review schliessen/wieder oeffnen.
- Bei Force-Push oder Branch-Reset: Loop pausieren, beim Nutzer nachfragen.
- Jeden Review-Kommentar auf beiden Seiten spiegeln (lokaler Chat + GitHub-Thread), auch
  Acknowledgements (`AGENTS.md` § "Mirroring GitHub Conversations").
- Inline-Comments mit `path` + `line` bevorzugen; Suggested-Code-Changes auf Englisch.

## Repo-Konventionen

- Conventional Commits beim Bewerten der Commit-Messages erwarten.
- Default-Branch aus dem PR-Objekt lesen.
- `git` + `gh` sind Default fuer alle GitHub-Operationen (`AGENTS.md` § "Forge Tooling"); das
  GitHub MCP nur als Fallback, wenn `gh` etwas nicht sauber kann, oder fuer MCP-only-Tools.
- Falls via MCP gereviewt wird: Inline-Comments in drei Schritten — `create` (pending) →
  `add_comment_to_pending_review` → `submit_pending` (`event: COMMENT`/`REQUEST_CHANGES`); sonst
  scheitert der Inline-Review still. Bei `gh` entfaellt das.
- Bei Backport-relevanten Punkten pruefen, ob im betroffenen Upstream-/Nachbar-Repo ein
  Tracking-Issue vorliegt.
