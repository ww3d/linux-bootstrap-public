---
name: ccweb-prompt
description: 'Baut den Auftrags-Prompt (in manchen Repos "TASK"), mit dem ein Coding-Agent eine Aufgabe in einem Repo umsetzt und einen Draft-PR oeffnet, und fuellt damit die Vorstufe der `dev`-Rolle des Playbook-PR-Lifecycles. Klaert bei Bedarf offene Entscheidungen in einer Design-Runde, haelt sie in einem Decision-Log fest, laedt den Repo-Kontext aus den Repo-Docs und gibt den fertigen Prompt als 4-Backtick-Block zur Uebergabe aus. Der Prompt setzt nur Environment und Aufgabe — Workflow, PR-Format und Branch-Wahl kennt der Agent aus AGENTS.md/CLAUDE.md. Triggert bei Anfragen wie "prompt fuer ccweb", "bau mir einen task", "handoff fuer [repo]", "prompt fuer issue #N", "prompt generieren", "task.md bauen". Nutzt das GitHub MCP oder `gh`. Nur fuer GitHub-Repos.'
metadata:
  version: "1.8.1"
  source: ww3d/playbook
---

# Agent-Prompt (TASK) bauen

Erzeugt den Prompt, mit dem ein Coding-Agent eine Aufgabe umsetzt. Fuellt die Handoff-Vorstufe der
`dev`-Rolle aus `AGENTS.md` § "PR Lifecycle": der Prompt geht an den Agenten, der Agent (Rolle
`dev`) oeffnet den PR. Dieser Skill oeffnet keinen PR und schreibt keinen Code.

## Kernprinzip

- **Environment, nicht Framework:** Der Prompt setzt Kontext + Aufgabe. Alles, was in AGENTS.md /
  CLAUDE.md steht (Workflow, Commit-/PR-Konvention, Branch-Wahl), gehoert NICHT hinein — der Agent
  kennt es.
- **Docs gewinnen:** Bei Widerspruch Prompt vs. Repo-Docs gewinnen die Docs. Das steht im Prompt und
  gilt beim Bauen genauso — Repo-Fakten werden am Repo verifiziert, nicht aus dem Gedaechtnis gesetzt.
- **Discussion before artifacts:** Kein Prompt vor finalen Entscheidungen. Erst klaeren, dann Log,
  dann Prompt.

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
- Ergebnis als Decision-Log-Datei (siehe unten), festgeschrieben **bevor** der Prompt entsteht.

## Schritt 2: Repo-Kontext laden

Am echten Repo verifizieren (GitHub MCP oder `gh`), nicht annehmen:

- `CLAUDE.md` + `docs/` (rekursiv) — Stack, Test-Gate, Architektur-Prinzipien, Overrides.
- Issue-/Label-Konvention und den Decision-Log-Ort des Repos (variiert — siehe unten).
- Betroffene Quell-Files, damit der Prompt sie gezielt benennen kann.

## Schritt 3: Prompt bauen

Der Prompt ist ein **fenced `md`-Block**. Bei Repos mit AGENTS.md / CLAUDE.md beginnt er mit dem
Lese-Auftrag (*"Lies erst CLAUDE.md und alle Dateien unter docs/ rekursiv vollstaendig; bei
Widerspruch Prompt vs. Docs gewinnen Docs."*), danach sechs Bloecke:

1. **Kontext** — Anlass, relevante Issues (*"Lies Issue #N vollstaendig"*).
2. **Aufgabe** — was konkret umzusetzen ist.
3. **Vorgehen** — schrittweise (Files sichten, aendern, testen).
4. **Gates** — Akzeptanz als ausfuehrbare Commands + pruefbare Kriterien (Build/Test gruen, keine
   Warnings), passend zum Test-Gate des Repos.
5. **Nicht-Tun** — aufgabenspezifische Scope-Grenze (nur was fuer diese Aufgabe gilt; Generelles wie
   CI-Files oder Dependencies steht schon in AGENTS.md — nicht wiederholen).
6. **Erwartete Observations** — was der Agent im Abschluss-Kommentar meldet.

**Model-Empfehlung (Pflicht):** In jedem Prompt das passende Modell explizit nennen, soweit der
Harness Modellwahl exponiert (`AGENTS.md` § "Working Mode"). Prinzip: das kleinste/schnellste Modell,
das die Aufgabe noch 100% sauber und SOTA loest. Bei parallelen Sub-Agenten waehlt jeder sein
kleinstes taugliches selbst, die Koordinator-Rolle das staerkste.

## Was NICHT in den Prompt gehoert

Steckt in AGENTS.md / CLAUDE.md — der Agent kennt es:

- Keine PR-Body-Vorlage (der Agent schreibt die Description aus dem Diff).
- Keine Workflow-Boilerplate (Commit-Konvention, kein force-push, Draft-PR, nicht selbst mergen).
- Keine Branch-Namen-Vorgabe — der Agent waehlt selbst, Session startet auf dem Default-Branch.
  Einzige Ausnahme: Abzweig von einem Nicht-Default-Branch (dann Basis explizit nennen).

## Ausgabe

- Standalone-Prompt: inline als **4-Backtick**-Block (der Prompt enthaelt selbst Triple-Backticks).
  Nie ungefragt nach GitHub posten.
- Fix-Anweisung fuer einen offenen PR: als PR-Review-Kommentar (via MCP oder `gh`) nach expliziter
  Freigabe, nicht als Chat-Block.

## Decision-Log

Format `YYYY-MM-DDTHHMM-[projekt]-[phase]-decisions.md` via `create_file` + `present_files`,
immutable Point-in-Time, nie editieren. **Ablage-Ort ist repo-spezifisch** — am Repo lesen, nicht
annehmen: manche Repos fuehren einen `docs/decisions/`-Ordner (mehrere Logs), manche eine einzelne
Datei, manche gar keins. Fuehrt das Repo keins, keins erzwingen.

## Strikte Regeln

- Nie einen Prompt unaufgefordert nach GitHub posten. Reine Status-Reads (PR/CI) sind ohne Freigabe ok.
- Neue Code-Level-Namen nicht annehmen — im Prompt offen lassen oder nachfragen. Bestehende
  (Fork-)Identifier nie unaufgefordert umbenennen.
- Verifizieren statt spekulieren: Repo-Fakten kommen aus dem Repo, nicht aus dem Gedaechtnis.

## Repo-Konventionen

- GitHub MCP und `gh` sind gleichwertig (`AGENTS.md` § "Forge Tooling") — das saubere Werkzeug nehmen.
- Rollen getrennt: der Agent oeffnet Draft-PRs (`dev`), der `maintainer` merged
  (`AGENTS.md` § "PR Lifecycle").
