# Recovering the fleet after a machine crash

When a fleet machine hard-freezes or is reset, **every tmux/agent session on it
dies at once** — including the staging coordinator. This document is the staging
agent's playbook for bringing the fleet back. It is the after-the-fact companion
to [`external-alerts.md`](external-alerts.md), which is about *preventing* the
freeze in the first place.

You may reach this playbook two ways: reactively (you restart and find the fleet
gone), or proactively — a monitor's **liveness heartbeat ceased** and, after
escalating per [`external-alerts.md`](external-alerts.md), you confirmed the
machine had frozen. Either way the steps below are the same.

The governing fact that makes recovery safe: **committed work is never lost.**
Every agent's commits live as refs in the shared bare repo; a dead session loses
only uncommitted working-tree edits and in-memory context. So recovery is
mechanical, not archaeological — you are relaunching sessions and pointing them
back at their own plan docs, not reconstructing lost work.

## Order of operations

1. **Orient before acting.** Read your own inbox and branch plan; the plan doc
   is the fleet roster and landing-queue state as of the last `/save` (it may be
   weeks stale). Check `tmux ls` (usually empty after a reset) and
   `git worktree list`. The most reliable record of **which sessions were alive
   at crash time** is the agents' own transcripts: every live session writes to
   its transcript continuously, so the transcripts modified in the last hours
   before the crash are the live roster (`recover-agents.sh --live-within <minutes>
   --dry-run` lists them). Attention markers only show agents that were blocked.
2. **Diagnose the crash** with the watchdog's runbook, in its order: the last
   heartbeat tick bounds when userspace stopped, then the last few health
   snapshots, then the prior boot's journal for that window. Check every
   timestamp: `journalctl -b -1` can include events from hours or days earlier
   (an OOM kill the evening before is not the crash). A memory-exhaustion
   livelock often has **no** OOM kill at all, just load climbing into the
   hundreds and the journal going silent. Then archive the pre-crash logs with
   your findings before the monitors are restarted (they rotate). Memory thrash
   is the recurring cause; if that was it, see "Capacity" below.
3. **Classify every worktree** into restart / do-not-restart (next section).
4. **Repair any corrupted worktree wiring** (see "Worktree corruption") *before*
   launching — a session started in a broken worktree wastes a launch.
5. **Write a one-time recovery brief** and point every relaunched agent at it
   (see "The one-time brief").
6. **Relaunch** in tiers: coordinators first (verify they come up), then
   workers. Verify each with `tmux capture-pane`.
7. **Confirm** the process roster: `pgrep -af "claude --remote-control"` should
   show one process per session with the intended model.

## Which sessions to restart

Not every worktree gets a session. Decide per worktree:

- **Restart** — an agent that was *actively working* (investigating, building,
  designing). Tell-tale: a `WIP:` branch tip, or a plan doc whose "current state"
  is mid-task.
- **Do NOT restart — paused/finalize-eligible.** An agent whose work is
  **squashed and delivered, awaiting landing + finalization** (branch tip has no
  `WIP:`, is a clean `Resolves #NNN` / delivered pointer; plan says "HOLDING for
  rebase signal" or "READY — parked"). Its branch is intact; staging lands and
  finalizes it without a live session. Restarting it just burns tokens and risks
  it re-doing settled work.
- **Do NOT restart — dormant/user-owned.** Anything the user has explicitly
  parked (e.g. a milestone deferred to a later release) or said they will
  restart themselves.

When in doubt between "actively working" and "paused," read the plan doc's
status line — squashed-and-delivered is unmistakable once you look. **Confirm the
ambiguous model assignments with the user** rather than guessing; model choice
is a real cost/quality lever.

## Capacity: restore fewer sessions than were running

If the crash was memory exhaustion, the fleet that was running is, by definition,
more than the machine holds. Don't restore it whole, even staggered:

- Agent sessions are the base load. Long-lived ones grow (on one fleet, sessions
  45–113 days old used 0.5–1.1 GB each against ~0.3 GB fresh), so a fleet that
  fit at first can fill RAM and swap over weeks with no single culprit.
- Restore in batches by priority (`recover-agents.sh --max N`), checking
  `free -h` between batches, and stop while there is clear headroom for one heavy
  build on top (several GB).
- Many restored agents will find their work squashed and delivered and stop on
  their own; count them out of the working set.
- Make sure heavy builds are gated on available memory, not only serialized
  (`lib-mem-check.sh`), and that the monitor's alerts reach you (below).

## Model assignments

Each agent's model is recorded (or derivable) from its role, per
[`agent-hierarchy.md`](agent-hierarchy.md): release/high-stakes coordinators run
the most capable tier, staging runs a strong/balanced tier, heavy design/"hard
thinking" issues run a strong tier, ordinary bug/task workers run the
plan-then-execute tier. A worktree's own plan doc often states its model on a
`**Model:**` line; when it doesn't, fall back to the role default. Preserve each
agent's *previous* model across the restart — don't silently upgrade or downgrade.

## Relaunching a session

Restoration is **not** a fresh spawn: the worktree, branch, plan doc, and inbox
already exist, so `bin/spawn-issue-worktree.sh` (which creates a *new* branch off
`origin/main`) is the wrong tool. Use `bin/recover-agents.sh` with an explicit
selection: `--roster FILE` (lines of `<worktree> [model]`) or `--live-within
<minutes>`, plus `--max N`, `--prompt "<wake-up prompt>"` and `--dry-run` first.
It names sessions exactly as spawn does (so a later run never duplicates them),
reuses each agent's model from its last transcript, and sends the prompt with
the split-Enter technique below. Run with no selection it considers every issue
worktree, which is rarely what you want after a memory crash. What it does per
session, if you need to do it by hand:

```bash
tmux new-session -d -s "<wt>" -c "<worktree-path>"
tmux set-window-option -t "<wt>" automatic-rename off
tmux rename-window -t "<wt>" "<wt>"
tmux send-keys -t "<wt>" "claude-remote <label>-<wt> -b -m <model>" Enter
sleep 8                                   # let the TUI settle
tmux send-keys -t "<wt>" "<wake-up prompt>" Enter
sleep 3; tmux send-keys -t "<wt>" Enter   # insurance Enter (paste-detection eats the first)
```

`claude-remote` resolves on `PATH` (or as a shell function); a tmux pane runs an
interactive shell so it resolves. `-b` = `--dangerously-skip-permissions`
(sandboxed worktree), `-m` selects the model. Pass a stable label as the first
positional arg so the remote-control handle is stable across restarts. (This
launch is Claude-Code-specific; another framework substitutes its own launcher.)

**Verify submission**, don't assume it: `tmux capture-pane -t <wt> -p | tail`.
The TUI's paste-detection frequently swallows the first Enter, leaving the
prompt sitting in the input box — hence the insurance Enter. A healthy pane shows
the agent *working* (a spinner / tool calls), not text idling at the `❯`.
(Ghost/placeholder text at the `❯` that won't clear with C-u is display-only —
harmless; don't send Enter to "fix" it, which would submit it.)

Scripting the loop over the roster in a small shell file (one call per worktree)
is cleaner than many hand-typed launches and lets you refuse to clobber a session
that already exists (`tmux has-session`).

## The one-time recovery brief

Give every relaunched agent the same short orientation instead of re-explaining
per session. Write it once (e.g. `FLEET-RECOVERY-<date>.md` at the staging
worktree root — **not** checked into git; it is ephemeral), and make each wake-up
prompt say "read `<abs-path>` first, then run the startup procedure and
resume." Keep it lean; it should contain:

- **What happened** — one paragraph, and the reassurance that committed work
  survived (only uncommitted edits / context were lost).
- **What to do** — run the startup procedure, re-establish build baseline from a
  clean point (don't trust a half-finished build cache left by the crash),
  reconnect to your coordinator with a one-line "back after crash" note,
  resume from the plan doc.
- **The agent hierarchy** — who reports to whom, so each agent knows which inbox
  to route to. If a coordinator is itself not being restarted (a dormant
  parent), name the acting coordinator to use instead.
- **Which agents were deliberately not restarted** — so a paused agent that was
  restarted by mistake knows to `/save` and stop.
- **A pointer here** — "if your worktree wiring looks broken, stop and message
  staging; don't self-repair."

A well-formed brief pays for itself immediately: agents read it and self-direct
correctly (re-baseline builds, notify the right coordinator, park if they should
be parked) without further hand-holding.

## Worktree corruption

A crash can corrupt a worktree's git wiring. One observed failure: a worktree's
admin registration under `<repo>.git/worktrees/<name>/` had its **`gitdir`
pointer and directory name cross-wired with another worktree** — the admin dir
*named* for a since-removed worktree was actually holding a live worktree's
registration (its `HEAD`/`gitdir` pointed at the live one), while the named
worktree itself had no valid checkout. Symptoms: `git worktree list` shows the
right path under a confusing name; a worktree's `.git` link file points at an
admin dir named for a *different* worktree; the "expected" branch doesn't exist.

Diagnose by mapping every admin entry to its branch and gitdir:

```bash
for d in <repo>.git/worktrees/*/; do
  printf "%-40s HEAD=%s  gitdir=%s\n" "$(basename "$d")" \
    "$(cat "$d/HEAD" 2>/dev/null)" "$(cat "$d/gitdir" 2>/dev/null)"
done
```

Repair carefully — this is surgery on live git state:

1. **Back up** any coordination state in the affected worktree dir (plan, inbox,
   drafts) to a scratch dir first. If the worktree held only coordination files
   and no source checkout, that is itself the bug to fix (every agent should have
   a real code worktree).
2. If an admin dir is **misnamed** (holds another worktree's live registration),
   `mv` it to the correct name, fix that worktree's `.git` link to point at the
   renamed admin dir, then `git worktree repair` from inside it to reconcile both
   directions. Verify your own `git status`/`rev-parse` still works before
   continuing.
3. `git worktree prune` will **not** clear a stale entry whose `gitdir` target
   still exists (it looks valid); such entries must be renamed/fixed by hand, not
   pruned.
4. To restore a worktree that lost its checkout entirely, recreate it with
   `git worktree add -b <branch> <path> origin/main`, then copy the backed-up
   coordination state back in and seed `.claude/settings.json` from
   `bin/claude-hooks/template-settings.json` (plus any backed-up
   `settings.local.json`) so the inbox/stop/proposals hooks fire.

Never let an individual agent self-repair its own worktree wiring — corruption is
easy to make worse. Centralize it in staging.

Two quieter kinds of rot are worth a sweep while you're here:

- **Orphaned coordinator folders.** A renamed or retired coordinator worktree
  can leave its directory behind holding only `claude-hydra-messages/`. Agents
  and monitors that still name the old coordinator keep delivering there and
  nobody reads it. List `worktrees/*/` entries that are not git worktrees but
  have an inbox; move their contents into the live coordinator's inbox archive,
  triage anything unanswered, and remove the folder.
- **Stale hook paths.** Per-worktree `.claude/settings.json` files written
  before a harness move can point at scripts that no longer exist (e.g.
  `../../agents/bin/...` after the harness moved under `external/`). The agent
  still runs, but silently loses its inbox, stop and decision hooks. Grep the
  settings files for the old path and rewrite it.

## After the fleet is back

- **Check that the monitor reaches you.** Look for a fresh liveness note from
  the machine's watchdog in *your* inbox. If there has never been one, its
  messages are going somewhere else; find out where before you rely on it.
- Post a hold/status note on the cross-machine coordination channel so a sibling
  staging agent knows this machine is back.
- Watch `~/.cache/claude-attention/` for agents that come up blocked.
- **Resume watching the liveness heartbeat.** Once the machine is back, the
  monitor's heartbeat should start beating again; confirm a fresh one arrives and
  fold heartbeat-watching back into your standing inbox cadence (see
  [`external-alerts.md`](external-alerts.md)). Any agents you paused defensively
  on a stale-beat suspicion should be un-paused now.
- Remove the one-time `FLEET-RECOVERY-<date>.md` once the fleet is stable.
- Fold any new lesson back into this file.
