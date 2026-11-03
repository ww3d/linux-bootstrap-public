# Spec-Datei bauen

Gelesen und quittiert vor Schritt 3 des Skills. Die Spec-Datei `docs/tasks/<issue>-<slug>.md` ist
der Auftrag an die Dev-Session (`SKILL.md`). Ihre Form
(Frontmatter, Haken, kein Beleg je REQ) steht in `.agents/rules/pr.md` § "Task Spec" und wird hier
nicht gedoppelt; hier steht, was die Design-Session hineinschreibt.

## Lese-Auftrag

Bei Repos mit AGENTS.md / CLAUDE.md beginnt die Spec mit dem Lese-Auftrag
(*"Session-Start-Pflicht aus AGENTS.md § 'Session Start: Read Before Anything Else' gilt:
Pflichtkern (AGENTS-Kern, CLAUDE.md, Audit-Kopf) vollstaendig lesen und je Datei mit Blob-SHA
quittieren, BEVOR irgendetwas anderes passiert; die Regeldatei zu einem Trigger vor der ersten
Aktion dieses Typs, ebenfalls mit Quittung. Bei Widerspruch Spec vs. Docs gewinnen Docs — ausser
die Spec setzt eine Entscheidung um, die die Docs aendern soll."*), danach die acht Bloecke. Diese
Ausnahme steht nur hier; Skills, die die Spec lesen, verweisen auf diesen Lese-Auftrag.

**Modell-Angabe:** die Zeile `Dev-Model: <modell>` nach `.agents/rules/agents.md` § "Models"; der Controller
startet die Dev-Session damit (`controller-mode` § "Schritt 4: Steuern").

## Die acht Bloecke

Vor den Bloecken: der Auftrag des Maintainers woertlich — Form und Pflicht in
`.agents/rules/pr.md` § "Task Spec".

1. **Kontext** — Anlass, relevante Issues (*"Lies Issue #N vollstaendig"*), Decision-Log und
   Zeilen-Datei der Runde, der Branch, auf dem die Spec liegt.
2. **Aufgabe** — was konkret umzusetzen ist.
3. **Vorgaben** — die Aufgabe als nummerierte Liste `REQ-01`, `REQ-02`, … (ab mehr als 20 Punkten
   dreistellig: `REQ-001`), Form nach `.agents/rules/pr.md` § "Task Spec"; ID-Bereiche paralleler
   PRs nach `.agents/rules/audit.md` § "Design Round". Die IDs werden hier beim Bau vergeben, und
   der Schnitt in Aussagen liegt hier, nicht beim umsetzenden Agent: deckt eine Vorgabe mehrere
   Oberflaechen, Komponenten oder Lieferungen ab, wird sie beim Bau in mehrere REQs aufgeteilt.
   - **Herkunftszeile Pflicht:** die Spec verpflichtet den Agenten auf die Anker-Zeile nach
     `.agents/rules/pr.md` § "PR / MR Description" (`Closes` oder `Refs`).
   - **Groesse und Schnitt.** Die Design-Session schaetzt je PR die geaenderten Zeilen und Dateien —
     reine Verschiebungen und generierte Dateien zaehlen nicht — und nennt die Schaetzung im Block
     **Aufgabe**. Ziel sind rund 500 Zeilen und hoechstens 10 Dateien; ab 1.000 Zeilen oder 40
     Dateien schneidet sie in mehrere PRs nacheinander, je mit eigener Spec-Datei und eigenem
     REQ-Bereich, oder begruendet die Ausnahme im Decision-Log. Eine Sperre am PR gibt es nicht.
   - **Doku-Nachzug wird einzeln aufgezaehlt.** Verlangt die Spec, die Doku nachzuziehen, nennt sie
     jede Wahrheitsquelle **namentlich und je als eigenes `REQ-NN`** — `architecture.md`,
     `roadmap.md`, `backlog.md`, die betroffenen Nutzer-Docs. Eine Sammelformel ("die Doku
     nachziehen") laesst genau die Quelle durchfallen, die niemand im Kopf hat.
   - **Alles Baubare wird gebaut, getragen wird nur, was nicht baubar ist.** Die Spec verpflichtet
     den Agenten darauf und verweist fuer die Faelle, ihre Zeilen-Formen und die gueltigen Traeger
     auf `.agents/rules/carrier.md` § "Carrier Requirement"; der PR-Body allein zaehlt nicht, und
     eine Luecke in einer Datei des eigenen PRs mit bekanntem Fix gehoert in den PR.
   - **Und die Gegenrichtung, im selben Satz beauftragt: gelieferte Punkte werden abgehakt.** Die
     Spec verpflichtet den Agenten, jeden Punkt, den er aus dem Body des Tracking Issues liefert, im
     selben PR dort **abzuhaken** (`.agents/rules/carrier.md` § "Tracking Issue", dort auch warum);
     sonst beauftragt der Uebernahme-Check aus Schritt 2 in der naechsten Runde Gebautes erneut.
4. **Vorgehen** — schrittweise (Files sichten, aendern, testen).
5. **Gates** — Akzeptanz als ausfuehrbare Commands + pruefbare Kriterien (Build/Test gruen, keine
   Warnings), passend zum Test-Gate des Repos und seinem vollen Lauf aus `CLAUDE.md`
   (`.agents/rules/pr.md` § "Test Runs"). Beleg-Pflicht: `.agents/rules/evidence.md` § "Evidence
   Requirement".
6. **Review-Modus** — nur die Zeile `Review-Mode: <mode>` (z. B. `Review-Mode: hard v4`). Der
   Wortlaut des Bausteins steht an einer Stelle,
   [`pr-poll-review/reference/review-modes.md`](../../pr-poll-review/reference/review-modes.md),
   und wird nicht in die Spec kopiert.
7. **Nicht-Tun** — aufgabenspezifische Scope-Grenze (nur was fuer diese Aufgabe gilt; Generelles wie
   CI-Files oder Dependencies steht schon in AGENTS.md — nicht wiederholen).
8. **Erwartete Observations** — was der Agent im Abschluss meldet, inkl. ehrlicher Deklaration, was
   nicht real lief (fehlendes Docker / CLI / CI / Hardware) statt es zu beschoenigen.

## Review-Modus waehlen

**Heuristik fuer den Vorschlag:** Groesse, Kritikalitaet und Hot-Path-Naehe der Aufgabe. Breite oder
sicherheits-/performance-kritische Slices und alles, was in einen Hot Path fasst → `hard`. Mittlere
Aufgaben mit echtem Logik-Anteil → `light`. Konventions-, Doku- und Text-Aenderungen ohne
Algorithmus-Risiko → `soft`.

## Was NICHT in die Spec gehoert

Steckt in AGENTS.md / CLAUDE.md — der Agent kennt es:

- Keine PR-Body-Vorlage (der Agent schreibt die Description aus dem Diff).
- Keine Workflow-Boilerplate (Commit-Konvention, kein force-push, Draft-PR, nicht selbst mergen).
- Keine Branch-Namen-Vorgabe in der Spec: der Branch ist der, den die Design-Session mit Log,
  Zeilen-Datei und Spec gepusht hat (Schritt 4 des Skills); `dev-task` findet ihn ueber das Issue.
  Geht der Branch nicht vom Default-Branch aus: Basis im Issue nennen.

## Quellen in der Spec

Jede Quelle, die die Spec referenziert, besteht den Quellen-Erreichbarkeits-Check aus Schritt 2.
Unerreichbares wird nicht verlinkt, sondern **inline in die Spec** uebernommen; der Verweis bleibt
nur als Herkunftsangabe. Inline geht ausschliesslich **Zustand** (Issue-Text, Entscheidungen,
ausgeraeumte Fehlannahmen) — nie Regeln oder Konventionen; es gilt die Artefakt-Regel aus
`.agents/rules/docs.md` § "Generated Artifacts".
