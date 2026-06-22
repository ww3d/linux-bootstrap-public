---
description: Quittiere den Lesestand (Konventionen / Profil / Memory) auf Zuruf
---

Zeige den aktuellen Read-Confirmation-Stand dieser Session — dieselbe Quittung,
die der SessionStart-Hook `read-confirm.sh` automatisch zu Session-Beginn in den
Kontext injiziert, hier auf Zuruf ("was hast du gelesen").

## Vorgehen

1. Führe den generischen Hook aus und lies seine Ausgabe:

   ```
   CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}" \
     bash "${CLAUDE_PROJECT_DIR:-$PWD}/.claude/hooks/read-confirm.sh"
   ```

   Die Ausgabe ist ein JSON-Objekt; der Quittungstext steht in
   `.hookSpecificOutput.additionalContext`.

2. Falls `jq` verfügbar ist, extrahiere den Text mit
   `... | jq -r '.hookSpecificOutput.additionalContext'`; sonst lies das Feld aus
   dem JSON heraus.

3. Gib die drei Gruppen (Konventionen / Profil / Memory) als Einzeiler je Datei
   unter ihren Gruppen-Headern mit dem jeweiligen OK aus — genau so, wie der Hook
   sie liefert. Was eine Umgebung nicht sehen kann, bleibt ehrlich als
   "— (nicht verfuegbar in dieser Umgebung)" markiert; nichts wird weggelassen
   oder erfunden.

## Usage

```
/read-check
```
