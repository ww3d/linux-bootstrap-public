---
trigger: audit
read-before: starting a new slice or design round, running a state audit, or syncing from or diverging from a source
budgetTokens: 2100
---

Read before: starting a new slice or design round, running a state audit, or syncing from or diverging from a source

## State Audit

### Quick Check

Before every design round, the quick check runs the existing scripts — the audit work list, the
carrier sweep, the closable issues — and its result goes into the design's decision log as one line,
with no PR of its own. Mechanics: the `state-audit` skill.

### Full Audit

**A full audit is due only when** (a) the repo has none yet, or (c) more than 30 PRs were merged
since the last full audit — a repo sets its own threshold in `CLAUDE.md` (`**Audit threshold:**
<N>`; the earlier `Audit-Schwelle:` is read until playbook 26.0.0).
`pwsh scripts/common/get-audit-due.ps1` computes (a) and (c) with their figures; without the script,
count the merged PRs since the commit the latest audit names and check (a) by hand.

- Each baseline statement is checked against the code (`file:line` against the commit the audit
  names, `.agents/rules/evidence.md` § "Evidence Requirement"), the build and the test actually run.
- **The audit walks the tracking issues in both directions:** a `[planned]` / `[partial]` marker
  with no point at a valid carrier, and a tracking-issue point with no marker or line behind it, are
  both findings (`.agents/rules/carrier.md` § "Carrier Requirement").
- **Every mechanism marker is also held against the architecture section that governs it.** The code
  answers "was this built", not "does it still do what the architecture promises"; a marker whose code
  contradicts its section is a delta entry, never `[met]` — counting it as fulfilled without that
  second check is how a relocated trigger or a narrowed guarantee survives an audit unnoticed. This
  holds for `[partial]` and
  `[planned]` too: under a marker naming a missing guard the mechanism is checked, and where it is
  missing as well, marker and text are corrected (`.agents/rules/docs.md` § "Target vs. Actual").
- The result is `docs/audit/state-<YYYY-MM-DDTHHMMZ>.md` on its own branch (the earlier name
  `docs/audit/ist-stand-<stamp>.md` is read until playbook 26.0.0)
  (`.agents/rules/docs.md` § "Timestamps in File Names"); it leads with the metadata block, then a
  short-form section — the **audit head** every session reads (`AGENTS.md` § "Session Start: Read
  Before Anything Else"), so the result sits up front: an audit that buries it behind the
  per-statement detail is an audit nobody reads.
- The audit works off the doc catch-up lines in `backlog.md` (`.agents/rules/docs.md`
  § "Documentation"), index files included (`CLAUDE.md`, `README.md`, link lists under `docs/**`);
  it changes no production or test code — it corrects markers and enters points, everything else
  becomes an order of its own. A backlog line ages by time or by merged PRs since it was written, not
  by audit stamps: it is aged once more PRs than the audit threshold were merged since it, or more
  than 30 days passed, whichever comes first, and an aged line goes as a mandatory point into the
  tracking issue of the next slice.
- **The audit walks the repo's own divergences** (§ "Divergences From a Source").

## Design Round

- References the maintainer or the task names are read **in full before the first question**, and
  the decision log lists them.
- The search inside before the one outside, sister repos included: `AGENTS.md` § "Working Mode".
- Parallel PRs from one round get fixed ranges for IDs, diagnostic codes and numbers in the design,
  so no two hand out the same one.
- Where a decision log already decided, the work follows it without a new round.
- The round's points — accepted, rejected, deferred, superseded, ideas — go into its ledger file
  (`.agents/rules/pr.md` § "Round Ledger"); a
  point already rejected is reopened only with a new argument (`scripts/common/get-rejected-points.ps1`).
- A design statement about platform rights or behaviour is checked against the code or the vendor's
  documentation before anyone agrees to it.
- We want to be SOTA, modern, high-performance and clean code, and shine with features the others
  simply don't have — just better, smarter and mega fast.
- **Every design question** first reads what is really asked and researches the state of the art —
  never guessed. Then a fresh background session researches competitors and gaps and finds or
  invents 1 to 4 features other tools do not have and that really help the user; a second fresh
  background session sketches per feature how it looks SOTA, modern, high-performance and clean
  code — a sketch, not code. At least one of the 1 to 4 features is the standout: one that exists
  nowhere yet, mega cool, the latest thing, that everyone wants; with it stand who wants it, what
  users take instead today (three names with links) and where the search went. The second session
  first tries to refute it; "none found" with the search list is a valid answer. Where no
  background session is possible, research yourself. Every such answer gives concrete, evidenced
  points of difference; ideas only, building is the maintainer's decision. A small decision in
  operation the session researches itself, without background sessions.

## Divergences From a Source

A **divergence** is a place where the repo deliberately departs from a source it otherwise follows —
an upstream it syncs or vendors from, a template it was built from, or the playbook (a
project-specific override in `CLAUDE.md`). Its reason stands beside it or in the evidence document a
comment points to (`.agents/rules/code.md` § "Code Comments").

- **A divergence is checked for "the reason holds at the head"**, not for "a reason is there". Every
  state audit, and every sync bringing a new state of the source into files with divergences, walks
  them and gives each `holds`, `no longer holds` or `not checkable` — measured or shown at the code,
  never read off the reason's wording: the state can go while the sentence stays, and a check for
  presence passes it on every sync after that. A sync also reads
  the source's delta itself, not only the folders it copies.
- **`no longer holds` is a finding:** back to the source's form, or a reason that holds today — in
  the same pass where it touches the files anyway, otherwise as `.agents/rules/carrier.md`
  § "Carrier Requirement" says.
- **`not checkable` names why** (a foreign system out of reach, a state this repo cannot see) and
  never counts as `holds`.
- **A reason bound to a state names what lifts it:** a carrier (`until #N`) or a checkable condition.
  "Not yet", "for now", "until X works" tell the next audit neither what to look at nor when; a reason
  meant for good says `permanent`, as a folder exception does. A reason bound to a state without
  what lifts it is a finding of its own.
