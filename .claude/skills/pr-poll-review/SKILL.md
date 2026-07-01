---
name: pr-poll-review
description: Reviewt einen GitHub Pull Request iterativ bis zum Approve und fuellt damit die `reviewer`-Rolle des Playbook-PR-Lifecycles. Schickt einen ersten Review (Inline-Comments + Summary), wartet auf neue Pushes des Authors — bevorzugt ueber `subscribe_pr_activity`-Events, als Fallback per Polling —, reviewt nach jeder Aenderung neu und approved erst wenn alle Punkte adressiert sind, CI gruen ist und keine Merge-Konflikte offen sind. Merged nie selbst. Triggert wenn der User einen PR reviewen UND bei OK approven lassen will: "review und wenn ok approve", "pr pollen", "check PR <ref>", "approve sobald die changes da sind". Nicht fuer einen einmaligen Review ohne Approve. Nutzt das GitHub MCP oder `gh`. Nur fuer GitHub-PRs (nicht GitLab/Forgejo).
---

# PR Review & Approve Workflow

Iterativer Review-Loop fuer GitHub-PRs. Faehrt von Erstreview bis Approve durch und fuellt die
`reviewer`-Rolle aus `AGENTS.md` § "PR Lifecycle" (Schritte 9-11). Der Merge (Schritt 12) bleibt
beim `maintainer` (`ww3d`) — dieser Skill merged nie.

## Eingabe

PR-Referenz, Pflicht (sonst danach **fragen**, nicht raten):

- `owner/repo#123` oder URL `https://github.com/owner/repo/pull/123`.

Optional (nur fuer den Polling-Fallback relevant):

- `poll_interval` — Sekunden zwischen Polls (Default: 30; Remote-API-Rate-Limits beachten).
- `max_iterations` — Review-Runden bevor abgebrochen wird (Default: 10).
- `timeout_minutes` — Gesamttimeout (Default: 60).

## Phase 1: Erstreview

1. Diff holen via `pull_request_read` (method=`get_diff`); bestehende Threads via
   `get_review_comments` lesen, um Doppel-Kommentare zu vermeiden.
2. Code durchgehen, Issues sammeln. Conventional Commits der Commit-Messages mitbewerten; den
   Default-Branch aus dem PR-Objekt lesen, nicht `master`/`main` annehmen.
3. Review erstellen via `pull_request_review_write`:
   - `event`: `COMMENT` (nur Hinweise) oder `REQUEST_CHANGES` (Blocker).
   - Inline-Comments mit `path` + `line` bevorzugen; Body mit knapper Zusammenfassung.
   - Suggested-Code-Changes auf Englisch.
4. Den Lifecycle-Trigger setzen: bei `REQUEST_CHANGES` den Autor anstossen, den PR auf Draft
   zuruecksetzen zu lassen (Schritt 10). HEAD-SHA des aktuellen Stands merken (`reviewed_sha`).

## Phase 2: Auf Aenderungen warten

- **Bevorzugt (Claude Code Web/Remote):** `subscribe_pr_activity` aufrufen und den Turn beenden.
  Neue Pushes und Kommentare kommen als `<github-webhook-activity>`-Events zurueck. **Nicht** mit
  `sleep` aktiv pollen.
- **Fallback (reiner cweb-Chat ohne Webhooks):** alle `poll_interval` Sekunden `pull_request_read`
  (method=`get`) abfragen und `head_sha` mit `reviewed_sha` vergleichen, bis er sich aendert oder
  `max_iterations` / `timeout_minutes` erreicht sind. Transiente API-Fehler tolerieren.

Webhooks liefern CI-Erfolg, neue Pushes und Merge-Konflikt-Uebergaenge nicht zuverlaessig — bei
Unsicherheit den PR-Zustand aktiv nachladen.

## Phase 3: Re-Review

1. Diff zwischen `reviewed_sha` und neuem `head_sha` holen.
2. Pro vorherigem Comment pruefen: Stelle geaendert? Punkt adressiert?
3. Auswertung:
   - **Alle adressiert, keine neuen Issues** → Phase 4.
   - **Rest- oder Neu-Issues** → neuer Review (`COMMENT` / `REQUEST_CHANGES`), `reviewed_sha`
     aktualisieren, zurueck zu Phase 2.

## Phase 4: Approve

<HARD-GATE>
Vor dem Approve, ausnahmslos — jeder Punkt muss erfuellt sein:

1. CI gruen — `pull_request_read` method=`get_check_runs`.
2. Keine Merge-Konflikte — bei `mergeable`/`mergeable_state` nicht clean **nicht** approven,
   Status melden.
3. Offene Threads anderer Reviewer — falls vorhanden, vor dem Approve darauf hinweisen.
4. PR-Body woertlich nach `Closes #` / `Fixes #` / `Resolves #` durchsuchen. Fehlt es — **nicht**
   approven (blocken, oder nach dem Merge manuell schliessen).
5. Self-authored PR (Autor = `ww3-claude`/cweb): nur `event: COMMENT` erlaubt — APPROVE ist
   gesperrt.
6. Zwei getrennte Verdikte, beide gruen: **Spec** (tut der Diff genau das Bestellte, nichts zu
   viel/zu wenig?) und **Quality** (handwerklich sauber: Tests, Struktur, keine Magic Numbers?).
</HARD-GATE>

Diese Gedanken bedeuten STOP — du rationalisierst:

| Gedanke | Realitaet |
|---|---|
| "Key-Files reichen, der Rest ist Boilerplate" | Zeile fuer Zeile, kein Sampling. |
| "Sieht fertig aus, Closes-Check kann ich sparen" | Erst Punkt 4, dann Urteil. |
| "Spec passt schon, muss den Diff nicht gegenpruefen" | Spec-Verdikt ist eigenstaendig. |

Wenn sauber: `pull_request_review_write` mit `event`: `APPROVE` und knappem Body (Schritt 11). Den
Nutzer informieren: "PR #N approved. Merge **nicht** ausgefuehrt — `maintainer` (`ww3d`) merged."

## Phase 5: Funktionale Zusammenfassung

Nach dem Approve im **Chat** liefern (nicht im PR):

- Vorher/Nachher-Zustand
- Happy Path
- Edge Cases
- Was bewusst unberuehrt bleibt
- Architektonischer Beitrag

## Strikte Regeln

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
- GitHub MCP und `gh` sind gleichwertig (`AGENTS.md` § "Forge Tooling"); nicht mit einem
  umstaendlichen MCP-Tool kaempfen wenn `gh api` sauberer ist.
