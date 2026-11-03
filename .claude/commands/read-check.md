---
description: Quittiere den Lesestand als Lese-Quittung (Version, Pruefsummen, Rules, Skills, Stop hook, Memory) auf Zuruf
---

Zeige den aktuellen Lesestand dieser Session — denselben Block, den der
SessionStart-Hook `read-confirm.sh` zu Session-Beginn als Vorlage in den Kontext
injiziert, hier auf Zuruf ("was hast du gelesen"). Die Form steht in `.agents/rules/session.md` § "Session Receipt".

## Vorgehen

1. Fuehre den generischen Hook aus und lies seine Ausgabe:

   ```
   CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" \
     bash "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/hooks/read-confirm.sh"
   ```

   Die Ausgabe ist ein JSON-Objekt; der Quittungstext steht in
   `.hookSpecificOutput.additionalContext`.

2. Falls `jq` verfuegbar ist, extrahiere den Text mit
   `... | jq -r '.hookSpecificOutput.additionalContext'`; sonst lies das Feld aus
   dem JSON heraus.

3. Gib den Block von `── Read receipt` bis zur Schlusslinie aus, in einem
   `diff`-Block, und trage den Stand dieser Session ein:
   - `+ … read` nur fuer eine Datei, die du in dieser Session vollstaendig gelesen
     hast (den Audit ab Zeile 1 bis zum Ende seiner Kurzfassung); `CLAUDE.md` und das
     mit einer Zeile `@AGENTS.md` eingebundene `AGENTS.md` zeigt die Vorlage schon gruen,
     weil der Start sie laedt.
     Eine vorhandene, nicht gelesene Kerndatei bleibt `- … not read`; `missing` und
     `not found` stehen, wie die Vorlage sie zeigt. Nichts als gelesen markieren, was
     nicht gelesen ist: die Stop-Sperre prueft jede gruene Zeile gegen die
     Mitschrift, und die Mitschrift sieht nur das Lesen mit dem Werkzeug Read.
   - Je Regeldatei, die du in dieser Session gelesen hast, eine Zeile
     `+ <datei>  <version>  <pruefsumme>  read (rule)` ueber der Zeile `Rules`, und
     `Rules <n> of <gesamt> read` mit der Zahl dieser Zeilen.
   Was eine Umgebung nicht sehen kann, bleibt ehrlich als
   "— (not available in this environment)" markiert; nichts wird weggelassen oder
   erfunden.

## Usage

```
/read-check
```
