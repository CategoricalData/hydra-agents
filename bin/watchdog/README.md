# watchdog/

Lightweight monitoring for the `alpha` GCE workstation, which has been freezing
intermittently. The goal is to leave enough forensic breadcrumbs on disk that
the next freeze can be diagnosed after the fact, without keeping anything
expensive or stateful running between freezes.

## Design in one paragraph

Two independent collectors run continuously and write append-only logs:
a 5-second script-side **heartbeat** (so we know exactly when the kernel
stopped scheduling userspace tasks), and a 60-second **health snapshot**
(PSI, vmstat, top-RSS, dmesg/journal tails). Both fsync after every write so a
hard freeze loses at most one record. Neither involves a Claude session.
When something interesting happens — or after a freeze — a human or Claude
runs a one-shot analysis against a bounded slice of the logs. See
`runbook.md` for analysis recipes and `agent-spec.md` for the stateless
agent contract.

## Layout

```
watchdog/
├── README.md                  # this file — start here
├── runbook.md                 # how to read the logs after a freeze
├── agent-spec.md              # contract for any LLM-based analyzer
├── bin/
│   ├── heartbeat.sh           # 5s heartbeat (systemd Service)
│   ├── health-monitor.sh      # 60s snapshot (systemd Timer → oneshot)
│   ├── alert-staging.sh       # fires from health-monitor on a danger threshold;
│   │                          #   warns the Hydra staging agent (no Claude here)
│   └── heartbeat-staging.sh   # fires from health-monitor every ~10 min; sends a
│                              #   liveness ping to staging (dead-man's switch)
├── logs/
│   ├── heartbeat.log          # 1 line / 5s  (~20 MB rotate)
│   └── health.log             # 1 record / 60s  (~50 MB rotate)
├── archive/                   # preserved log snapshots, one dir per freeze
│   └── <UTC-timestamp>/       # e.g. 20260708T205024Z/ — see "Archiving" below
│       ├── *.log, *.log.1     # verbatim copies (cp -p, timestamps preserved)
│       ├── NOTES.md           # why archived + one-paragraph finding
│       └── MANIFEST.sha256    # integrity checksums
├── systemd/                   # canonical unit files (installed to /etc/systemd/system)
│   ├── instance-heartbeat-script.service
│   ├── instance-health-monitor.service
│   └── instance-health-monitor.timer
└── deprecated/                # do NOT resurrect; see deprecated/README.md
    ├── README.md
    ├── claude-heartbeat.sh
    └── claude-heartbeat.log
```

## Operational status

| Service                                 | Type      | When it starts                            |
|-----------------------------------------|-----------|-------------------------------------------|
| `instance-heartbeat-script.service`     | simple    | manually, after analysis (no auto-start)  |
| `instance-health-monitor.timer`         | timer     | manually, after analysis (no auto-start)  |
| `instance-health-monitor.service`       | oneshot   | triggered by the timer above              |

Auto-start at boot is deliberately disabled: after a freeze, the pre-crash
logs should sit untouched until somebody analyzes them. See
`runbook.md` for the analysis steps and `runbook.md`'s "Restart commands"
section for what to run when you're ready to resume monitoring.

## Quick reference

```bash
# Are the monitors running?
systemctl is-active instance-heartbeat-script.service instance-health-monitor.timer

# Most recent activity (does NOT stream — bounded read):
tail -1  ~/watchdog/logs/heartbeat.log
tail -50 ~/watchdog/logs/health.log

# Resume monitoring after a reboot (run only after you've analyzed the
# pre-crash logs):
sudo systemctl start instance-heartbeat-script.service
sudo systemctl start instance-health-monitor.timer

# Stop monitoring (e.g., before a planned reboot):
sudo systemctl stop instance-heartbeat-script.service instance-health-monitor.timer

# Re-install systemd units after editing watchdog/systemd/*:
sudo install -m 0644 ~/watchdog/systemd/*.service /etc/systemd/system/
sudo install -m 0644 ~/watchdog/systemd/*.timer   /etc/systemd/system/
sudo systemctl daemon-reload
```

## Post-freeze workflow: analyze → record findings → archive → resume

After a freeze, the order matters. **Analyze first, write the findings down,
archive the logs alongside those findings, and only then clear `logs/` and
restart the collectors.** The findings are the point — raw logs without a
conclusion age into noise. Do the whole thing while the monitors are still
`inactive` (they don't auto-start after a reboot — see "Operational status"),
so nothing is writing to `logs/` and the evidence stays intact.

1. **Analyze the pre-crash logs.** Read a bounded slice — the last few health
   snapshots and heartbeats before the boundary. See `runbook.md` for recipes
   and "When you ask Claude to do analysis" below for a starter prompt. Do
   **not** ingest whole logs; they're tens of MB.
2. **Come up with findings.** Identify the freeze boundary (boot_id change /
   uptime reset), the leading root-cause hypothesis, and the evidence for it
   (PSI/vmstat/swap trend, top-RSS offender, OOM or its absence).
3. **Record the findings in `NOTES.md`** as you archive (step 4). This is the
   deliverable: the freeze boundary plus a one-paragraph root cause with the
   numbers that support it. An archive without a `NOTES.md` finding is
   incomplete — future-you needs the conclusion, not just the bytes.
4. **Archive the logs with the findings**, then clear and resume:

```bash
# 4a. Name the archive dir for the freeze boundary (the last log write /
#     journal end), in compact UTC. Find it with:
#       tail -1 ~/watchdog/logs/heartbeat.log
#       journalctl -b -1 -o short-iso | tail -1
STAMP=20260708T205024Z          # <-- replace with this freeze's boundary
DEST=~/watchdog/archive/$STAMP
mkdir -p "$DEST"

# 4b. Copy every log, current and rotated, preserving timestamps (-p).
cp -p ~/watchdog/logs/health.log    ~/watchdog/logs/health.log.1 \
      ~/watchdog/logs/heartbeat.log ~/watchdog/logs/heartbeat.log.1 \
      "$DEST/"                    # .1 files may not exist yet — that's fine

# 4c. Write the findings from steps 1–2 into NOTES.md, and checksum for
#     integrity. NOTES.md is required, not optional.
$EDITOR "$DEST/NOTES.md"         # freeze boundary + one-paragraph root cause
( cd "$DEST" && sha256sum *.log *.log.1 > MANIFEST.sha256 )

# 4d. Only now clear the live logs and resume monitoring (see Quick reference).
: > ~/watchdog/logs/health.log
: > ~/watchdog/logs/heartbeat.log
sudo systemctl start instance-heartbeat-script.service
sudo systemctl start instance-health-monitor.timer
```

Notes:
- Truncate with `: > file` (not `rm`) so the running collectors keep their
  open file descriptors valid. Do the truncate **after** stopping/​before
  starting the services, i.e. while nothing is writing.
- Archives are the permanent forensic record — never edit a `*.log` inside
  `archive/`. Keep one directory per freeze; `NOTES.md` is what makes an old
  archive legible six months later.
- The first archived freeze, `archive/20260708T205024Z/`, is a worked example
  of the layout and the `NOTES.md` findings content.

## Alerting staging on danger (prevention, not just forensics)

The logs above are *forensic* — they explain a freeze after the fact. To
**prevent** the next freeze, the health-monitor also raises a live alert to the
Hydra build fleet while there is still headroom to act, so the fleet can back
off before the machine livelocks.

**There is no Claude in this path.** `alert-staging.sh` is a plain script. It
does not think, poll, hold context, or run continuously — it fires from
`health-monitor.sh` (already on a 60s timer) only when a threshold trips, writes
two files, and exits. This is deliberate: a watchdog that ran a live agent to
send alerts would be exactly the kind of memory/context consumer it exists to
catch. See "Where Claude fits in" below.

**Trigger** (in `health-monitor.sh`, tuned from the 2026-07-08 freeze where swap
hit 100% and PSI mem-stall reached 74%): fire when **swap used ≥ 90%** *or*
**PSI memory `some avg10` ≥ 40%** — earlier than the freeze point, so the alert
buys reaction time.

**What it does** (`alert-staging.sh`):

1. **Resolves the staging worktree dynamically.** The per-machine staging agent's
   name always begins with `staging` but is not always `staging-gce`, so the
   script globs `…/hydra/worktrees/staging*/` rather than hard-coding a path.
2. **Writes an advisory message** into that agent's
   `claude-hydra-messages/inbox/` using the Hydra filename convention
   (`<UTC>-watchdog-alpha-memory-pressure.md`). The staging agent's inbox hook
   surfaces it on its next turn — **staging** is the agent; the watchdog is not.
   The message names the leading top-RSS offender and recommends preventive
   action (throttle/pause the Haskell build workers), but leaves the decision to
   staging — the watchdog observes and warns, it never remediates.
3. **Drops an attention-marker** at
   `~/.cache/claude-attention/watchdog-alpha-memory-pressure.txt` — the urgent
   out-of-band channel the user and staging already watch — because a freeze is
   disruptive enough to interrupt, not just wait for staging's next prompt.
4. **De-bounces.** At most one alert per 15-minute cooldown (a stamp file at
   `logs/.last-staging-alert`), so a sustained squeeze produces a few alerts,
   not hundreds. This is what keeps alerts *infrequent*.

**No reply channel, by design.** The watchdog has no inbox because it has no
reader — removing Claude from the watchdog side means there is nobody here to
poll for or act on a response. Staging acts (or not) at its discretion; if a
human wants to know what staging did, that lives in staging's own transcript and
message archive, not here. (An earlier design gave the watchdog its own inbox so
staging could reply — but reading a reply implies either a polling loop or a
standing session, both of which reintroduce the accumulation we are avoiding, so
the inbox was dropped.)

To change the thresholds or cooldown, edit the danger-check block at the bottom
of `bin/health-monitor.sh` and `COOLDOWN_SECS` in `bin/alert-staging.sh`.

## Liveness heartbeat to staging (dead-man's switch)

The danger-alert above catches a freeze that is *building*. But a freeze that
arrives fast — or a monitor that itself dies — produces **no alert at all**,
because the very thing that would send it is gone. So the watchdog also sends a
positive **liveness heartbeat**, and staging watches for its **absence**.

`bin/heartbeat-staging.sh` (fired from `health-monitor.sh`, self-gating to once
per **~10 minutes**) writes a quiet "monitor is alive" note into the staging
agent's inbox. The contract:

- **The signal is the absence.** If the newest liveness note is **older than 15
  minutes**, the monitor or the machine has likely died — and *that staleness is
  the alert*. 15 min is chosen because staging is instructed to check its inbox
  at least every 15 minutes, so a stale beat is visible within one check cycle.
- **10-min send vs. 15-min alarm, on purpose.** Sending inside staging's check
  window means one missed/late beat won't false-alarm; it takes a genuine gap
  (roughly two missed beats) to cross 15 minutes. Sending *at* 15 min against a
  15-min check would false-alarm constantly on normal timing drift.
- **Self-overwriting, quiet.** The note uses a **stable filename**
  (`watchdog-alpha-liveness.md`), so each beat overwrites the last — staging's
  inbox holds exactly one liveness note whose freshness is the whole point, not
  ~144 files a day. Unlike a danger-alert it drops **no attention-marker**: a
  routine beat must not cry wolf.
- **Tied to the collector it vouches for.** Because the heartbeat rides
  `health-monitor.sh`, it stops precisely when that collector stops (crash,
  freeze, or the units being stopped) — which is exactly when staging should
  notice. A separate timer could keep beeping "alive" after the collector had
  silently died; this cannot.

The staging-side handling of a stale/absent beat is documented in the Hydra repo
(`claude/external-alerts.md`). To change the cadence, edit `SEND_INTERVAL_SECS`
in `bin/heartbeat-staging.sh` (and keep staging's alarm threshold comfortably
above it).

## Where Claude fits in

Claude is **not** part of the hot path. There is no Claude session running
continuously. The rules:

1. The static scripts in `bin/` do the collection **and the staging messaging**
   (both the danger-alert and the liveness heartbeat). They are the watchdog.
   `alert-staging.sh` / `heartbeat-staging.sh` messaging the staging agent is not
   an exception to this — each is a script writing a file, with no LLM in the
   loop. Do **not** "upgrade" either into an agent: the recipient (staging) is
   the agent; the sender stays a script.
2. Claude is used on-demand:
   - to **maintain** the scripts (add fields, adjust thresholds, fix bugs);
   - to **analyze** logs after an interesting event (a freeze, an OOM, a
     suspicious PSI excursion);
   - to **explain** novel patterns the scripts surface.
3. Any LLM agent that touches this directory must obey the stateless,
   bounded-context contract in `agent-spec.md`. If a future design wants
   to put an LLM on every tick, do it as a one-shot, externally scheduled,
   cold-start invocation — never an open session with `/loop` or
   `ScheduleWakeup`.

See `deprecated/README.md` for what happens when those rules are violated.

## When you ask Claude to do analysis

A useful starter prompt, run from your normal shell (not from inside a
long-lived session):

```bash
claude -p "Read ~/watchdog/runbook.md, then analyze the last 400 lines of
~/watchdog/logs/health.log and the last 200 lines of
~/watchdog/logs/heartbeat.log. Identify the freeze boundary (boot_id change
or uptime reset), summarize PSI/vmstat trends in the 5 snapshots before it,
and flag any process in top-RSS that wasn't there earlier in the boot."
```

The prompt is intentionally bounded ("last 400 lines"). Don't ask Claude
to ingest the whole log — it's tens of MB.
