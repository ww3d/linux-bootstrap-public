---
trigger: code
read-before: writing code
budgetTokens: 4300
---

Read before: writing code

## Code Conventions

Detail per stack lives in the tech overlay; these size limits are cross-stack.

- **Class size.** Guideline ~150-200 lines, hard cap 300; beyond 300 only with a justification in
  the PR body.
- **Responsibility axis**, independent of the line count: at most ~15 instance fields and one clear
  responsibility — the real God-class catcher, which a mechanical file split does not evade.
- **Exception.** Pure schema / DTO / config classes and stateless helpers are exempt from the line
  limit — they grow by independent records, not by coupling.
- **Method size.** Guideline ~30 lines. Cognitive Complexity ~15 (C family incl. C# ~25) as the
  readability measure; Cyclomatic Complexity guideline ~10, blocked from ~25, as the testability
  measure. Deeply nested or hard to read → split.
- **Names** speak for themselves: a name says what the thing is or does.
- **Constructor.** About five parameters at most, more → a parameter object. Collaborators behind an
  interface, not a bag of `Func<>` callbacks; no circular construction.
- A sync API stays sync and an async one async unless the caller needs the other — never switched
  just to round it off.
- **Cross-stack defaults:** nullability checks on and I/O async wherever the language offers them;
  records or value types for data, classes for entities with identity; timestamps in UTC. The
  overlay names the construct.

## Code Comments

`.agents/rules/code.md` § "Always" says what gets documented; this section bounds how a comment reads.

- **Short why**, guideline 1-3 lines. A longer rationale lives in the evidence document (decision
  log, architecture or upstream doc), and the comment points there.
- **Present state only.** Git history and the decision log carry how the code got here — no review
  rounds, finding numbers or "this used to be …". A pointer to a decision or a carrier (`TODO #N`) is
  fine. A review round that lengthens a comment is the wrong fix: shorten it, or move the reasoning.
- **Line limit: 120 characters** for every line carrying a comment, indentation included; the overlay
  names the tool, otherwise the review check in `pr-poll-review` carries it.
- **Exception: upstream comments taken over verbatim** from synced or vendored code, kept comparable
  with their source — rewriting them breaks that comparison on the next sync; a comment of our own beside them follows this section.
- A suppressed warning carries the comment that explains it.
- **No REQ number in code, XML docs or tests**, in new and touched code: a reference points at an
  issue or a decision log (`#N`, in another repo `owner/repo#N`); which code meets which REQ stands
  in the spec and the PR.

## Folder Conventions

Detail per stack lives in the tech overlay; these six rules are cross-stack.

1. **Folders are named for the subject, never the technical role.** Default ban-list: `Services`,
   `Helpers`, `Utils`, `Models`, `Interfaces`, `Extensions`, `Common`, `Misc`, `Shared`;
   `Tenancy/`, `Dispatch/`, `Status/`, `Planning/` instead. An exception costs a line in the
   exception file (below).
2. **No sediment.** The top level of a project/module carries only what concerns the whole (entry
   point, DI/module root, manifest), hard cap **three**; everything else lives in a folder.
3. **Namespace equals path** wherever the language has namespaces.
4. **The test project mirrors in both directions:** every product folder has a same-named test
   folder, and every test folder a product counterpart — a test folder without one means the code
   moved and the tests stayed, the state where a test checks the wrong thing and still passes.
5. **Folder size guideline**, soft, ~15 files; beyond it split, or justify in the PR body.
6. **Repo root.** The top level of every repo holds only:
   - the folders `src/` (source), `tests/` (tests), `docs/` (documentation, with `audit/`,
     `backlog.md` and `roadmap.md`), `scripts/` (the repo's own scripts, with the playbook's
     `scripts/common/`) and `artifacts/` (build output, never checked in, its place settable — how,
     the stack overlay says); `eng/` only where the org build tool builds the stack;
   - the dot folders tools demand — `.agents/` (with the playbook's `tech/`), `.claude/`,
     `.github/` — and the dot files the repo's tools read;
   - `AGENTS.md`, `CLAUDE.md`, `README.md`, licence and changelog, and the files the stack expects
     at the top (solution or project file, toolchain pin, build entry wrappers), listed per stack in
     the playbook's root list.

   **`eng/` against `scripts/`:** `eng/` holds the build entry, the build properties and the tools
   that build, pack or generate build input; `scripts/` holds upkeep — syncing with a source,
   convention checks, setup. Without the org build tool, build scripts live in `scripts/`.
   Root deviations stand in `.agents/config/root-layout.json`, each with its reason and a carrier
   or `permanent`; `scripts/common/check-root.ps1` checks the root against the playbook's list and
   that file, both ways.

**Exceptions to rules 1-5 live in one file per repo (the root's: rule 6), never in comments:**
ban-list, its exceptions and the sediment cap together, so an exception costs a visible diff
line — the same mechanic as a dependency-direction allow-matrix. **Every exception carries a
resolution note** — a carrier reference or `permanent` — so the list stays tracked. Whether the rule
applies to the existing tree or only the diff is the repo's call: a permanently red gate teaches
everyone to ignore it.

## Work Standard

The bar for finished work, beyond `.agents/rules/code.md` § "Branches, Commits and Fixes":

- Grasp the full context before a design decision — docs, issues, PRs, backlogs, rejected approaches
  too — and reuse prior work. Code from another repo or an earlier project is read first and
  summarized, then modernized and merged; existing implementations are assets, never rewritten from
  scratch unprompted.
- Turn a task into verifiable goals: a failing test first, then make it pass; tests green before and
  after a refactor; a multi-step plan names a verify-check per step.
- Every finding or piece of work that belongs to the order is built in the same PR.
  `.agents/rules/carrier.md` § "Carrier Requirement" carries the same sentence and what else holds;
  related work goes into its own commits, and the PR body lists it (`.agents/rules/pr.md` § "PR / MR
  Description").
- Cover every use case, the derived ones too; the result stays intuitive. No dead paths.
- Hot paths allocate nothing; measure, don't guess. Structured logging with no hot-path cost, and
  enough context to debug.
- Tests cover the happy path, every edge case and every error path; a test that cannot run on a
  platform is skipped there, never omitted or replaced by other behaviour. Async library APIs take a
  cancellation token as required.
- A test checks our own code — never a third-party library's behaviour, only our wrapper around it
  —, and its name states the expectation, not the technical how; for a complex interface a double
  that reproduces the real interface comes before an auto-mock.
- Validate packaged or bundled artifacts in the **consumer's topology**, not the repository's: the
  repo layout can silently heal failures the shipped artifact will have (§ "Test Isolation" for the
  smoke folder).
- Autonomous through to completion; self-review and refactor rounds until clean.

## Test Isolation

**A test changes nothing outside its own test folder** — a cleanup in `finally` included, since it
never runs when the process is killed. Off limits: a drive letter (`subst`, a mapped drive), the
registry, a persistent environment variable at user or machine scope, a scheduled task, any folder
outside the run's folder, system temp and `%LOCALAPPDATA%` included. A variable set in the run's own
process is fine. A test whose subject is such behavior runs against a stand-in (an interface, a fake),
never against the machine.

- **The test run sets the temp folder.** Before any test starts, the repository's test entry point
  (its test script or build target — no test depends on the caller's environment) points `TMP`,
  `TEMP` and `TMPDIR` at the run's folder inside the build's output folder, default
  `artifacts/tmp/<run>/` under the git-ignored `artifacts/`; whatever asks the platform for a temp
  path (`Path.GetTempPath()`, Pester's `TestDrive:`, a library's scratch file) lands there. Where the
  repo's versioning or build tool defines the output structure, its folder wins.
- **Package smoke tests get a named folder of their own** in the same output folder, and their
  isolation comes from the lookup paths, not the location: no repository file, package cache or
  parent `node_modules` on any lookup path of the smoke run.
- Locations a tool fixes inside the repository, and toolchain caches the restore writes, are the named
  exceptions per stack (`docs/common/ci.md` § "Testordner je Stack"). A tool that needs a short temp
  path outside the repository (Unix socket path length) is an open question to the maintainer,
  and until it is decided such a folder is named in the repo's `CLAUDE.md` as a divergence
  (`.agents/rules/audit.md` § "Divergences From a Source").
- **Cleanup happens at the next start, not only at the end:** the entry point removes earlier runs'
  folders that no running process holds any more (a lock on a marker file the OS releases with the
  process), so an aborted run's leftovers go and a parallel run keeps its files.

## Tests and Time

**A test never sleeps and never waits on the real clock** — no sleep or delay, no polling loop with a
wall-clock deadline. Under load such a wait runs out and the test turns red for no fault of the code;
every wait also lengthens the run. This holds for every existing test, not only new ones (the overlay
names the tool per stack).

- **Time-dependent code takes a replaceable clock**; the test hands in its own, and time jumps
  instantly instead of passing.
- **Waiting on another thread or process** is waiting on a signal (an event, the process exit),
  never "look again after X seconds".
- **A wall-clock deadline is only the run's hang guard** — it aborts a test that hangs — and never a
  condition a test has to meet.
- **A test that must measure real time** (a performance budget, a real process start) is its own
  group: marked as such in the repo's own way, run alone and outside the normal run, never in
  parallel with other tests (after Google's test sizes and Bazel's `exclusive` tag). Only there
  real time is allowed.

## Dependencies

A package the code needs is a blocking question, asked the moment the need shows, with the need
justified; who answers: `.agents/rules/pr.md` § "Controller Mode". The work on that point waits: a
substitute built meanwhile is no answer. A good reason for a package is a reason to use it;
standard-library options first. A justified dependency is pinned at the current stable version,
verified from the registry, not from memory, and named with its version in the body of the `build:`
commit that introduces it. An outdated existing dependency is named with an update proposal — never
bumped silently, never left unmentioned.

1. **Latest stable is the default;** a deviation is named with a reason and a follow-up at the pin.
2. **Pre-release only on explicit request,** in every stack; once the stable ships, the pin is due.
3. **A major jump is its own decision** — own commit, own test run, never bycatch of a sweep: a major
   can change behavior without the compiler saying so.
4. **One platform line, one version** — differing patch levels of one product family in a repo are a
   finding.
5. **Audit downgrades are time-boxed:** `NuGetAuditMode`, `NoWarn` on security warnings and the like
   are re-checked at every sweep and fall once their reason is gone.

A sweep **shows** currency instead of claiming it: the overlay's currency command output goes into
the PR body before and after, empty except for the named exceptions. No update bot (Renovate,
Dependabot) before the org CI runs in production — PRs nobody can see green train everyone to ignore
them. The per-stack currency commands live in the tech overlays.

## Product Name vs. Code Identifiers

The product name is user-visible; technical identifiers (assembly names, namespaces, folders,
binaries) are decided per project — ask before introducing concrete ones. Configuration sections and
environment-variable prefixes typically follow the product name.

## Release Notes Are Not UI Strings

A build that injects the top changelog section into a package manifest carries it into a format older,
non-UTF-8-defaulting hosts read (a `.psd1` without BOM is read in the ANSI codepage by Windows
PowerShell 5.1), where every non-ASCII byte becomes mojibake. The BOM-less manifest pipeline is the
reference; a per-repo BOM override only hides the breach. A repo publishing such a manifest carries a
build check that hard-rejects non-ASCII in the injected section — mandatory, its form the repo's call.

## Simplicity in Detail

- The rule stands in `.agents/rules/code.md` § "Simplicity"; in addition, no error handling for cases that
  cannot occur, and a 200-line change that could be 50 is rewritten.
- New code matches the file it lands in in naming and formatting, but takes the newest language and
  platform feature the project's baseline offers — and so does every line a change touches.
  Neighbouring formatting and pre-existing dead code are mentioned, not changed; rebuilding a whole
  file, or whatever lies beside the touched lines, is a proposal to the maintainer
  (`.agents/rules/pr.md` § "Controller Mode").
- Each tech overlay carries a "Do Not Miss" list: feature names without version numbers, the
  analyzer or lint rule id on every line a rule checks, re-checked at the stack's baseline jump.
- For new code take the current, idiomatic, well-supported approach the toolchain offers: a modern
  built-in over a heavier dependency, performance from sound algorithms and structure rather than
  micro-optimization, the simplest form that does the job; reference implementations are researched
  first rather than taking the first solution that works.

## Branches, Commits and Fixes

- The language rules stand in `.agents/rules/docs.md` § "Language".
- Feature branches only, never `main`. One commit = one sentence you can describe; a PR over ~150
  changed lines gets ≥3 commits. Conventional Commits (language: `.agents/rules/docs.md`
  § "Language"): imperative, lowercase after the colon, no period, ~72 characters; an optional
  scope, `!` for a breaking change; the body says why, in full sentences. The one exception to the
  branch rule and the commit types stand in `.agents/rules/pr.md` § "Branch Naming".
- Sketch large changes first; state assumptions; surface tradeoffs and simpler alternatives; present
  several readings instead of picking one silently; push back when warranted. A plan comes first, then
  sessions as the limits allow.
- What is made modern and what is proposed: `.agents/rules/code.md` § "Simplicity in Detail"; what
  goes to the maintainer: `.agents/rules/pr.md` § "Controller Mode"; code details you decide. What
  is configurable goes cleanly into the project's settings file; which settings exist is settled in
  the design with the maintainer, and a dev session only proposes switches.
- One fix reaches every path of the same cause.
- At most three fix attempts at the same error; then stop with a diagnosis — what was tried, what
  was observed, where the suspicion lies.

## New Names and Dependencies

- A name the design round did not decide is researched in the design workflow and put to the
  maintainer to vote on or pick from.

## Simplicity

As little code as needed; every line traces back to the order. Where you see a more modern, better
or more performant solution or an additional feature, propose it; whether it is built is the
maintainer's call. Detail, and where modernizing ends and a proposal begins, in
`.agents/rules/code.md` § "Simplicity in Detail".

## Never in Code

- Modify `.git/` directly, or add a `TODO`, `HACK` or `FIXME` without an open carrier
  (`.agents/rules/carrier.md`).
- Suppress a warning without an explanatory comment; catch an exception without logging and either
  rethrowing or handling it; log full file contents.

## Always

- Run the tests before declaring something done; add tests for new public library APIs.
- Document every public surface others consume — whatever the construct — with what and why, not
  the obvious; the stack overlay names the tool (e.g. XML doc comments for .NET). Internal code is
  documented only where it is not self-explanatory.
- Cover every silent fallback path with a test that forces the success path: graceful degradation
  at runtime is fine as UX, degradation that slips through CI is not — when the primary path breaks,
  a test turns red.
