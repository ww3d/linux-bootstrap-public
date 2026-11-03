# Gegenabgleich des Transcripts

Der Ablauf des Helfers, der einen Teil des Transcripts gegen die Traeger abgleicht: vor der
Verdichtung, sobald `remind-before-compact.sh` an der Grenze erinnert (Zeilen und Ergebnisdatei im
Hinweis), solange der volle Verlauf noch da ist; nach jeder Verdichtung fuer das Stueck seit der
Marke (`restore-compact-state.sh` nennt Zeilen und Ergebnisdatei im Hinweis); und vor jeder
Uebergabe (`SKILL.md`, Schritt 2). Er laeuft als
Unter-Agent mit Sonnet: die Session gibt ihm Transcript-Pfad, Zeilenbereich und Ergebnisdatei und
liest danach nur die Ergebnisdatei.

## Eingang

- **Transcript:** die JSONL-Datei der Session, eine Zeile je Eintrag.
- **Bereich:** `<von>-<bis>`, Zeilennummern der Datei. Der Bereich umfasst den neuesten Teil, auch
  die Zeilen nach der letzten Verdichtung — der Hinweis des Restore nennt ihn von der Zeile nach
  dem letzten Abgleich (`<gate>/<session>-cross-check-mark`, sonst 1) bis zum Transcript-Ende zur
  Zeit des Restore ([ww3d/playbook#487](https://github.com/ww3d/playbook/issues/487)). Vor einer
  Uebergabe ohne Hinweis: dieselbe Spanne. Er reicht zurueck ueber die Eintraege, die die
  Replay-Datei aus Platzgruenden weglaesst, und ueber den letzten Zug vor der Verdichtung — nicht,
  wo der Abgleich vor der Verdichtung die Marke gesetzt hat (`<n> pre`): bis dahin ist das
  Transcript selbst abgeglichen. Hinweis und Sperre nennen ihn in derselben Form.
- **Ergebnisdatei:** der Pfad aus dem Hinweis, vor einer Uebergabe eine Datei im Scratchpad.
- **Stuecke:** ein Bereich ueber 300 Zeilen laeuft in Stuecken von hoechstens 300 Zeilen; die
  Schritte 1 bis 3 gelten je Stueck, und die Ergebnisdatei waechst je Stueck um dessen offene
  Punkte.

## Ablauf

1. **Auszug.** Nur der Bereich, per `jq` ueber Bash — das Transcript ist zu gross fuer einen Read,
   und eine Zeile kann Megabytes tragen:

   ```bash
   MAIN_AGENT_IDS=$(jq -c '[inputs | select(.type == "assistant" and (.isSidechain | not))
       | .message.content[]? | select(.type == "tool_use"
           and (.name == "Agent" or .name == "Task" or .name == "Workflow"))
       | .id]' "$transcript")
   sed -n "${von},${bis}p;${bis}q" "$transcript" | jq -r --argjson main_agent_ids "$MAIN_AGENT_IDS" --argjson off "$((von - 1))" '
     (.timestamp // "")[0:16] as $t | (input_line_number + $off) as $z |
     (select(.isSidechain | not) |
       (select(.type == "user" and (.isMeta | not) and (.isCompactSummary | not)
               and ((.origin.kind? // "") != "task-notification")
               and ((.message.content | type) != "array"
                    or (any(.message.content[]?; .type? == "tool_result") | not)))
         | .message.content | if type == "string" then . else
           ([.[]? | select(.type == "text") | .text] | join("\n")) end
         | select(length > 0) | "IN  Z\($z) \($t) " + .[0:2000]),
       (select(.type == "attachment" and .attachment.type == "queued_command")
         | "IN  Z\($z) \($t) " + (.attachment.prompt | tostring)[0:2000]),
       (select(.type == "assistant") | .message.content[]? | select(.type == "text")
         | "OUT Z\($z) \($t) " + .text[0:2000]),
       # PEN: open points of the last compaction summary. The summary is isCompactSummary=true;
       # its "Pending Tasks" (or equivalent) section typically sits at the end, so the tail is
       # kept, not the head.
       (select(.type == "user" and .isCompactSummary == true)
         | .message.content | if type == "string" then . else
           ([.[]? | select(.type == "text") | .text] | join("\n")) end
         | select(length > 0) | "PEN Z\($z) \($t) " + .[-2000:]),
       # HLP: sub-agent results. Two shapes - a tool_result for an Agent/Task/Workflow tool_use of
       # the main thread (bash looks the id up in the $main_agent_ids list), and a
       # <task-notification> user line (background helper).
       (select(.type == "user" and ((.origin.kind? // "") == "task-notification"))
         | .message.content | if type == "string" then . else
           ([.[]? | select(.type == "text") | .text] | join("\n")) end
         | select(length > 0) | "HLP Z\($z) \($t) task-notification: " + .[0:2000]),
       (select(.type == "user" and (.message.content | type) == "array")
         | .message.content[]? | select(.type == "tool_result"
             and (.tool_use_id | type == "string")
             and (.tool_use_id | . as $i | $main_agent_ids | index($i)))
         | "HLP Z\($z) \($t) sub-agent " + (.tool_use_id)
         + ": " + ((.content | if type == "string" then . else
             ([.[]? | select(.type == "text") | .text] | join("\n")) end)[0:2000]))
     )'
   ```

   `$main_agent_ids` ist die Liste der `tool_use.id`-Werte, die der Hauptfaden fuer `Agent`,
   `Task` oder `Workflow` schrieb; der Bash-Vorlauf oben baut sie aus dem ganzen Transcript und
   gibt sie dem `jq` per `--argjson main_agent_ids "$MAIN_AGENT_IDS"`. `$off` setzt die
   Transcript-Zeilennummern um `von-1` nach oben, weil `sed -n "${von},${bis}p"` nur den
   Ausschnitt an `jq` liefert und `input_line_number` dann relativ zum Ausschnitt zaehlt — ohne
   das Offset waeren die `Z<n>`-Zeilen im Auszug und in der Ergebnisliste gegen das Transcript
   verschoben. `IN` ist jede Eingabe —
   Satz des Menschen, Nachricht einer anderen Session, vom Werkzeug eingespielter Auftrag; eine
   Nachricht, die waehrend eines Zugs eintrifft, steht als `queued_command` —, `OUT` jeder eigene
   Text der Session, `HLP` ein Helfer-Ergebnis (Vordergrund-Helfer als `tool_result` zu einem
   `Agent`/`Task`-Aufruf des Hauptfadens, Hintergrund-Helfer als `<task-notification>`-Text),
   `PEN` eine offene Zeile aus der letzten Verdichtungs-Zusammenfassung (`isCompactSummary`
   User-Zeile; die Zeilen unter "Pending Tasks" oder gleichwertig; PEN behaelt die letzten 2.000
   Zeichen, weil Pending-Zeilen am Ende der Zusammenfassung stehen). `Z<n>` ist die
   Transcript-Zeile. Normale Tool-Ergebnisse (zu einem anderen Werkzeug) fallen weg.
2. **Punkte sammeln:** jeder Satz des Menschen, der etwas verlangt, entscheidet oder fragt — eine
   Ruege (Kritik des Menschen am eigenen Vorgehen, etwa `"halt dich an die regeln"` oder
   `"nutzt du denn nicht mcp"`) zaehlt dabei als Verlangen und ist nur mit einer Traeger-Zeile zur
   gebrochenen Regel oder Erfahrung erledigt, eine Zusage im Chat ist keine; jede Nachricht einer
   anderen Session mit Auftrag, Antwort, Befund oder Frage; jede eigene Zusage (`"ich mache"`,
   `"folgt"`, `"trage nach"`); jeder eigene Vorschlag ohne Zukunftsform (`"besser ist eine feste
   Sperre: ..."`), der offen bleibt, bis er dem Menschen als Frage vorgelegt oder an einem Traeger
   abgelegt ist; jedes Helfer-Ergebnis (`HLP`), das einen Auftrag, eine Antwort, einen Befund oder
   eine Frage traegt; jede offene Zeile der letzten Zusammenfassung (`PEN`). Steht in der
   Replay-Datei des Restore `the compaction summary is not in the transcript yet`, pruefe die
   Eingaben des Menschen trotzdem gegen die Traeger — die Pruefung geht gegen den Traeger, nicht
   gegen die Zusammenfassung, so dass die spaete Zusammenfassung keine Luecke mehr ist. Die eigene
   Antwort des letzten Zugs vor der Verdichtung (der Hinweis nennt ihre Zeilen) wird in jedem Fall
   auf Zusagen geprueft: eine Zusage, die kein spaeteres Werkzeugergebnis und keine Traeger-Zeile
   belegt, ist ein Punkt.
3. **Abgleich je Punkt** gegen die Traeger am Head: Issue-Body und -Kommentare, PR-Body,
   Review-Threads, Spec-Datei, Decision-Log (`gh api`, `git grep`). Ein Punkt ist erledigt, wenn
   er dort steht oder gebaut ist; sonst ist er offen. Eine Frage ohne Antwort ist offen.
   Behauptet ein eigener Satz, etwas sei erledigt oder stehe am Traeger (`"steht im Issue"`, `"mit
   Testbefehl"`), wird der genannte Inhalt dort gelesen: dass der Traeger existiert, reicht nicht;
   fehlt der Inhalt, ist der Punkt offen.
4. **Ergebnis schreiben** — die Datei entsteht immer, auch ohne Fund, denn die Sperre wartet auf
   sie: je offenem Punkt eine Zeile `- [<Zeit UTC>] Zeilen <von>-<bis> <Herkunft>: <Kern in
   eigenen Worten> — fehlt an <Traeger>` (`<von>` und `<bis>` sind die `Z<n>`-Zeilen des Auszugs,
   die den Punkt tragen), ohne Fund im ganzen Bereich die eine Zeile
   `keine offenen Punkte (Zeilen <von>-<bis>)`.
   Erledigtes steht nicht darin.

## Grenzen

- Der Helfer schreibt nichts an Traeger und aendert nichts im Repo; Offenes traegt die Session
  nach, nachdem sie die Ergebnisdatei gelesen hat.
- Kein Zitat ueber einen Halbsatz hinaus, kein Geheimnis und kein Token in die Ergebnisdatei.
