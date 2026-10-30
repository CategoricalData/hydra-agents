---
name: quota-pacing
description: Pace a fleet's use of the Claude subscription quota near the weekly reset — check whether to launch spare-quota work (go/hold/ease/stop), install the status-line reading, raise or lower the target and limit, and keep a watch that wakes an idle coordinator. Use when asked about quota, usage, spare quota before the reset, "use up the quota", "stop before the limit", or when a coordinator plans extra work near a reset.
---

# Quota pacing

The procedure is `docs/quota-pacing.md` in the hydra-agents checkout; read it
for the reasons. This skill is the operational card.

**Find the tools.** This skill's directory is `<agents>/skills/quota-pacing`,
usually installed as a symlink. Resolve it, then use `<agents>/bin/quota/`:

```sh
Q="$(cd "$(dirname "$(readlink -f "<this skill's base directory>/SKILL.md")")/../../bin/quota" && pwd)"
```

`QUOTA_DIR` defaults to `${CLAUDE_CONFIG_DIR:-~/.claude}/usage`.

## Step 0, always: agree with the user what the spare quota is for

The tools only say how fast to go. *What* to spend the quota on is the user's
call, and it needs a conversation before any pacing starts. Propose, and let the
user choose, work that:
- **is relatively unlimited:** a backlog larger than the quota left (enrichment
  or research passes over a large corpus, test or QC sweeps, reviews), so `go`
  never runs out of things to launch;
- **can be throttled up and down** in small units: one worker or one batch at a
  time, each worth a fraction of a point;
- **stops cleanly at any point:** each unit is self-contained, and its output is
  pending or reviewable (claims to approve, PRs, reports);
- **needs no live decision from the user** while it runs (they may be asleep).

Record what was agreed: the work, its queue, the target and limit, and who
coordinates. Without that agreement, report the status and launch nothing.

## What was asked → what to do

**"Status" / "how much quota is left" / no argument:** run `"$Q/quota-check.sh"`
and report its line: the verdict, use, target, ease point, limit, hours to the
reset, burn per hour and projected use. Exit 3 means no reading: see *Install*.

**"Install":** check the Claude config dir's `settings.json`.
- If there's no `statusLine`, set `{"type": "command", "command": "<Q>/statusline.sh"}`.
- If there is one, keep it: set the command to
  `QUOTA_STATUSLINE_NEXT='<old command>' <Q>/statusline.sh`.

Show the user the change before writing it. Then confirm a reading appears in
`$QUOTA_DIR/rate-limits.json` after the next redraw.

**"Raise/lower the target or limit" (e.g. "aim for 95, stop at 97"):**
`echo 95 > "$QUOTA_DIR/target"; echo 97 > "$QUOTA_DIR/limit"`. That applies to
every fleet on this machine at its next check; other machines need the same
files. The defaults when they're absent are 90 and 90 (a good unattended overnight goal).

**Coordinating (staging, or whoever runs extra work near a reset):**
1. **First thing on every wake**, re-arm the watch as a background job:
   `"$Q/quota-check.sh" --watch 300 --heartbeat 1800`. It exits when the
   verdict changes, or every 30 minutes regardless, and its exit wakes you.
2. **Read every channel on that wake,** not only the inbox. Answers to your
   questions may be in the decision channel.
3. **Act on the verdict:**
   - `go`: launch one or two workers from a queue you prepared earlier. Cut the
     next batch while this one runs, so `go` never meets an empty queue.
   - `hold`: launch nothing extra; keep what's running.
   - `ease`: launch nothing new; let running work finish.
   - `stop`: `STOP` exists; wind down, and leave anything half-applied consistent.
4. **If several fleets share the account,** pass `--fleets N` and stagger your
   checks from the other fleets'. Also pass the same `--limit` everywhere, or use
   the shared `limit` file.

**Briefing a worker:** include this line in every spawn brief:
> Before each token-heavy step (a subagent, a pass, a batch, a large build, each
> request in a long fetch loop), run `test -f "$QUOTA_DIR/STOP"` and stop
> cleanly if it exists. Check between steps; don't rely on an `a && b | c` chain
> to halt.

**Never:**
- gate the work a fleet was asked to do on this verdict (it governs only extra work);
- raise the target or limit without the user;
- delete `STOP` by hand within a window (a new window removes it).
