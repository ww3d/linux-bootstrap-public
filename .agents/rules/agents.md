---
trigger: agents
read-before: starting a sub-agent or a session
budgetTokens: 1100
---

Read before: starting a sub-agent or a session

## Models

The models are the latest Haiku, Sonnet and Opus; no version numbers here. Model choice stands here
and nowhere else, for sessions, reviewers and sub-agents. The default per session kind also stands
as data, the field `model` of
[`.agents/session-kinds.json`](https://github.com/ww3d/playbook/blob/main/.agents/session-kinds.json)
— the same rule as data, not a second source; the playbook's check holds it equal to
the first point below. The field is only the default.

- Design, research, controller, review and orchestrator sessions run Opus; a dev session runs Sonnet, Opus
  only where the controller judges the change critical, intricate or sensitive — the design names
  the dev model in the spec, the controller confirms or overrides it.
- Review waves pick by focus: in every wave — single or follow-up — the critical focus runs Opus,
  every other focus Sonnet; the coordinator names the critical focus, in a follow-up wave split by
  area it is the area holding the fixes. A wave of one agent runs Opus.
- Haiku only for mechanical work that checks nothing (a search, a count, a reformat), never as a
  reviewer; every partial check inside a review runs Sonnet at least.
- Everything else: the cheapest model that manages the task, named explicitly — an omitted model
  inherits the session default.
- Fable only with the maintainer's release, for exactly the purpose named; it counts against the
  weekly allowance. A controller never releases it itself.
- A dated order of the maintainer (e.g. in the issue) overrides this until lifted. A safety-filter
  abort is reported.
- Where the harness offers no model choice, the step runs on what it gets and names that model —
  "unknown" when it cannot tell — marked as a deviation where a point above rules it out.

## Sub-Agents

- A § reference below that names no file is a heading of this file or of `AGENTS.md`.
- Extended `Glob`/`Grep`/`WebSearch`/`Bash` goes to Explore agents, extended `Edit`/`Bash` to
  general-purpose sub-agents (model: § "Models"). What `AGENTS.md` § "Session Start: Read Before
  Anything Else" asks for and what a statement of yours rests on you read yourself, in full:
  delegate only the exploring, never the reading that decides something. A sub-agent's result is
  checked before it is used.
- Use sub-agents wherever they speed the task up. Hand over files, not pasted prose — pasted context
  stays in your window every later turn: the brief as a file, the result as a file, back only status,
  commits, a one-line test summary.
- A sub-agent's files go to the session's scratchpad. It starts sub-agents of its own only with a
  reason.
- Mutation probes and test runs on one tree run through one agent; parallel readers use `git show`.
- Where the maintainer orders saving: no review waves beyond the mandatory ones, and before
  stopping, check that no sub-agent still runs — theirs keep running when the parent stops.
- Multi-step runs keep a git-ignored ledger `.agent/progress.md`, one line per finished task
  (`Task N: done <base7>..<head7>, review clean`); after a reset trust it and `git log`, and never
  re-run a task it marks done.

## Never: Ending Processes and Sessions

- End, restart or suspend a process you did not start in this session — shells, IDEs,
  `explorer.exe`, AI-CLI and agent-harness processes (`claude`, `codex`, `gemini`, `copilot`, …)
  and your own session host included — outside core rule 5; `.claude/hooks/guard-kill.sh` blocks
  shell commands, never asks.
- Only the orchestrator grants a foreign process (`.claude/hooks/lib/grant-kill.sh`), per number,
  once: a process of a session clone; on the maintainer's word that they are away (at
  most 12 h, journaled), any but the kept programs; never an AI-agent host or a process above one,
  the granter's own chain, the system's core.
- A session is ended only through the session-delivery tool, never by a shell command. A successor
  ends the one predecessor that named it in its hand-back, through that tool, once it holds the seat
  — the maintainer's standing yes under core rule 5 (`.agents/rules/pr.md` § "Controller Sessions"). A hung tool call is diagnosed, not shot.
