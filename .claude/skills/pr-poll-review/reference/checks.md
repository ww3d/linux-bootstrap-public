# pr-poll-review — Pruefkatalog (Phase 1)

## Inhalt

- [Fehlendes Artefakt — wann es blockt](#fehlendes-artefakt--wann-es-blockt)
- [Sub-Agent-Passes und Modellwahl](#sub-agent-passes-und-modellwahl)
- [Agent-Red-Flags (zuerst, harte Sachen)](#agent-red-flags-zuerst-harte-sachen)
- [Doku-Integritaet](#doku-integritaet)
- [Doku-Delta](#doku-delta)
- [Mechanismus und zweite Fundstelle](#mechanismus-und-zweite-fundstelle)
- [Test-Evidence](#test-evidence)
- [Beleg-Pflicht](#beleg-pflicht)
- [Mengenangaben](#mengenangaben)
- [Klassengroesse](#klassengroesse)
- [Kommentare](#kommentare)
- [PR-Body vs. Diff](#pr-body-vs-diff)
- [Backlog-Gegencheck](#backlog-gegencheck)
- [Beobachtung ohne Befund](#beobachtung-ohne-befund)
- [Mitgeliefertes Log](#mitgeliefertes-log)
- [Fehlerart je Befund](#fehlerart-je-befund)
- [Altcode-Marke je Befund](#altcode-marke-je-befund)
- [Beim Sammeln pro Punkt festlegen](#beim-sammeln-pro-punkt-festlegen)

Wonach in Phase 1 gezielt gesucht wird, was pro gesammeltem Punkt festzulegen ist, und die
beiden Kasuistiken der Schritte 1 und 2. Phase 3 wendet denselben Katalog auf das neu
Dazugekommene an.

## Fehlendes Artefakt — wann es blockt

**Ein fehlendes Artefakt blockt nur, wenn der PR es beansprucht** — sonst traefe die Regel
jeden kleinen Touch-PR und jeden Alt-PR aus der Zeit davor, und zwei Absaetze weiter steht,
dass ein Touch-PR knapp bleiben darf:
- **Spec-Datei** — nur, wenn der Auftrag eine `REQ`-Liste trug (`.agents/rules/pr.md` § "Task
  Spec" bindet die Datei ausdruecklich daran).
- **Tracking Issue** — wo die Aufgabe aus einem Design kommt; es entsteht dort immer, auch ohne
  offenen Punkt (`.agents/rules/carrier.md` § "Tracking Issue"); die Ausnahme fuer den PR aus
  Auftragstext steht in `.agents/rules/pr.md` § "Task Spec". Fehlt das Tracking Issue, wo es
  verlangt ist, ist das der Befund, unabhaengig davon, ob dieser PR selbst Punkte zurueckstellt.
- **Decision-Log** — nur, wenn der PR sich darauf beruft.

Fehlt eines in einem PR, der es beansprucht, ist das ein `issue: (blocking)`: ohne Spec-Datei
ist die Vollstaendigkeit nicht pruefbar, ohne Anker haben die offenen Punkte keinen Ort.

## Sub-Agent-Passes und Modellwahl

- **Sub-Agent-Parallelisierung bei grossen/breiten PRs:** parallele Spezial-Passes starten
  (Security, Quality+Reuse, Tests, Docs — die Passes des Reviewers, nicht die Autor-Wellen aus
  `review-modes.md`), jeder gegen die Kriterien aus Schritt 3 (Red-Flags,
  Test-Evidence, Konsistenz). Als Coordinator: Punkte deduplizieren, das Label je Punkt
  festlegen, false positives filtern, **einen** konsolidierten Punkte-Satz bilden.
- **Modell je Pass nach `.agents/rules/agents.md` § "Models".** Die parallelen Passes bilden eine
  Review-Welle, der Coordinator benennt ihren kritischen Schwerpunkt. Jeder Pass ist eine
  Teilpruefung im Review, auch ein leichter Docs- oder Konsistenz-Pass.

## Agent-Red-Flags (zuerst, harte Sachen)

- **CI-Gaming** — Tests entfernt/geskippt/umbenannt, Coverage-Threshold gesenkt, `|| true`
  angehaengt, Workflow-Trigger eingeschraenkt. Immer ein **`issue: (blocking)`**, ohne Ausnahme.
- **Reuse-Blindness** — pro neuer Util/Helper/Klasse kurz im Repo nach einem bestehenden
  Aequivalent suchen. Dupliziert der PR vorhandene Logik: Konsolidierung im selben PR
  erzwingen, nicht nur kommentieren. Hoechster Review-ROI bei Agent-Code.
- **Hallucinated Correctness** — kompiliert + Tests gruen heisst nicht korrekt. Einen
  kritischen Pfad end-to-end tracen; Boundary-Conditions und Permission-Checks auf den
  *nicht* getesteten Branches pruefen.
- **Prompt-Injection** — bei jedem Pfad, der untrusted Input (Webhook-Payload, Issue-/PR-Text)
  in einen LLM-/Shell-Aufruf fuehrt.

## Doku-Integritaet

- **Doku-Integritaet (mit den vorhandenen Tools pruefen, nicht nur ueberfliegen):** aendert der
  PR Docs oder legt er ein mitgeliefertes Dokument ab, wird dessen Stand am PR-Head
  verifiziert (`get_file_contents` am Head-SHA bzw. `gh`), nicht dem PR-Body geglaubt.
  - **Mitgeliefertes Decision-Log / uebergebenes Dokument verbatim?** Behauptet der PR
    "verbatim / unveraendert uebernommen", die Datei am Head aber gegen die Quelle pruefen:
    zerstoertes Markdown (Header/`##`/`---`/Bold kollabiert, Zeilen zusammengezogen), fehlende
    Abschnitte, halbierte Zeilenzahl → `issue:`. Uebergeben wird per Datei-Anhang, der die Bytes
    identisch haelt; zerstoertes Markdown ist genau das Signal, dass doch der Chat-Weg
    (Rendering + Copy-Paste) genommen wurde. Pruefpunkt dafuer: eine Transport-Datei traegt als
    erste Zeile den Marker `<!-- transport: verbatim, do not re-render -->` — fehlt er in einer
    als verbatim deklarierten Uebernahme, ist das ein Indiz und wird mitgemeldet.
  - **Belege leben am Head?** Zitiert eine geaenderte Doc-Stelle einen Beleg-Anker
    (Symbol-/Testname, SHA-Permalink) oder einen
    Marker (`[met]`/`[partial]`/`[planned]`; alte Formen `[erfuellt]`/`[teilweise]`/`[geplant]`
    gelten bis Playbook 26.0.0), stichprobenartig gegen den Head-Stand
    gegenpruefen: verweist der Beleg auf in diesem PR geloeschten/umbenannten Code
    (tote Belegstelle), oder widerspricht der Marker dem Gebauten → `issue:`. Besonders bei
    Retire-/Umzugs-PRs und Soll/Ist-markierten Architektur-Docs. **Das gilt fuer Belege, die im
    Repo-Text stehen** — nicht fuer die Spec-Datei, die keine mehr traegt.
  - **`[met]`-Marker gegen Dateiliste.** Wird im Diff ein Marker von `[planned]`/
    `[partial]` auf `[met]` gezogen, gegen die Dateiliste des PRs halten: deckt die
    Aussage eine Oberflaeche oder Komponente ab, zu der der Diff keine Datei enthaelt →
    `issue:`, auch wenn der danebenstehende Beleg plausibel klingt.
  - **Spec-Datei gegen das Issue.** Die Form der Spec-Datei (Pfad, eine widerlegbare Aussage je
    REQ, lueckenlose Nummern, Haken oder `not delivered: <reason>`) steht in `.agents/rules/pr.md`
    § "Task Spec"; eine `REQ`-Tasklist **im Body** statt der verlinkten Datei ist ein `issue:`. Die
    Datei wird **gegen das Issue** geprueft, nicht nur in sich: deckt sie den Auftrag des Issues ab
    und haelt sie die Form? Ob die Aussage stimmt, wird **am Diff** geprueft, nicht an einer
    Beleg-Zeile — die Datei traegt keine. Eine Umsetzung im Diff, die zu keinem REQ gehoert, bleibt
    ein Punkt: Scope-Ueberschuss ist ein Befund wie eine Luecke.
  - **Auftrag woertlich (Pruefung A).** Traegt die Spec den Auftrag des Maintainers
    (`.agents/rules/pr.md` § "Task Spec"), wird jeder seiner Saetze geprueft: hat er ein REQ oder
    ein `not implemented: <reason>`, ist das REQ geliefert, und sagt es dasselbe wie der Satz? Fehlt
    ein Satz, weicht ein REQ ab, oder fehlt der Wortlaut in einer Spec, deren Auftrag vom
    Maintainer kam → `issue: (blocking)`.
  - **Verbleib ueber Sprachgrenzen:** wo das Repo eine Verbleib-Tabelle (remains table) fuehrt
    (im Playbook `docs/remains/`, bis Playbook 26.0.0 auch `docs/verbleib/`), wird jede Zeile,
    deren Satz deutsch und deren Ziel englisch ist oder umgekehrt, von Hand gegen ihr Ziel gehalten — steht die Aussage dort nicht, ist das ein
    `issue: (blocking)`.
  - **Wellen-Bericht (konditional).** Nur pruefen, wenn der PR-Body Review-Wellen behauptet oder
    die Spec-Datei am Head den Review-Modus `hard vN` traegt (Zeile `Review-Mode:`). Dann wird der
    Bericht gegen den aktuellen Baustein in `review-modes.md` geprueft (Form der Zeile je Welle,
    Abbruch, Cap); fehlender oder unplausibler Bericht → `issue:`. Restpunkte nach dem Cap prueft
    Punkt 5 bzw. der Backlog-Gegencheck unten, nicht dieser Punkt. Traegt die Spec `light` oder
    `soft` — oder gar keinen Modus — und behauptet der Body keine Wellen, ist ein fehlender Bericht
    **kein** Befund.

## Doku-Delta

- **Verhaltensaenderung ohne Doku-Delta ist ein `issue: (blocking)`** (`.agents/rules/review.md`
  § "Review Comments"). Als Dokument zaehlen Architektur-/Baseline-Doc, `README.md`, `docs/**`,
  `CLAUDE.md`, ein Skill, eine Regeldatei, die Comment-Based-Help eines Skripts; ein Befund ohne
  Ermessen, denn die Aussage dort ist ab dem Merge unwahr.
- **Gesucht wird mechanisch:** je geaenderter Oberflaeche (Funktions-, Skript-, Parameter-,
  Konfigurations- oder Schaltername, Meldungstext, Pfad, Default) `git grep` ueber die
  Dokumente am Head; jeder Treffer, dessen Aussage der Diff unwahr macht, wird gegen die Dateiliste
  des PRs gehalten.
- **Abgrenzung.** Nur was der Diff **unwahr** macht, blockt; was ein Dokument bloss ergaenzen
  koennte, ist eine `backlog.md`-Zeile (`.agents/rules/docs.md` § "Documentation"). Datierte
  Schnappschuesse sind ausgenommen; welche das sind, steht in `.agents/rules/docs.md` § "Correcting
  a Value".

## Mechanismus und zweite Fundstelle

Zwei Pruefpunkte fuer jeden Diff, der Regel- oder Skill-Text aendert (`AGENTS.md`, `.agents/**`,
`.claude/skills/**`, `docs/common/**`, `.agents/tech/**`, Hooks):

- **Gibt es den Mechanismus?** Jeder neue oder geaenderte Satz, der einen Mechanismus nennt — ein
  Skript, einen Parameter, einen Hook, ein Werkzeug, eine Faehigkeit, einen Endpunkt, ein Feld, das
  etwas liest —, wird gegen Code oder Doku gehalten, mit `Datei:Zeile` am Head bzw. URL der
  Hersteller-Doku. Laesst sich der Mechanismus nicht finden oder tut er anderes als der Satz sagt,
  ist das ein `issue: (blocking)`; der Report nennt je Satz den Beleg.
- **Steht die Vorgabe schon woanders?** Jede neue oder geaenderte Vorgabe wird per `git grep` nach
  ihren tragenden Woertern auf eine zweite Fundstelle gesucht. Steht sie schon an anderer Stelle,
  gilt die Rangfolge aus `.agents/rules/docs.md` § "Rules Stand Once": die hoehere Stelle traegt sie, die andere
  verweist nur; eine zweite Fassung ist ein `issue: (blocking)`, eine widersprechende erst recht.

## Test-Evidence

- **Test-Evidence:** jede nicht-triviale Logikaenderung braucht einen Test, der auf dem
  Pre-Change-Verhalten fehlgeschlagen waere. Fehlt der: als Punkt aufnehmen — kann der Author
  keinen schreiben, ist der Fix unvollstaendig.

## Beleg-Pflicht

- **Beleg-Pflicht:** was sie verlangt und welcher Anker zaehlt, steht in `.agents/rules/evidence.md`
  § "Evidence Requirement" — nur fuer das, was der Reviewer **nicht im Diff sieht**; einen Beleg
  fuer Sichtbares einzufordern ist selbst der Fehler. Behauptet der Body einen Testlauf oder eine
  Messung ohne gueltigen Anker, oder beschoenigt er, was nicht real lief, ist das ein `issue:`.

## Mengenangaben

- **Mengenangaben ueber den Diff** verbietet `.agents/rules/pr.md` § "PR / MR Description". Steht
  dort eine, ist das ein `nitpick:`; nachgerechnet wird sie nicht. Testlauf-Ergebnisse sind keine
  Diff-Zahlen.

## Klassengroesse

- **Klassengroesse:** die Grenzen (Zeilen, Instanzfelder, eine Verantwortlichkeit, Ausnahmen) stehen
  in `.agents/rules/code.md` § "Code Conventions". Eine neue oder gewachsene Klasse darueber ohne
  Begruendung im PR-Body ist ein `issue:`.

## Kommentare

- **Ueberlange oder erzaehlende Kommentare** — die Regel steht in `.agents/rules/code.md` § "Code
  Comments"; hier nur die Einstufung, an Kommentaren, die der Diff neu schreibt oder aendert:
  - Zeile ueber 120 Zeichen, Review-Runden- oder Befund-Verweise, "hier stand frueher" oder Zitate
    frueherer Staende → `issue: (blocking)`.
  - Begruendung, die schon im Beleg-Dokument steht (Doppelung) → `issue: (blocking)`.
  - Begruendung nur ueber dem Richtwert von 1–3 Zeilen, ohne Doppelung →
    `suggestion: (non-blocking)`, sie ins Beleg-Dokument zu verlegen.
  - Fehlt dem Stack ein Werkzeug fuer die Zeilengrenze (das Overlay sagt es), ist dieser Punkt die
    Pruefung. Woertlich uebernommene Upstream-Kommentare sind ausgenommen.

## PR-Body vs. Diff

- **PR-Body-vs-Diff-Konsistenz:** auf Phantom Changes (Body behauptet Aenderungen, die nicht im
  Diff sind), Scope-Understatement (Diff tut mehr als der Body sagt) und Placeholder-
  Descriptions pruefen.
- **Schliess-Zeilen schon in Runde 1.** Je Issue, das der PR-Body oder eine geaenderte
  Wahrheitsquelle als von diesem PR erledigt fuehrt, das Issue am Head lesen: offen? Checkliste,
  und steht darin noch ein unabgehakter Punkt? Ist es offen und ohne offenen Punkt, verlangt der
  Review eine Auto-Close-Zeile dafuer (`issue: (blocking)`), sonst begruendet er ihr Fehlen in
  einem Satz — gerechnet nach `reference/gates.md` § "Hard-Gate Punkt 5". Das `[HARD-GATE]` in
  Phase 4 rechnet dasselbe nur nach; laeuft die Pruefung erst dort, kostet ein fehlendes `Closes`
  eine eigene Runde.

## Backlog-Gegencheck

- **Backlog-Gegencheck (beide Richtungen).** Erledigt der PR einen Eintrag, der in
  `backlog.md`, `roadmap.md` oder einem Issue als offen gefuehrt wird, **muss er ihn im selben
  PR streichen** (durchstreichen, nicht loeschen) — sonst taucht er in der naechsten
  Design-Runde wieder als offen auf und beschreibt womoeglich einen Stand, den es nicht mehr
  gibt. Umgekehrt gilt: was der PR offen laesst, steht an einem gueltigen Traeger
  (`.agents/rules/carrier.md` § "Carrier Requirement"). Bei Doku-Nachzuegen die Wahrheitsquellen
  **einzeln** gegenpruefen — `architecture.md`, `roadmap.md`, `backlog.md`, betroffene Nutzer-Docs;
  eine Sammelformel ("die Doku nachziehen") laesst genau die Quelle durchfallen, die niemand im Kopf
  hat.
- **Neue Traeger-Zeilen gegen die eigenen Dateien des PRs halten — mechanisch, an jedem Traeger**
  (`.agents/rules/carrier.md` § "Carrier Requirement", `.agents/rules/review.md` § "Review
  Comments"). `scripts/common/find-moved-fixes.ps1 -Repo <repo> -Pr <n>` fahren: es haelt jede
  Zeile, die waehrend des PRs neu in den Body des Tracking Issues, in `roadmap.md` oder in
  `backlog.md` kommt, gegen die Dateiliste des PR-Diffs. Jeder Eintrag `moved-fix` ist ein
  `issue: (blocking)`, ohne Ermessen und unabhaengig davon, wie plausibel die Zeile klingt. Ein
  Eintrag `no-known-fix` (die Zeile traegt `**No known fix:**`) blockt nicht von selbst: er
  steht in der Tabelle "Verschobenes", und der Grund wird am Diff geprueft — ist der Fix doch
  bekannt, ist es wieder ein `issue: (blocking)`. Ebenso ein Eintrag `foreign-repo-only` (die Zeile
  traegt `**Foreign repo only:** <owner/repo#N>`): geprueft wird, dass der Fix wirklich nur im
  genannten Repo liegt und die Zeile das dort angelegte, offene Issue verlinkt; fehlt das Issue oder
  liegt der Fix doch hier, ist es wieder ein `issue: (blocking)`. Ebenso ein Eintrag `own-pr` (die
  Zeile traegt `**Own PR:** <owner/repo#N>`): geprueft wird, dass `#N` existiert, offen ist und
  die Arbeit beauftragt; sonst ist es wieder ein `issue: (blocking)`. Ein Treffer aus dem Tracking
  Issue nennt in `Origin` die Bearbeitung, die ihn schrieb: gehoert sie belegt zu einem parallelen
  PR desselben Designs, ist die Zeile nicht die dieses PRs und zaehlt hier nicht.
  `SOURCE UNAVAILABLE` ist keine leere Liste: die betroffene Quelle wird von Hand gegen die
  Dateiliste gehalten, und der Report sagt das.

## Beobachtung ohne Befund

- **Beobachtung ohne Befund.** Ein heute gruener Mechanismus mit erkennbarem kuenftigem
  Bruchrisiko ist kein Punkt mit Label. Er wird als **Beobachtung** gesammelt und
  bekommt seinen Platz im Verdikt (Schritt 4, Stufe A) — nicht weggelassen, nicht zum `issue:`
  hochgestuft, nicht zur Abstimmung gestellt.

## Mitgeliefertes Log

- **Mitgeliefertes Log gegen die Review-Runden gelesen?** Ein Decision-Log, das **in diesem PR
  neu entsteht**, traegt dessen Endstand — die Review-Runden liegen nach seiner Niederschrift.
  Pruefen: steht dort ein Punkt noch als ungetragen, der inzwischen einen Traeger hat?
  Beschreibt es einen Scope, den der reale Diff nicht mehr hat? Dann fehlt der Abschnitt
  `## Nachtraege aus den Review-Runden` am Ende des Files → `issue:`. **Das hebt den
  Verbatim-Check oben nicht auf:** der uebergebene Entscheidungstext bleibt byte-identisch, der
  Nachtrag steht abgesetzt darunter (`docs/decisions/README.md` § Immutabilitaet).

## Fehlerart je Befund

Die Regel steht in `.agents/rules/review.md` § "Review Comments"; hier der Ablauf je `issue:`:

1. **Fehlerart benennen** — die Klasse, nicht die Stelle ("Pfad ohne `-LiteralPath`", nicht
   "Zeile 40").
2. **Eine Suche, ein Befehl** — `git grep -n -E '<muster>' -- <pfade>` oder ein Skript, das ueber
   die Dateien des PRs und den Code laeuft, den er beruehrt (Aufrufer, Geschwister-Skripte, die
   Tests daneben). Der Befehl steht woertlich im Bericht.
3. **Alle Fundstellen** am Head lesen und nennen; jede echte Fundstelle gehoert zum selben Punkt,
   keine wird als eigener Punkt der naechsten Runde aufgehoben.
4. **Phase 3** wiederholt denselben Befehl am neuen Head: ein Treffer, der noch die Fehlerart
   traegt, heisst "nicht adressiert", auch wenn die zuerst gemeldete Stelle gefixt ist. Trifft die
   Folgerunde eine Stelle der Fehlerart, die der Befehl nicht fand, bleibt es derselbe Punkt: der
   Befehl wird korrigiert, neu ueber den ganzen PR gefahren und mit allen Fundstellen neu gepostet.

## Altcode-Marke je Befund

Fester Schritt je Befund, vor dem Bericht: **gehoert die Zeile zu den `+`-Zeilen des PR-Diffs?**
Nein — die Zeile stand so schon am Basis-Commit — dann traegt der Punkt `(pre-existing)` hinter
seiner Blockier-Dekoration, mit dem Beleg aus `.agents/rules/review.md` § "Review Comments"
(`git blame` am Basis-Commit). Ob er blockt, entscheidet die Marke nicht.

## Beim Sammeln pro Punkt festlegen

Fuer jeden gesammelten Punkt wird festgelegt (fuer die Freigabe in Schritt 4):

- **Label und Dekoration**, nach `.agents/rules/review.md` § "Review Comments" (Tabelle, Nit-Regel);
  wo mehrere Wege valide sind oder die Wahl an Kontext haengt, den nur der User hat, ist es eine
  `question: (blocking)`, nie ein als `issue:` verkleideter Rat. Je `issue:` dazu Fehlerart, Suche und
  Fundstellen (§ "Fehlerart je Befund") und je Befund die Altcode-Pruefung (§ "Altcode-Marke je
  Befund").
- **Architektur-Widerspruch — kein Label.** Wie er behandelt wird und dass bis zur Design-Runde kein
  positives Abschluss-Verdikt faellt, steht in `.agents/rules/review.md` § "Review Comments".
- **Autor-Punkte:** Unter "Open questions", "Observations" und "Deliberately not changed" steht je
  Punkt nur der Link auf seinen Traeger, eine Umgebungsfeststellung gehoert unter "How tested"
  (`.agents/rules/pr.md` § "PR / MR Description"; alte Ueberschriften "Offene Fragen" / "Bewusst
  nicht" / "Wie getestet" gelten bis Playbook 26.0.0). Jeder dieser Links bekommt **genau eine eigene
  F-Nummer**; kein Buendeln, kein Weglassen mit der Begruendung "ausserhalb des Auftrags" oder "vom
  Autor korrekt eingeordnet" — **ob ein Punkt ausserhalb bleibt, entscheidet der User, nicht der
  Review**. Die eigenen Funde zaehlen zusaetzlich. Steht dort statt eines Links ausformulierter
  Text, ist das ein `nitpick:`; eine Umgebungsfeststellung dort ist **kein** offener Punkt.
- **Tracking Issue — eine Pruefung statt N.** Was der Review am Tracking Issue prueft, steht in
  `.agents/rules/carrier.md` § "Tracking Issue" (letzter Punkt), welche Orte gueltig sind, in
  § "Carrier Requirement" — dort auch, wer den Punkt eintraegt und wann eine Weitergabe an eine
  kuenftige Scheibe zaehlt. Alles am Head nachgelesen, nie der Angabe im PR-Body geglaubt. Ein
  `nitpick:` wird hier nicht mitgezaehlt. Editiert der Reviewer den Body selbst, dann mit
  `scripts/common/edit-issue-body.ps1`.
- **Was dem Menschen vorgelegt wird — gefiltert, nicht gestrichen.** Zur Abstimmung geht nur eine
  `question: (blocking)` (die Faelle: Tabelle in `.agents/rules/review.md` § "Review Comments").
  Alles andere bleibt eine **Beobachtung** und
  steht mit der Einschaetzung des Reviewers im Verdikt, ohne Abstimmung. Der Test ist einfach:
  lautet die eigene Empfehlung "akzeptieren" oder "stehenlassen", war es keine Frage.
- **Blockende Fragen aufbereiten:** die Form, samt was bei fehlendem Beleg gilt, steht in
  `ccweb-prompt` § "Schritt 1: Design-Runde und Tracking Issue"; `reference/report.md` (§ "Stufe A —
  Chat-Report", Offene Fragen) verweist darauf. Die Empfehlung ist immer
  Claudes eigener, begruendeter Rat.
