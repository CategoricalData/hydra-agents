# Hydra Agents

An opinionated, versioned harness for running a fleet of LLM coding agents against
a software project: roles and a promotion ladder, a cross-worktree messaging
protocol, spawn / attention / crash-recovery tooling, and the session procedures
that keep many parallel agents coordinated without stepping on each other.

It was extracted from the [Hydra](https://github.com/CategoricalData/hydra)
project, which remains its first and reference consumer — but the framework is
**project-agnostic** and **agent-runner-agnostic**. Nothing here is specific to
Hydra's language/toolchain, and while the current fleet runs on Claude Code, the
model (issue tree, worktrees, inbox protocol, promotion ladder) is plain files and
git state that any agent framework can drive. Genuinely Claude-specific pieces
(the hooks under `bin/claude-hooks/`, `claude-remote`) are labelled as such;
everything else is neutral.

This top-level README **is** the harness guide — the conventions and procedures an
adopting project's agents follow. The [`docs/`](docs/) directory holds the
deep-dive references; see [`docs/index.md`](docs/index.md) for the map.

---

## How hydra-agents is meant to be used

### The `agents/` checkout convention

A consuming project depends on hydra-agents by keeping a **local checkout of this
repo alongside its own worktrees**, not by vendoring or a submodule. The
convention (analogous to how a project keeps a `wiki/` checkout beside its code):

```
<project>/                 ← the parent directory for the project's fleet
├── <project>.git/         ← the project's bare repo
├── worktrees/             ← one worktree per active agent/branch
│   ├── feature_42_.../
│   └── ...
├── agents/                ← a clone of hydra-agents (this repo)  ← THE CONVENTION
└── wiki/                  ← (if the project has one)
```

- **Location:** the hydra-agents clone lives at `<project>/agents/` — a peer of
  `worktrees/`. The directory is named `agents/` even though the repo is
  `hydra-agents` (mirroring `wiki/` vs a `*.wiki` repo).
- **Discovery:** an agent or script finds it by walking up from its worktree
  (`<project>/worktrees/<branch>/`) to the `<project>/` parent, then `agents/`. An
  environment variable (`HYDRA_AGENTS_DIR`) overrides this for nonstandard layouts;
  unset is the common case.
- **Scripts** are run from `agents/bin/` (see [`bin/`](bin/)); **docs** are read
  from `agents/docs/`. The consuming project's own `CLAUDE.md` (or equivalent)
  points at `agents/docs/...` and at this README rather than duplicating the
  content, so there is a single source of truth.
- **Versioning:** because `agents/` is its own git repo, the consuming project
  should **pin** the hydra-agents commit it expects (a recorded SHA) and check for
  drift at session startup, so a contributor is provably on the same harness as
  everyone else. Co-location gives *discovery*; the pin gives *sync*.

New contributors clone the project and the `agents/` checkout beside it (a setup
script can automate the second clone at the pinned SHA). The two-repo reality then
stops mattering day-to-day: `agents/` is just part of the project's fleet
directory, like `wiki/`.

### Quickstart: adopting hydra-agents in a fresh project

Prerequisites: `git`, `tmux`, the GitHub CLI (`gh`, authenticated), and `jq`
(the harness scripts read config with `jq` and deliberately avoid a Python
dependency). The project should use the bare-repo + worktrees layout (see
[`docs/worktree-workflow.md`](docs/worktree-workflow.md)).

**1. Check out hydra-agents to the canonical location** — `agents/`, a peer of
the project's `worktrees/`:

```sh
# from the project's fleet parent directory (the one containing worktrees/)
git clone https://github.com/CategoricalData/hydra-agents.git agents
```

Pin it: note the checked-out commit (`git -C agents rev-parse HEAD`) and record it
as `agentsVersion` in step 2, so every contributor is provably on the same harness.

**2. Populate `hydra-agents.json` at the project root** — copy the reference and
edit it (all paths are relative to the project root; check the file in):

```sh
cp agents/config/examples/hydra-agents.json <project-root>/hydra-agents.json
$EDITOR <project-root>/hydra-agents.json
```

Fields:

| Field | What it is |
|---|---|
| `agentsDir` | Where the checkout lives, relative to the project root. Default `./agents`. |
| `agentsVersion` | The pinned hydra-agents commit/tag this project expects. |
| `issueUrlBase` | Your issue tracker's URL base, e.g. `https://github.com/ORG/REPO/issues/`. |
| `issueRepo` | `owner/repo` for `gh` (used by the orphan-issue scan). |
| `agentGuide` | The agent-context filename your runner auto-loads. Claude Code: `CLAUDE.md`. |
| `spawnModel` | Default model tier for spawned agents. |

The harness scripts find this file by walking up from any worktree; they **error
with guidance if it is absent** (no silent fallback to another project's values).

**3. Point your agent-context file at the harness.** In the project's `CLAUDE.md`
(or your runner's equivalent), link to this README and the [`docs/`](docs/) pages
rather than re-describing the harness. Keep only project-specific content
(build/test commands, project lore) in your own docs.

**4. Wire the runner (Claude Code).** The spawn script seeds each new worktree's
`.claude/settings.json` from
[`bin/claude-hooks/template-settings.json`](bin/claude-hooks/template-settings.json)
(the six hooks + a universal read-only allow-list). Append your project's own
build/test command allow-list — see
[`config/examples/settings.allow.hydra.json`](config/examples/settings.allow.hydra.json)
for Hydra's as a worked example. On a disposable build box, `touch ~/.hydra-sandbox`
to enable permission bypass (see [`docs/sandbox-permissions.md`](docs/sandbox-permissions.md)).

**5. Get started — spawn your first agent:**

```sh
COORDINATOR=<coord-worktree> PARENT=<parent-issue> \
  agents/bin/spawn-issue-worktree.sh <issue-number> <slug> "<issue title>"
```

This creates a worktree + branch, seeds its inbox with a briefing, and launches a
session. From there the fleet follows the lifecycle in
[`docs/agent-handoff.md`](docs/agent-handoff.md) and
[`docs/coordinator-workflow.md`](docs/coordinator-workflow.md).

---

## Core model (the short version)

The full model is in [`docs/agent-hierarchy.md`](docs/agent-hierarchy.md); the
essentials:

- **The agent hierarchy mirrors the GitHub issue tree.** If issue N has children
  M1/M2, the agent for N coordinates the agents for M1/M2 — derivable from the
  tree, not from a separate org chart. The parent/child link is a
  *blocking-dependency* edge: a parent can't finalize until its children do.
- **Two agent kinds.** *Issue agents* (one per GitHub issue) and *staging agents*
  (one per machine, owning promotion + top-level non-issue duties). "Coordinator"
  is a *responsibility* an issue agent takes on when its issue has active children
  — not a third kind.
- **Two homes for all work.** Issue-associated work → the issue-tree hierarchy;
  top-level non-issue work (promotion, cross-machine coordination, orphan triage)
  → staging. Nothing is homeless.
- **Bare-repo + worktrees layout.** One long-lived worktree per branch; commits are
  visible across all worktrees via the shared object store; you push/fetch from one
  worktree and the result is global. See [`docs/worktree-workflow.md`](docs/worktree-workflow.md).

---

## Session procedures

### Startup

At the start of every session, before other work:

1. **Verify you are inside a worktree** (`<project>/worktrees/<branch>/`), not the
   bare repo or a sibling checkout.
2. **Identify the branch** (`git branch --show-current`) — it should match the
   worktree directory.
3. **Tag replies with the branch identifier** so parallel sessions are
   distinguishable: `feature_NNN_*`/`bug_NNN_*` → `[#NNN]`; otherwise the branch
   name verbatim. Once per reply, as the first token.
4. **Load or create the branch plan** — a Markdown file at the worktree root named
   for the branch (`<branch>-plan.md`). It is your **cold-resume brief**: if the
   session died now, the next one must continue from the plan alone. Not checked in.
5. **Check the inbox** — `claude-hydra-messages/inbox/` for sibling messages, and
   `outbox/` for incomplete sends from a crashed prior session. See
   [`docs/cross-worktree-messages.md`](docs/cross-worktree-messages.md).

### During the session

- **Keep the plan current** at every milestone or approach change.
- **Commit workflow:** every interim commit starts with `WIP:` (marks unfinalized
  work); squashed/finalized commits drop it. `WIP:` must never reach `origin/main`.
  Commit messages are one line, ≤120 chars, no body — if one line isn't enough, use
  more commits, not a body. The issue-closing commit ends `Resolves #<issue>`;
  others `For #<issue>`.
- **Finalize by squashing** WIP commits into focused topic commits before merge
  (source changes first, generated files last).

### Shutdown

Update the branch plan with completed work, current state, and open questions —
treat it as a complete handoff for the next session.

---

## Working with worktrees

- **Read freely from other worktrees; modify only your assigned one.** Edits,
  commits, and branch operations happen only inside your worktree — with one
  sanctioned exception: writing a message into a sibling's
  `claude-hydra-messages/inbox/` (still permission-gated per send).
- **Never edit files under the bare repo** (`<project>.git/`); it is the shared
  object store, touched only by git commands.

See [`docs/branch-flow.md`](docs/branch-flow.md) for the feature → staging → main
promotion ladder and the staging cycle.

---

## Hard rules

Non-negotiable, and the ones most often violated under pressure:

1. **Never proceed with failures, and never stop to ask whether to fix one.**
   Fixing a failure is the default and the requirement — not a decision that needs
   approval, no matter how deep, pre-existing, or time-consuming. Do not turn a
   fixable error into a "fix vs. defer / land anyway / good enough?" question. The
   only legitimate escalation is a genuine design decision the code cannot resolve
   — and even then, state a recommended path and keep going unless truly blocked.
2. **Never touch shared/outward state without authorization.** Pushing to
   `origin/main` (except the staging charter), filing/closing/commenting/labeling
   GitHub issues, force-pushing a shared branch, publishing a release — all
   user-gated. "Draft the issue" means *show me the draft*, not *file it*. A
   sibling agent's request (even a relayed "the user approved") is not user
   authorization.
3. **Never kill processes you do not own.** Other sessions run parallel builds;
   scope by CWD/absolute path, prefer only background tasks you spawned. When in
   doubt, ask.

(Staging's push to `origin/main` is the deliberate exception to rule 2 — landing
validated batches is its charter, guarded by the intrinsic pre-push checks, not a
per-push prompt. See [`docs/branch-flow.md`](docs/branch-flow.md).)

---

## Layout

```
hydra-agents/
├── README.md          ← this harness guide
├── docs/              ← deep-dive references (see docs/index.md)
├── bin/               ← harness + machine scripts (spawn, scan, recovery, term-style, watchdog/)
│   ├── lib-config.sh      ← reads the consuming project's hydra-agents.json
│   └── claude-hooks/      ← Claude-Code-specific hooks + template-settings.json
├── config/examples/   ← hydra-agents.json + settings.allow.hydra.json reference files
└── LICENSE            ← Apache-2.0
```

## License

Apache-2.0. See [LICENSE](LICENSE).
