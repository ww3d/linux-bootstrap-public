---
trigger: carrier
read-before: deferring a point, or closing an issue
budgetTokens: 4000
---

Read before: deferring a point, or closing an issue

## Tracking Issue

**One design = one decision log = one tracking issue**, however many PRs the design takes — created
**always**, even when no point stays open, and closed after the merge. The unconditionality is
deliberate: an exception ("only with more than one PR") is a judgement call, judgement calls are
where points get lost, and an empty tracking issue costs thirty seconds.

- **Every open point of the design stands in the tracking issue's body** — one list, never spread
  over PR bodies or comments; deferring a point means editing that body. A comment stream is no work
  list: nobody reads it back as what is left.
- **Both directions:** deferring writes a point in; **delivering ticks it off, in the same PR that
  delivers it** — the spec file ticks the `REQ`, the issue body ticks the point, both. The body is the
  live answer to "what is still open"; an unticked shipped point gets commissioned again.
- **An agent edits the body from a shell with `scripts/common/edit-issue-body.ps1`** — one tick or
  one section, every other byte unchanged; a body pushed back through a PowerShell string arrives as
  one line, and no checkbox renders. Through the forge connector, read the body before and after and
  compare: only the intended place differs. Check the length too: GitHub caps a body at 65,536
  characters — move finished parts verbatim into a comment before it gets close.
- **The design round creates it**, before the first spec file, in the same move as the decision log
  (`ccweb-prompt`, step 1) — created only at the first PR, a window would stay without carrier.
- **It carries the label `tracking`**, which makes it findable by machine: the state audit reads the
  open points out of every issue with that label. A title convention filters nothing, and a source that
  silently returns nothing looks exactly like "nothing open" — the failure class this rule stands
  against.
- **A new tracking issue carries no plan label** until the maintainer places it
  (`.agents/rules/docs.md` § "Planning").
- **Around 30 checkboxes, open points move to GitHub Sub-Issues;** the body then carries the current
  state — issue bodies have a length limit, and a full body looks as tended as a healthy one. Known
  gap: sub-issues are not forge-neutral (GitLab and Forgejo model them differently), accepted while
  every repo lives on GitHub.
- **`Closes #N` on an issue with a checklist** — with or without `tracking` — only once its body has
  no unticked box left: the keyword closes on merge and checks nothing. While a point is open the PR
  names the issue without keyword (`.agents/rules/pr.md` § "PR / MR Description"); this holds for
  `Fixes` and `Resolves` alike. **The other direction is the dev's duty:** where the boxes this PR
  ticks leave none unticked, the PR body carries the `Closes #N` line from that push on — counted
  at the head on every round, a later one included — so the maintainer's merge click closes the
  issue with no comment and no script. The checks of § "Carrier Requirement" ("before closing an
  issue …") do not run on that path, so the dev sets the line only once
  `scripts/common/find-closable-issues.ps1 -Repo <owner/repo> -Pr <n>` reports the issue
  `closable` (every `rehang-first` place re-hung before); the script reads body and tree at the
  head and runs before the merge.
- **Where no closing line closed it on the merge, whoever merges closes it**, after the merge, with
  `pwsh scripts/common/close-tracking-issue.ps1 -Repo <owner/repo> -Pr <n>` — which closes only when
  **both** hold: the body has no open point left, and the checks of § "Carrier Requirement" ("before
  closing an issue …") ran. Without the script, run those checks by hand. With points left the issue
  **stays open**; a point moves only because it no longer belongs to this design, never to make the
  issue closable. The same holds for every issue with a checklist; whether this PR ticked the last
  point is counted at the head, never remembered. Where no PR ticks the last point (ticked by hand,
  moved), whoever does that closes it under the same conditions. Where the closer cannot, it falls
  to the `maintainer`; the state audit stays the net below. A tracking issue whose body never held a
  checkbox is closed the same way once the carrier checks ran.
- **The review checks two things:** the tracking issue exists and is open, and the points this PR
  defers stand in it — plus, with a closing keyword, that its body is free of open points
  (`pr-poll-review`, Phase 4).

- **An order carries no closing keyword with a number** — whoever writes one (controller,
  orchestrator, design session) words it without `Closes #N`, `Fixes #N` or `Resolves #N`: the
  dev pastes the order verbatim into the PR body, where the keyword would close an issue
  unchecked. What closes the issue is the dev's own line, set under
  `.agents/rules/carrier.md` § "Tracking Issue".

## Carrier Requirement

A **carrier** is the place a deferred point is written down so it can be found again. Every point a
PR consciously leaves open has one **before the PR gets a positive closing verdict** — an approval, a
"looks mergeable" comment or a sentence in chat alike (`pr-poll-review`, Phase 4).

- **Everything buildable is built; only what is not buildable is carried.** A point is buildable
  when this repository can implement it without an open decision of the maintainer, however small.
  Every finding or piece of work that belongs to the order is built in the same PR.
  `.agents/rules/code.md` § "Work Standard" carries the same sentence for writing code and says
  how; a finding unrelated to the order is its own PR, not a deferral, and the maintainer is told
  about it (the way: `.agents/rules/pr.md` § "Controller Mode"); a work limit
  sets the order, never the scope. While it waits, its line reads `**Own PR:** <owner/repo#N>` —
  `#N` the open PR or open tracking issue that commissions it, never a session name; a reviewer
  checks that the target exists and is open. The one scheduled form without a target is the doc
  catch-up, a `backlog.md` line (`.agents/rules/docs.md` § "Documentation").
- **Exactly three cases are not buildable:**
  1. **Only in a foreign repo** — an issue there, here a line `**Foreign repo only:** <owner/repo#N>`
     linking it, and a report to the maintainer (in controller mode through the orchestrator, where
     one steers).
  2. **No fix known** — after documented research, sources named: `**No known fix:** <reason with
     sources>`.
  3. **A decision of the maintainer** (the list in `.agents/rules/pr.md` § "Controller Mode") — a
     question, on the way that section names, not a line that would only lie there.
- **Valid carriers — this list stands here and nowhere else:** the design's open **tracking issue**
  (§ "Tracking Issue"); a line in `roadmap.md`, or in `backlog.md` for what is not buildable and
  for the doc catch-up only; for a point only a foreign repo can
  implement, an open issue in that repo, which this repo only links. Someone walks all of them again —
  the quick check before every design round, the full audit when due (`.agents/rules/audit.md`). A
  missing `backlog.md` is created by the PR adding its first line — the clause stands in `.agents/rules/docs.md` too, because one is read while deferring a
  point and the other while writing docs.
- **Everything else is no carrier** (core rule 11): the PR body (once merged, an archive nobody
  reads back), a review or issue comment, a chat, a decision log
  (the record of one day, read for the why), the task spec file (nobody reopens it after the merge,
  and its ticked items make it look finished), and a `[planned]` / `[partial]` marker (a display at
  the statement, `.agents/rules/docs.md` § "Target vs. Actual"). An obligation that stands only there
  gets a carrier line in addition; naming a point is not carrying it. Neither is a hook's state
  file (it only bridges a compaction on the same machine and is gone after a change of machine) or
  a handover or plan file in a scratchpad: what they hold goes to a valid carrier, a session's state
  to its place in a body (`.agents/rules/pr.md` § "Controller Sessions").
- **A marker is covered once its point stands at any valid carrier;** a marker at none is a finding
  the state audit carries to one — the tracking issue of the slice that makes it due, otherwise
  `roadmap.md` / `backlog.md`, for a foreign-only point an open issue there — never to a foreign
  design's tracking issue, whose body would become a dump the next round reads as an order.
- **A carrier issue is open;** a closed one looks finished and carries nothing. A roadmap / backlog
  line holds until it is struck through.
- **A carrier line names the state of the mechanism, not only of its guard.** Test question: does the
  thing this line guards exist? A line describing a missing guard over a mechanism that is itself
  missing misleads every later reading.
- **The dev writes the line, in the same PR;** the reviewer files it only where the PR touches none
  of the carrier files.
- **A gap in a file the PR creates or changes, with a known fix, is fixed in the PR.** Written into a
  carrier instead, it is a **moved fix** — a deferral in a carrier's shape. A review-wave cap limits
  the waves, never the fixing. For a file of the PR only the three carrier line forms are valid —
  `**Own PR:**`, `**Foreign repo only:**`, `**No known fix:**` (the earlier German forms are read
  until playbook 26.0.0); what the reviewer checks in them stands in `.agents/rules/review.md`
  § "Review Comments".
- **A point handed to a future slice counts once it stands at the destination** — that slice's
  tracking issue or `roadmap.md` line; a sentence in the sender's PR body is a note to nobody, since
  the receiver reads its own issue, not foreign PR bodies. Without a destination it goes to
  `backlog.md`.
- **Before closing an issue, check what points to it** — a `Closes #N` closes without any check,
  which is why the keyword is conditional:
  1. **Checkboxes against the other carriers:** every open point is moved first, or recorded as
     resolved with it.
  2. **The issue's name across the whole repository** — it finds what the checkbox check cannot, a
     place that names this issue as its carrier without being a checkbox in its body: a place naming
     it as carrier ("carried in",
     "point in") is a carrier formula; a quotation ("the finding `#36` lists") is not.
  3. **Where other repositories consume this one as their playbook:** their `CLAUDE.md` exceptions
     bound to the issue ("until #N", "bis #N"), which check 2 never finds since it searches only this
     repository — each falls with the close or names its new carrier.
     Also search across repos (`gh search code '<owner/repo>#N' --owner <org>`), and where the issue
     carries a note of the maintainer ("DO NOT CLOSE", a decision), ask first: closing is never an
     end in itself.
- **No marker without a number:** a `TODO`, `HACK` or `FIXME` — in code or in source-of-truth prose —
  references an open carrier; a caveat on a statement in a source-of-truth document stands on that
  statement.
- **A `nitpick:` is no open point:** it gets no carrier and is fixed or dropped
  (`.agents/rules/review.md` § "Review Comments").

Known gap: nothing runs the closing checks unattended. The periodic run of
`scripts/common/sweep-carriers.ps1` waits for the org CI, carried as a line in the playbook's own
`backlog.md`; the quick check walks the tracking issues and markers before every design round meanwhile.
