---
name: ccweb-prompt
description: 'Baut den Auftrags-Prompt (in manchen Repos "TASK"), mit dem ein Coding-Agent eine Aufgabe in einem Repo umsetzt und einen Draft-PR oeffnet, plus den zugehoerigen Review-Prompt fuer den separaten Review-Chat; fuellt damit die Vorstufe der `dev`-Rolle des Playbook-PR-Lifecycles. Klaert bei Bedarf offene Entscheidungen in einer Design-Runde, haelt sie in einem Decision-Log fest, laedt den Repo-Kontext aus den Repo-Docs, fragt den Review-Modus ab (hard / light / soft, Vorschlag vorbelegt) und liefert Prompt, Decision-Log und Review-Prompt als Output-Dateien (`YYYY-MM-DDTHH-MM-SS-<art>.md`), nicht als Chat-Block. Der Prompt setzt nur Environment und Aufgabe — Workflow, PR-Format und Branch-Wahl kennt der Agent aus AGENTS.md/CLAUDE.md. Triggert bei Anfragen wie "prompt fuer ccweb", "bau mir einen task", "prompt fuer issue #N", "prompt generieren", "task.md bauen", "review-prompt bauen". Nutzt das GitHub MCP oder `gh`. Nur fuer GitHub-Repos.'
metadata:
  version: "3.0.0"
  source: ww3d/playbook
---

# Agent-Prompt (TASK) bauen

Erzeugt den Prompt, mit dem ein Coding-Agent eine Aufgabe umsetzt, und den passenden Review-Prompt
fuer den separaten Review-Chat. Fuellt die Handoff-Vorstufe der `dev`-Rolle aus `AGENTS.md`
§ "PR Lifecycle": der Prompt geht an den Agenten, der Agent (Rolle `dev`) oeffnet den PR. Dieser
Skill oeffnet keinen PR und schreibt keinen Code.

## Kernprinzip

- **Environment, nicht Framework:** Der Prompt setzt Kontext + Aufgabe. Alles, was in AGENTS.md /
  CLAUDE.md steht (Workflow, Commit-/PR-Konvention, Branch-Wahl), gehoert NICHT hinein — der Agent
  kennt es.
- **Docs gewinnen:** Bei Widerspruch Prompt vs. Repo-Docs gewinnen die Docs. Das steht im Prompt und
  gilt beim Bauen genauso — Repo-Fakten werden am Repo verifiziert, nicht aus dem Gedaechtnis gesetzt.
- **Discussion before artifacts:** Kein Prompt vor finalen Entscheidungen. Erst klaeren, dann Log,
  dann Prompt.
- **Datei-Transport:** Jedes Artefakt geht als Output-Datei raus, nie als Chat-Block (siehe
  "Ausgabe"). Chat-Text ist ein lossy Kanal.

## Eingabe

- Ziel-Repo (`owner/repo`) und die Aufgabe (frei oder Issue-Referenz `#N`).
- Fehlt eines: **fragen**, nicht raten.

## Schritt 0: Projekt-Typ pruefen

- **Code-Repo mit Coding-Flow:** normaler Prompt, weiter mit Schritt 1.
- **Reines Design-/Infra-/Doku-Projekt** ohne Coding-Agent-Flow: KEIN Prompt. Stattdessen
  Design-Diskussion + Decision-Log. Hier stoppen und das klarstellen.

## Schritt 1: Design-Runde (bei Bedarf)

Nicht-triviale Aufgaben erst durchentscheiden:

- Ein Thema pro Turn, am Ende "gibt es noch was?". Nicht selbststaendig weiterspringen.
- Ergebnis als Decision-Log (siehe unten), festgeschrieben **bevor** der Prompt entsteht.

## Schritt 2: Repo-Kontext laden

Am echten Repo verifizieren (GitHub MCP oder `gh`), nicht annehmen:

- `CLAUDE.md` + `docs/` (rekursiv) — Stack, Test-Gate, Architektur-Prinzipien, Overrides.
- Issue-/Label-Konvention und den Decision-Log-Ort des Repos (Konvention in `docs/decisions/README.md`
  — siehe unten).
- Betroffene Quell-Files, damit der Prompt sie gezielt benennen kann.
- **Quellen-Erreichbarkeits-Check:** Jede Quelle, die der Prompt referenziert (Issues,
  Decision-Logs, Konventions-Docs, fremde Repos), pruefen: existiert sie, ist sie gemergt/synced,
  und kann die **Ziel-Session** sie erreichen (Repo-Scope, Sandbox-Whitelist der Agent-Umgebung)?
  Unerreichbares wird nicht verlinkt, sondern **inline in den Prompt** uebernommen; der Verweis
  bleibt nur als Herkunftsangabe.

## Schritt 3: Prompt bauen

**Zuerst den Review-Modus abfragen — Pflicht, kein Prompt ohne diese Abfrage.** Der Skill schlaegt
selbst einen Modus vor (Heuristik unten) und fragt mit vorbelegtem Vorschlag:
"Review-Modus: hard / light / soft?". Der gewaehlte Baustein wird 1:1 aus dem Abschnitt
"Review-Modus-Bausteine" uebernommen, nie freihaendig formuliert.

Der Prompt ist ein **fenced `md`-Block** in der Ausgabe-Datei. Bei Repos mit AGENTS.md / CLAUDE.md
beginnt er mit dem Lese-Auftrag (*"Lies erst CLAUDE.md und alle Dateien unter docs/ rekursiv
vollstaendig; bei Widerspruch Prompt vs. Docs gewinnen Docs."*), danach acht Bloecke:

1. **Kontext** — Anlass, relevante Issues (*"Lies Issue #N vollstaendig"*).
2. **Aufgabe** — was konkret umzusetzen ist.
3. **Vorgaben** — die Aufgabe als nummerierte Checkbox-Liste `REQ-01`, `REQ-02`, … (ab mehr als 20
   Punkten dreistellig: `REQ-001`). IDs werden hier beim Bau vergeben und ueber alle Review-Runden
   hinweg **nie umnummeriert**. Jedes `REQ-NN` traegt **genau eine widerlegbare Aussage** — deckt
   eine Vorgabe mehrere Oberflaechen, Komponenten oder Lieferungen ab, wird sie beim Bau in mehrere
   REQs aufgeteilt (der Schnitt liegt hier, nicht beim umsetzenden Agent). Der Prompt verpflichtet
   den Agenten, diese Liste unveraendert als GitHub-Tasklist (`- [ ]`/`- [x]`) in den PR-Body zu
   uebernehmen: pro Punkt entweder Haken plus Beleg mit **stabilem Anker** oder unchecked plus
   `nicht geliefert: <Grund>` — Haken ohne Beleg und unchecked ohne Grund sind beide unzulaessig.
   Die "nicht geliefert"-Zeile ist ausdruecklich erlaubt und kein Makel.
   **Stabiler Anker** (`AGENTS.md` § "Evidence Requirement"): Test-/`It`-Name, Funktions-/
   Symbolname, Variablenname, Kommentar-Ueberschrift oder Permalink mit Commit-SHA (bevorzugt).
   Nacktes, branch-relatives `file:line` zaehlt nicht — der naechste Push verschiebt die Zeile.
   Zusaetzlich verpflichtet der Prompt den Agenten zur **Beleg-Stand-Zeile**: einmal oben im
   PR-Body der Commit-SHA, auf den sich die Belege beziehen ("Belege beziehen sich auf `<sha>`").
4. **Vorgehen** — schrittweise (Files sichten, aendern, testen).
5. **Gates** — Akzeptanz als ausfuehrbare Commands + pruefbare Kriterien (Build/Test gruen, keine
   Warnings), passend zum Test-Gate des Repos. Beleg-Pflicht: der Abschluss-Kommentar fuehrt jede
   Erfuellungs-Behauptung mit einem stabilen Anker aus Block 3.
6. **Review-Modus** — der gewaehlte Baustein, verbatim aus "Review-Modus-Bausteine".
7. **Nicht-Tun** — aufgabenspezifische Scope-Grenze (nur was fuer diese Aufgabe gilt; Generelles wie
   CI-Files oder Dependencies steht schon in AGENTS.md — nicht wiederholen).
8. **Erwartete Observations** — was der Agent im Abschluss-Kommentar meldet, inkl. ehrlicher
   Deklaration, was nicht real lief (fehlendes Docker / CLI / CI / Hardware) statt es zu
   beschoenigen.

**Model-Empfehlung (Pflicht):** In jedem Prompt das passende Modell explizit nennen, soweit der
Harness Modellwahl exponiert (`AGENTS.md` § "Working Mode"). Prinzip: das kleinste/schnellste Modell,
das die Aufgabe noch 100% sauber und SOTA loest. Bei parallelen Sub-Agenten waehlt jeder sein
kleinstes taugliches selbst, die Koordinator-Rolle das staerkste.

## Review-Modus-Bausteine

Drei feste Bausteine. **Wortlaut nie umformulieren** — nur der zutreffende Block wird kopiert; so
driften Modellwahl und Wellen-Regel nicht von Session zu Session weg.

**Heuristik fuer den Vorschlag:** Groesse, Kritikalitaet und Hot-Path-Naehe der Aufgabe. Breite oder
sicherheits-/performance-kritische Slices und alles, was in einen Hot Path fasst → `hard`. Mittlere
Aufgaben mit echtem Logik-Anteil → `light`. Konventions-, Doku- und Text-Aenderungen ohne
Algorithmus-Risiko → `soft`.

**hard** — traegt eine Versions-Kennung. Aktuell `hard v1`; sie wird hochgezaehlt, sobald sich
Modellwahl, Schwerpunkte, Loop-Regel oder Cap aendern. Der Prompt reicht die Kennung in den PR-Body
durch, damit der Reviewer weiss, gegen welche Fassung er prueft.

```md
Review-Modus: `hard v1`

Vor dem PR und vor jeder Fix-Runde eine parallele Welle von 3-4 Review-Sub-Agenten: frische
Sessions, verschiedene Modelle, verschiedene Schwerpunkte (Korrektheit/Randfaelle, Performance/Hot
Paths, Vertraege/Docs, Test-Luecken), alle auf demselben Commit-Stand. Befunde mergen/dedupen,
fixen; die naechste Welle verifiziert erst die Fixes. Befund = ab Severity minor. Loop, bis eine
komplette Welle ohne Befund bleibt. Hard-Cap 4 Wellen, der Rest als offene Punkte in den PR.

Wellen-Bericht im PR-Body ist Pflicht: je Welle eine Zeile mit Nummer, Modellen, Schwerpunkten und
Findings-Zahl (auch `0`); nach Cap 4 die Restpunkte benannt.
```

**light** — eine einzige Gegen-Welle. Fuer mittlere Aufgaben: 80% des Wertes zum Bruchteil der
Kosten. Kein Wellen-Bericht-Gate.

```md
Review-Modus: `light`

Eine einzige Gegen-Welle: 1 frischer Sub-Agent, anderes Modell, voller Gegencheck. Befunde fixen.
Kein Wellen-Bericht noetig.
```

**soft** — nur die Schleifen-Formel. Kein Bericht, kein Gate.

```md
Review-Modus: `soft`

Autonom bis zum Ende, Schleife bis perfekt und ohne Befunde: Self-Review + Refactoring-Runden,
Annahmen dokumentieren. Kein Wellen-Bericht noetig.
```

## Schritt 4: Review-Prompt bauen

Nach jedem gebauten Agent-Prompt einen zugehoerigen Review-Prompt fuer einen separaten Chat
erzeugen (dort laeuft Skill `pr-poll-review`). Der Review-Prompt ist eine **eigene Output-Datei**
(`…-review-prompt.md`), nie mit dem Agent-Prompt in einer Datei.

### Struktur (feste Reihenfolge)

1. **Kopfzeile:** "Review via Skill pr-poll-review: `owner/repo` PR #TBD (Umsetzung von <Aufgabe>) —
   reviewen und bei OK approven." Die PR-Nummer bleibt der feste Platzhalter `PR #TBD`, wenn der PR
   beim Bau noch nicht existiert; am Dateianfang steht die Hinweiszeile
   *"`PR #TBD` vor Verwendung ersetzen"*. Der Platzhalter ist bewusst grep-bar — ein halb
   ausgefuelltes `#XX` rutscht unbemerkt in die Review-Session.
2. **Review-Modus des Auftrags:** `hard vN` / `light` / `soft` benennen, damit der Reviewer
   weiss, ob das Wellen-Bericht-Gate ueberhaupt gilt (bei `light`/`soft` ist ein fehlender
   Bericht kein Finding).
3. **Soll-Abgleich:** Die verbindliche Spec benennen, gegen die Punkt fuer Punkt geprueft wird
   (Issue, Decision-Log, REQ-Liste). Wenn der Auftrag pruefbare Einzelnachweise definiert (z.B.
   Mutations-Proben, Belege je REQ mit stabilem Anker), ausdruecklich anweisen, sie stichprobenartig
   selbst nachzuvollziehen statt dem PR-Body zu glauben. Spec-Punkte, die durch eine
   Design-Entscheidung praezisiert wurden, mit Entscheidungs-Kennung und Log-Pfad im PR benennen,
   damit der Reviewer die gewollte Abweichung nicht als Befund meldet.
4. **CI-Rahmen:** Den Ist-Zustand der CI des Repos festhalten (welche Legs, was sie real pruefen,
   was lokal geskippt wird). Veraltete Praemissen explizit ausraeumen, wenn fruehere Sessions sie
   tragen koennten. Rote Checks als Blocker deklarieren.
5. **Scope-Wache:** Die Nicht-Tun-Grenzen des Auftrags-Prompts fuer den Reviewer wiederholen
   (erlaubte Ausnahmen eingeschlossen), damit Scope-Ueberschreitung als Befund erkannt wird — inkl.
   bewusst vertagter Nachbar-Issues, denen der PR nicht vorgreifen darf.
6. **Konstellation:** Autor-Account und Review-Account benennen und daraus das zulaessige Verdikt
   ableiten (cross-account → APPROVE erlaubt; self-authored → nur COMMENT mit explizitem
   Blocking-/OK-Vermerk). Wer merged, steht dabei (samt Merge-Strategie des Repos).
7. **Pflicht-Checks vor Approve:** Woertliche Suche nach `Closes #N` / `Fixes #N` / `Resolves #N` im
   PR-Body (englisch; deutsche Varianten triggern GitHubs Auto-Close nicht) — fehlt das Keyword:
   blocken mit Hinweis. Dazu die Beleg-Form: jeder Haken der REQ-Liste traegt einen stabilen Anker,
   ein Beleg aus nacktem branch-relativem `file:line` ist ein Finding. Weitere repo-spezifische
   Pflicht-Checks hier ergaenzen.
   *Der `Closes #N`-Check doppelt bewusst das Hard-Gate von `pr-poll-review` — die Redundanz ist
   gewollt, damit die beiden Skills bei Aenderungen nicht auseinanderlaufen.*
8. **Nach dem Merge:** Was danach zu tun oder bewusst NICHT zu tun ist (CI auf main pruefen,
   Tracking-Kommentare ja/nein mit Begruendung, welcher Punkt als naechstes dran ist).

### Regeln

- Nur uebertragen, was der Review-Chat nicht selbst am Repo lesen kann oder was
  session-uebergreifend verloren geht: Entscheidungen dieser Design-Runde, ausgeraeumte
  Fehlannahmen, Konstellation. Alles Verifizierbare (Diff, CI-Status, Issue-Text) liest der
  Review-Chat selbst — nicht paraphrasieren.
- Repo-Fakten im Review-Prompt sind beim Bau am Repo verifiziert, nie aus dem Gedaechtnis gesetzt.
- Kurz halten; der Prompt setzt Rahmen und Sonderwissen, der Skill kennt den Ablauf
  (Klassifikation, Wellen, Widget, Poll-Loop).
- Review-Schwerpunkte aus der Autoren-Session gehoeren **nicht** hinein — sie ankern den Reviewer
  und kosten genau die Objektivitaet, fuer die er ein eigener Chat ist.

## Was NICHT in den Prompt gehoert

Steckt in AGENTS.md / CLAUDE.md — der Agent kennt es:

- Keine PR-Body-Vorlage (der Agent schreibt die Description aus dem Diff).
- Keine Workflow-Boilerplate (Commit-Konvention, kein force-push, Draft-PR, nicht selbst mergen).
- Keine Branch-Namen-Vorgabe — der Agent waehlt selbst, Session startet auf dem Default-Branch.
  Einzige Ausnahme: Abzweig von einem Nicht-Default-Branch (dann Basis explizit nennen).

## Ausgabe

Alle Artefakte gehen als **Output-Datei** raus (`create_file` + `present_files`), nie als
Chat-Block. Feste Art-Taxonomie und Namensschema:

| Art             | Dateiname                                |
|-----------------|------------------------------------------|
| Agent-Prompt    | `YYYY-MM-DDTHH-MM-SS-prompt.md`          |
| Decision-Log    | `YYYY-MM-DDTHH-MM-SS-decision-log.md`    |
| Review-Prompt   | `YYYY-MM-DDTHH-MM-SS-review-prompt.md`   |

- Zeitstempel sekundengenau nach ISO 8601, Doppelpunkte durch Bindestriche ersetzt; die `.md`-Endung
  bleibt dran, sonst verliert der Client beim Download die Typ-Erkennung.
- Ein Artefakt pro Datei — Prompt, Log und Review-Prompt werden nie zusammengelegt.
- Jede Transport-Datei beginnt mit der Marker-Zeile `<!-- transport: verbatim, do not re-render -->`.
- **Uebergabe:** Datei herunterladen und in der Ziel-Session **als Datei anhaengen**, nicht den
  Inhalt hineinkopieren — Copy-Paste ueber gerenderten Chat zerstoert das Markdown.
- Nie ungefragt nach GitHub posten. Eine Fix-Anweisung fuer einen offenen PR geht als
  PR-Review-Kommentar (via MCP oder `gh`) nach expliziter Freigabe.

## Decision-Log

**Format, Dateiname und Ablage im Repo folgen der `docs/decisions/README.md` des jeweiligen
Consumers** — der kanonischen Decision-Log-Konvention (MADR-Light), abgeleitet aus dem
Playbook-Skelett `templates/docs/decisions-README.md`. Am Repo lesen, nicht annehmen; die
Format-Details (vier Pflicht-Sektionen plus eine optionale, Dateiname-Schema) hier nicht doppeln.
Default-Ablage ist `docs/decisions/`; fuehrt das Repo gar keine Logs, keins erzwingen.

**Transport und Ablage sind zwei Dinge.** Der Chat-Dateiname (`…-decision-log.md`) ist reiner
Transport zur Ziel-Session; der Agent legt den Inhalt unveraendert unter dem Repo-Dateinamen der
Consumer-Konvention ab.

Sobald der Agent den Draft-PR geoeffnet hat, liegt das Log im PR — ein Reviewer zieht es von dort
(nicht vom User weitergereicht).

## Strikte Regeln

- Nie einen Prompt unaufgefordert nach GitHub posten. Reine Status-Reads (PR/CI) sind ohne Freigabe ok.
- Neue Code-Level-Namen nicht annehmen — im Prompt offen lassen oder nachfragen. Bestehende
  (Fork-)Identifier nie unaufgefordert umbenennen.
- Verifizieren statt spekulieren: Repo-Fakten kommen aus dem Repo, nicht aus dem Gedaechtnis — und
  jede referenzierte Quelle muss fuer die Ziel-Session erreichbar sein (Schritt 2), sonst inline.
- Jedes Artefakt als Output-Datei mit Verbatim-Marker, nie als Chat-Block.
- Kein Prompt ohne die Review-Modus-Abfrage aus Schritt 3; der gewaehlte Baustein wird verbatim
  uebernommen.

## Repo-Konventionen

- `git` + `gh` sind Default fuer alle GitHub-Operationen (`AGENTS.md` § "Forge Tooling"); das
  GitHub MCP nur als Fallback oder fuer MCP-only-Tools.
- Rollen getrennt: der Agent oeffnet Draft-PRs (`dev`), der `maintainer` merged
  (`AGENTS.md` § "PR Lifecycle").
