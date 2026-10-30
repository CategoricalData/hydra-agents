# Quota pacing: spending spare subscription quota before it resets

A Claude subscription has a weekly quota, with a 5-hour window on top, and
whatever is unused at the weekly reset is lost. Near the end of a week a fleet
can turn that spare quota into useful background work. But it has to know how
much is left, aim to arrive at a target by the reset, and stop before a limit
the user wants to keep. Left alone, the user ends up watching `/usage` by hand,
and nobody watches it overnight.

This page is the procedure: the reading, the verdict, who acts on it, and how
several fleets share one account. The tools are in `bin/quota/`. The status
line and its `rate_limits` field are Claude-Code-specific; the pacing is not.

## The reading: `bin/quota/statusline.sh`

Claude Code passes its status-line command a JSON object with `rate_limits`:
`five_hour` and `seven_day`, each with `used_percentage` and `resets_at`
(epoch seconds). `statusline.sh` records that object, with the time it was
read, to `$QUOTA_DIR/rate-limits.json` and prints `5h:NN% 7d:NN%`.

- **Install** it at the user level, opt-in: in the Claude config dir's `settings.json`,
  `"statusLine": {"type": "command", "command": "<agents>/bin/quota/statusline.sh"}`.
  To keep an existing status line, set `QUOTA_STATUSLINE_NEXT` to its command.
  It gets the same input and its output comes first.
- **`QUOTA_DIR`** defaults to `${CLAUDE_CONFIG_DIR:-~/.claude}/usage`, so each
  Claude account (config dir) on a machine records into its own directory.
- **The file is only as fresh as the last status-line redraw.** With no session
  running on the machine, it goes stale; the check reports `stale`.
- **Right after the weekly reset there may be no `seven_day` at all,** until the
  new week has use. The check reports `hold` then.

## The verdict: `bin/quota/quota-check.sh`

One verdict about **extra** work: spare-quota passes, optional jobs, anything
the fleet would not otherwise run. It never gates the work a fleet was asked to do.

| verdict | when | what the coordinator does |
|---|---|---|
| `go` | the use projected at the reset (current + recent burn × hours left) is below `--target` | launch one or two more workers |
| `hold` | on pace or ahead, or not enough readings for a burn rate | launch nothing extra; keep what's running |
| `ease` | within `margin × fleets` of `--limit`, or less than `--ease-hours` (default 1) before the reset | launch nothing new; let running work finish |
| `stop` | `--limit` reached; `$QUOTA_DIR/STOP` is written | launch nothing; wind down; leave work consistent |

The exit status is 0, 10, 11 or 12 respectively, and 3 when there is no
reading. `--json` prints the numbers: use, target, ease point, limit, hours
left, burn per hour, projected use at the reset, and the pace needed.

**Target and limit.** `--target` (default 90) is where to arrive at the reset,
a good unattended overnight goal. `--limit` (default: the target) is the hard
stop. Without the flags, both are read from `$QUOTA_DIR/target` and
`$QUOTA_DIR/limit` (one number each) when those files exist. So the user can
change them for every fleet on a machine at once: on waking to spare quota,
`echo 95 > target; echo 97 > limit`. The reset time always comes from the
reading (`resets_at`), never from a fixed clock time.

**Why 90 unattended, and not higher.** The fleet adapts to the user's own load,
because the burn it sees is the account's total: when the user's morning work
raises the burn, the projection rises and the fleet holds. But it can't give
back what it already spent overnight. Aim lower when nobody is watching, and
let the user raise the target when they know what the morning needs.

**Ease off before the limit.** Work already running keeps burning after the last
launch. In practice, stop launching about an hour before the reset, or a few
points under the limit; the defaults (`--ease-hours 1`, `--margin 3`) do both.

**Filters.** A reading whose `seven_day.resets_at` is older than the current
window is skipped, and so is a reading below the highest use seen in the window
(weekly use does not fall before the reset). Either way it most likely came from
another account's session on the same machine. Both accounts can share a reset
time, so the second rule is the one that catches them. A later `resets_at`
starts a new window: the state is reset and `STOP` is removed.

## Who acts on it: the coordinator

Pacing is a fleet-level decision, so it belongs to the **staging agent** (see
[`branch-flow.md` § Staging's non-issue duties](branch-flow.md#stagings-non-issue-duties)).
Staging runs `quota-check.sh` on a cadence (every 30 minutes is enough), and
before each batch of extra work, and acts on the verdict. Other agents check one
thing only, before each token-heavy step (a subagent, a pass, a large build):
`test -f "$QUOTA_DIR/STOP"`. Put that check in every spawn brief.

**An idle coordinator does not wake itself.** A cadence the coordinator only
intends to keep does nothing once its session is idle, and the fleet stalls with
quota left. Run `quota-check.sh --watch 600` as a background job. It exits when
the verdict changes (for example from `hold` to `go`), and its exit re-invokes
the session. Restart it after each wake.

## Several fleets on one account

Two or more independent fleets (different projects, or different machines)
can draw on the same account **at the same time**; the user doesn't have to pick
one. It's safe when:

1. **Every fleet reads the same number.** Use is per account and identical on
   every machine; each machine's status line records it.
2. **`stop` depends on that number alone, at the same limit everywhere.** Then every
   fleet stops at the same reading without any messages. Keep the limit in the
   shared `$QUOTA_DIR/limit` file (on each machine) rather than in per-project flags.
3. **Launches are small and staggered.** Each fleet's projection includes the
   other fleets' burn, so a fleet holds when the others already fill the gap. But two
   fleets that check at the same moment both see the same gap and both launch.
   Launch at most one or two workers per check, and offset the checks
   (one fleet at :00 and :30, another at :15 and :45), so each sees the effect of
   the other's last step.
4. **The ease margin scales with the number of fleets.** N fleets keep N times
   as much work running after they ease off. Pass `--fleets N` to every fleet's
   check: the ease point becomes `limit − margin × N`.

Even split between fleets is not guaranteed: whichever fleet checks while
there's room gets it. If the user wants a fleet to get less, give it a lower
`--target`; it then holds while the others still `go`.

## Spare-quota work

Good spare-quota work needs no live decision from the user, and can stop at
any point without leaving a mess:

- batch passes whose output is pending or reviewable (nothing applied until the
  user approves);
- code built and tested on synthetic data, delivered as PRs;
- reviews and QC of work already done.

Anything that needs the user's approval is queued for when they're back, and the
pace never touches shared state the user owns.

## Testing

`bin/quota/test-quota.sh` runs every verdict, filter and file rule on
synthetic readings in a temporary `QUOTA_DIR`; it reads no real quota.
