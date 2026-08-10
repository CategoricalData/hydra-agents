# runbook.md — GCE crash investigation handover

> Layout note: this file lives at `~/watchdog/runbook.md`. The companion
> documents are `~/watchdog/README.md` (entry point) and
> `~/watchdog/agent-spec.md` (the watchdog agent contract — formerly
> `~/watchdog-agent.md`). All logs and scripts moved under `~/watchdog/` on
> 2026-06-15; old `/home/josh/instance-*` paths no longer exist.

> **READ THIS WHOLE FILE BEFORE DOING ANYTHING.** The previous agent ran an
> in-session `/loop` heartbeat for ~930 turns and became a major billing/quota
> problem and a plausible contributor to the very instance pressure it was
> supposed to be watching. **Do not repeat that.** The hard rules below are not
> suggestions.

---

## STOP — Hard rules for the next agent (read first, no exceptions)

These rules exist because the previous agent violated all of them.

1. **You are stateless per wake.** This conversation does NOT host a
   long-running watchdog. The watchdog spec is `~/watchdog/agent-spec.md` and
   is driven by an **external** scheduler (cron / systemd timer), not by
   `/loop`, not by `ScheduleWakeup`, not by anything inside the Claude
   session.
2. **NEVER call `ScheduleWakeup` from this session for monitoring purposes.**
   Not every 5 min, not every hour, not "just to keep the loop alive." The
   prior session did this 900+ times and accumulated ~930 turns of context
   that grew with every tick. That cost real money and put the `claude`
   process itself among the top RSS consumers on the box you're meant to be
   watching.
3. **NEVER run `/loop` from this session for monitoring purposes.** Same
   reason. If you find yourself writing a heartbeat tick from inside a Claude
   turn, you have already failed.
4. **The Claude-side heartbeat is DEPRECATED.** The old script and log live
   at `~/watchdog/deprecated/claude-heartbeat.{sh,log}` for forensic
   comparison only. Do not invoke the script. Do not write new ticks to the
   log. If Josh asks for a Claude-presence signal, point him at
   `~/watchdog/agent-spec.md`: a stateless one-shot invocation driven
   externally, **not** an open Claude session ticking on a timer.
5. **You may NOT auto-restart the monitoring services on the user's behalf.**
   They are `static`. If Josh asks you to start them, run the documented
   commands (below) and stop. Do not arm anything that loops back into a
   Claude tool call.
6. **If a `claude` / `node` / agent process appears in the top RSS list of a
   snapshot, that IS a finding.** Surface it plainly. A watchdog (or a
   Claude session) that won't implicate itself is useless on exactly the
   failure mode that matters here.
7. **Bounded context.** Don't `cat` or `tail -F` the full snapshot log into
   your context. Use line-counted reads (`tail -n 400`, `awk` boundary
   queries). Read targeted segments. If you find yourself ingesting megabytes
   of log, stop and narrow the query.
8. **Observe, don't remediate.** Don't restart services, kill processes, or
   edit configs to "fix" what you find. Report it.

If any of these rules feels inconvenient, re-read `~/watchdog/agent-spec.md`.
The inconvenience is the point: a watchdog that's expensive or stateful
becomes the failure it's meant to detect.

---

## TL;DR for the next agent

After a crash, Josh restarted Claude and pointed you here. Your job, in order:

1. **Do NOT auto-restart the monitoring services.** They are deliberately
   configured `static` (not enabled) so a reboot leaves them stopped. The
   pre-crash logs are intact on disk. You analyze first, then ask Josh
   whether to restart.
2. **Look at `~/watchdog/logs/heartbeat.log` first** — this is the systemd
   heartbeat, written every 5s with `sync -d`. Its last line tells you
   roughly when the kernel stopped scheduling userspace tasks. Compare
   `T_script` against the timestamp of the next boot's first log entry to
   bound the freeze window.
3. **Analyze `~/watchdog/logs/health.log`** to find the snapshots leading up
   to the freeze. Reboot creates an obvious gap and a new `boot_id`. See
   "How to analyze the log after the next crash" below.
4. **Correlate with the kernel/journal logs** from the boot that crashed
   (`journalctl -b -1 …`). See queries below.
5. **Report findings to Josh.** Concrete suspects only: PSI spike? specific
   process eating RSS? OOM storm? IO stall? maintenance event? If the
   monitor itself (claude/agent/node) appears in the top-RSS list pre-crash,
   say so directly — that was a real risk created by the prior agent's
   design.
6. **Only after Josh approves**, restart the monitoring services (see
   "Restart commands" at the bottom of this doc). Do **not** restart the
   Claude-side heartbeat — it's deprecated.

Don't re-derive the context below from scratch — it's here so you can spend
your context window on the actual analysis, not on rediscovering the setup.

## Why this exists

Josh's GCE workstation (`alpha`) has crashed 5+ times in roughly 5 days
(2026-06-07 → 2026-06-12). He runs multiple concurrent Claude Code sessions and
sometimes heavy GHC/`stack` builds. The crashes don't always correlate with
obvious high load. We set up this monitor so the next crash leaves enough
forensic breadcrumbs in a persistent log file to actually diagnose it.

## Critical symptom (added 2026-06-12)

During a "crash," GCE **still reports the instance as running** but all
communication fails: existing Claude/remote sessions silently disconnect, new
SSH attempts time out, the metadata server presumably still responds to the
host. The instance does not return to service until it is manually restarted
(or eventually auto-restarted), at which point a new `boot_id` appears.

**This rules out a Google-side hard reset and points squarely at the guest
kernel becoming unresponsive** — networking dead, sshd dead, journald not
flushing — while the hypervisor still sees the VM as up. Most likely causes
for that signature:

- **Memory pressure → swap thrash → IO stall**: kernel still "alive" but every
  task is blocked on swap-in from disk. PSI `memory.full` and `io.full` would
  pin near 100. SSH `accept()` never schedules.
- **Soft/hard lockup on a CPU** that didn't get logged because journald was
  starved.
- **Network stack hang** (less likely; would usually leave the console
  reachable, but we have no console here).
- **OOM killer storm** that took out essential daemons (sshd, systemd-networkd)
  without panicking the kernel.

This means: the snapshot ~1 minute before the freeze is the most valuable
artifact. The monitor's job is to capture the lead-up state at higher fidelity
than journald can preserve during a freeze, because we know journald will
*lose* its last buffers.

## Lessons from the previous agent (read before you design anything)

The previous agent's design had a fatal flaw: it used the *Claude session
itself* as the second heartbeat. It armed `/loop` with `ScheduleWakeup` every
~4 minutes, each tick writing one line to
`~/instance-heartbeat-claude.log` and rescheduling itself. Over ~3 days that
became:

- ~930 turns of accumulated transcript context (the harness keeps prior
  turns visible to the model).
- ~930 round-trips of model inference, each billed.
- A persistent `claude` process consistently in the top RSS list of the
  watched machine — i.e. the watchdog became one of the heaviest processes
  on the box it was watching.

The lesson, which is now baked into `~/watchdog/agent-spec.md`: **a stateful,
long-lived monitoring agent is itself an instability source**, and on a
billed model is also a budget problem. The replacement spec: each wake is a
cold start, driven by an external scheduler, with bounded context, emitting
one structured JSON record. Do not undo that.

If Josh asks for "a Claude heartbeat" or "something that proves Claude is
alive," the answer is: **no in-session loop.** If we need a Claude-side
signal, it should be a cron job that runs the agent-spec.md prompt as a
one-shot — stateless, externally scheduled, billed once per wake, not 900
times per day.

## Instance facts (as of 2026-06-12)

- Hostname: `alpha`
- GCE machine type: **e2-standard-8** (8 vCPU AMD EPYC 7B12, 32 GiB RAM)
- Scheduling: `preemptible=FALSE`, `automaticRestart=TRUE`, `onHostMaintenance=MIGRATE`
- Disk: `/dev/sda1`, 200 GB, ext4, root `/`. About 29% used.
- Swap: 16 GiB swapfile at `/swapfile` (priority -2).
- Zone: `us-west1-c`, project `cognisee-demos`.
- OS: Debian 12, kernel `6.1.0-49-cloud-amd64` (Debian 6.1.174-1).
- Hypervisor: KVM (Google host).
- Primary user: `josh` (uid 1000). `loginctl Linger=no` — user systemd manager
  does NOT persist after logout, which is why we use system-level units.

## Reboot pattern observed so far

`last -x | grep -E "reboot|crash"` showed sessions ending in `crash`, not a
clean shutdown. `journalctl --list-boots`:

| Boot | Started UTC          | Ended UTC            | Notes                                |
|------|----------------------|----------------------|--------------------------------------|
| -6   | 2026-05-27 17:53     | 2026-06-07 05:04     | kernel upgrade 6.1.0-47 → 6.1.0-49   |
| -5   | 2026-06-07 05:04     | 2026-06-10 06:19     |                                      |
| -4   | 2026-06-10 06:28     | 2026-06-10 07:36     | short — ~1 h                         |
| -3   | 2026-06-10 07:50     | 2026-06-10 17:13     |                                      |
| -2   | 2026-06-10 17:21     | 2026-06-11 04:46     |                                      |
| -1   | 2026-06-11 04:46     | 2026-06-12 18:50     | **OOM-killed `guile` x2 during stack/ghc build** |
| 0    | 2026-06-12 19:11     | (current)            |                                      |

Gap between boot -1's last log entry (18:50:23) and boot 0's first (19:11:45) =
~21 minutes. No graceful-shutdown messages (`Reached target Shutdown` etc.) for
recent reboots. The journal terminates mid-output (a multi-line interface dump),
which is what a hard reset looks like — buffered journal lines were never
flushed.

## Findings from the most recent crash (2026-06-12 ~18:50–19:11)

- **No kernel panic, OOM, MCE, soft-lockup, or hung-task** in `journalctl -b -1 -k`.
- **No clean shutdown** marker (no `Reached target Shutdown` from systemd, no
  shutdown wtmp record).
- Journal ends abruptly at 18:50:23, ~21 min before boot 0 starts.
- Last "interesting" pre-cutoff signals: `google_guest_agent_manager` reporting
  `Plugin health check failed … context deadline exceeded` for both
  `GuestAgentCorePlugin` and `GuestTelemetryExtension` (18:47:52, 18:50:04),
  followed by the manager restarting both plugins. Then the journal stops.
- Earlier in the same boot (Jun 11): OOM-killed `guile` twice (PID 8200 at
  05:12; PID 85354 at 13:30) — both ~30 GiB RSS, both inside a `stack` /
  `ghc-9.10.2` build (`test-scheme-tar`).

### Best-guess diagnosis for *this* crash

With the "GCE still reports the VM as running, but all comms fail" symptom:
this is **not** a hypervisor-side reset. The guest kernel went unresponsive —
likely memory/IO pressure during a build pushed the system into a state where
userspace (sshd, journald, networking) couldn't make progress. The guest-agent
`Plugin health check failed … context deadline exceeded` messages a few
minutes before the journal cutoff are exactly what a kernel starting to stall
looks like: timers fire, but tasks can't be scheduled in time, so RPC ACKs
miss their deadlines. Eventually journald itself can't flush. The journal
then terminates mid-output and the VM has to be manually rebooted because no
userspace daemon can respond.

The pattern across all 5 crashes — no panic, no clean shutdown, abrupt log
termination, VM still "running" per GCE — is consistent.

### Open questions the monitor is designed to answer

- Was the system actually under memory pressure at crash time? (PSI counters)
- Was the swap being thrashed? (`pswpin`/`pswpout` deltas, `pgmajfault` deltas)
- Was a build process running with multi-GB RSS at crash time?
- Was the IO subsystem stalled? (PSI `io.full`, `procs_blocked > 0`)
- Were there GCE maintenance events?
- **Was the watchdog/monitoring itself contributing to RSS pressure?**

## Heartbeats and snapshots — what's actually running

There are two persistent monitors. Neither involves a Claude session.

### `~/watchdog/logs/heartbeat.log` (active)

Written by `instance-heartbeat-script.service`, a systemd Service that runs
`~/watchdog/bin/heartbeat.sh` in a loop, one line every 5 seconds, `sync -d`
after each write. Each line:
`tick ts=<UTC ms> uptime=<seconds> load1=<n>`. Rotates at 20 MB.

**This stops when the kernel stops scheduling userspace tasks or the disk
stops accepting writes.** That's the signal we want post-freeze: the last
tick's timestamp is the latest-bound moment the box was still alive at the
kernel level.

### `~/watchdog/logs/health.log` (active)

Written by `instance-health-monitor.service`, triggered by
`instance-health-monitor.timer` every 60 s. The script is
`~/watchdog/bin/health-monitor.sh`. Each snapshot includes PSI (cpu/memory/io),
vmstat counters, diskstats, top-8-RSS processes, load, kernel and journal
warning tails, GCE `maintenance-event`. Rotates at 50 MB.

### `~/watchdog/deprecated/claude-heartbeat.log` (DEPRECATED — do not resume)

This was the prior agent's mistake. It's left on disk for forensic
comparison only. Do not write new ticks. Do not invoke
`~/watchdog/deprecated/claude-heartbeat.sh`. See "Lessons from the previous
agent" above and `~/watchdog/deprecated/README.md`.

The stale `~/.claude/settings.json` allowlist entry for the old
Claude-heartbeat script was removed on 2026-06-15. If anything similar
reappears, don't resurrect the script.

### Interpreting freeze evidence after a crash

Let `T_script` = timestamp of the *last* line of `~/watchdog/logs/heartbeat.log`
in the pre-crash boot. Let `T_boot` = timestamp of the first journal entry of
the recovery boot. The freeze window is `[T_script, T_boot]`.

Inside the snapshot log, walk back from the boundary (last `boot_id` change)
and look at the final 3–5 snapshots from the *old* boot. PSI / vmstat /
top-RSS in those snapshots are the ground truth for what was happening as the
box died.

Useful queries:

```bash
echo "=== last script tick ===";  tail -1 /home/josh/watchdog/logs/heartbeat.log
echo "=== current time     ===";  date -u +'%Y-%m-%dT%H:%M:%SZ'
echo "=== boot table       ===";  sudo journalctl --list-boots | tail -10

# Largest inter-tick gap in the script log (in seconds) — finds the freeze:
awk '
  match($0, /ts=([0-9-]+T[0-9:]+\.[0-9]+Z)/, m) {
    cmd = "date -u -d \"" m[1] "\" +%s.%N"; cmd | getline cur; close(cmd)
    if (prev != "") {
      d = cur - prev
      if (d > maxd) { maxd = d; gap_line = NR; gap_ts = m[1] }
    }
    prev = cur
  }
  END { printf "max gap = %.1f s before line %d at ts=%s\n", maxd, gap_line, gap_ts }
' /home/josh/watchdog/logs/heartbeat.log
```

## Restart commands (run only after analysis, and only if Josh asks)

```bash
sudo systemctl start instance-heartbeat-script.service
sudo systemctl start instance-health-monitor.timer
# Do NOT restart the Claude-side heartbeat. It is deprecated.
```

## How to analyze the log after the next crash

1. **Find the reboot boundary.** Each snapshot line starts with
   `===== <UTC> uptime=<secs> boot_id=<uuid> =====`. A reboot shows up as a
   `boot_id` change AND a sudden drop in `uptime`. The last snapshot with the
   *old* `boot_id` is your "last words before the crash."

   ```bash
   awk '/^===== / {match($0, /boot_id=([^ ]+)/, m); if (m[1] != last) {print NR": "$0; last=m[1]}}' ~/watchdog/logs/health.log
   ```

2. **Look at the last 3–5 snapshots before the boundary.** Concretely:

   ```bash
   awk '/^===== / {match($0, /boot_id=([^ ]+)/, m); if (m[1] != last) {boundary=NR; last=m[1]}} END {print boundary}' ~/watchdog/logs/health.log
   ```

   Then `sed -n '<boundary-300>,<boundary>p' ~/watchdog/logs/health.log` —
   read a bounded slice, not the whole file.

3. **What to look for:**
   - `psi.memory: some avg10=` rising into double digits, especially
     `full avg10` > 0 → real memory stall.
   - `psi.io: full avg10=` rising → IO stall (swap thrash, disk).
   - `procs_blocked` > 0 sustained → tasks waiting on uninterruptible IO.
   - `pswpin`/`pswpout` increasing rapidly between snapshots → swap thrashing.
     (They are cumulative; take the delta.)
   - A `ghc-9.10.2` / `guile` / `stack` / `cabal` process with RSS climbing past
     ~10 GiB.
   - **A `claude` / `node` / agent process in the top-RSS list** — flag this
     plainly. The prior agent's session was a contributor.
   - dmesg warnings section non-empty.
   - GCE `maintenance-event` != `NONE`.

4. **Cross-check with the journal from the crashed boot:**

   ```bash
   sudo journalctl -b -1 --no-pager -o short-iso | tail -100
   sudo journalctl -b -1 -k --no-pager -o short-iso | tail -100
   sudo journalctl --no-pager 2>&1 \
     | grep -iE 'panic|oom|killed process|hung_task|soft lockup|hard lockup|nmi|mce|segfault|stall'
   sudo journalctl --list-boots | tail -10
   ```

5. **If the log shows NO concerning signals just before the crash**, check:
   - GCE serial-port output (from the Google Cloud Console; not accessible from
     inside the VM).
   - Cloud Logging `compute.googleapis.com/activity_log` for
     `compute.instances.guestTerminate` / `hostError` / `automaticRestart` events.
   - `gcloud compute instances describe alpha --zone us-west1-c` →
     `lastStartTimestamp`, `lastStopTimestamp`.

## Useful one-liners (bounded reads only)

```bash
# Most-recent N snapshots — bounded:
tail -n 400 ~/watchdog/logs/health.log

# How many snapshots per boot:
awk '/^===== / {match($0, /boot_id=([^ ]+)/, m); print m[1]}' ~/watchdog/logs/health.log | sort | uniq -c

# Watch real-time PSI (do NOT leave this running in a Claude tool call):
for f in /proc/pressure/*; do echo "== $f =="; cat $f; done
```

Avoid `tail -F` and `watch` from inside a Claude tool call — they don't end
on their own and waste tokens.

## Files & where they live

- `/home/josh/watchdog/README.md` — entry point for the directory.
- `/home/josh/watchdog/agent-spec.md` — **the operating spec for any future
  watchdog agent.** Read it. It supersedes anything in this file that
  conflicts.
- `/home/josh/watchdog/runbook.md` — this document.
- `/home/josh/watchdog/logs/health.log` — snapshot log, rotated at 50 MB
  (`.1` backup).
- `/home/josh/watchdog/bin/health-monitor.sh` — the snapshot script.
- `/home/josh/watchdog/logs/heartbeat.log` — script-side heartbeat,
  1 line / 5 s, rotated at 20 MB.
- `/home/josh/watchdog/bin/heartbeat.sh` — the heartbeat loop.
- `/home/josh/watchdog/deprecated/claude-heartbeat.log` — **DEPRECATED**
  Claude-side heartbeat log. Forensic value only; do not append.
- `/home/josh/watchdog/deprecated/claude-heartbeat.sh` — **DEPRECATED**
  Claude-side heartbeat script. Do not invoke.
- `/home/josh/watchdog/systemd/*` — canonical copies of the three installed
  unit files; edit here, then `sudo install` to `/etc/systemd/system/`.
- `/etc/systemd/system/instance-health-monitor.service` — snapshot oneshot.
- `/etc/systemd/system/instance-health-monitor.timer` — snapshot timer
  (`static`, manual start).
- `/etc/systemd/system/instance-heartbeat-script.service` — heartbeat service
  (`static`, manual start, `Restart=always` once started).

## Known caveats / limitations

- The snapshot monitor runs every 60s, so the *exact* moment the freeze
  begins is somewhere in a ≤60-s window after the last snapshot. The
  5-second script heartbeat narrows that window.
- `sync -d` does its best, but on a true hard reset some buffered writes can
  still be lost. The previous-snapshot data is the safest forensic state.
  Because the *header* is flushed before the body, even a half-written
  snapshot tells you the last *attempted* timestamp + boot_id.
- `dmesg` and `journalctl --since '5 min ago'` may be empty when nothing is
  wrong — that's expected. Their value is in the snapshots immediately before
  a crash.
- The `pgrep` count line only prints processes that actually exist; missing
  names = zero, not an error.
- The journal-warning section filters sshd `Invalid user` / `Disconnected`
  noise so brute-force scans don't drown the signal.
- **The deprecated Claude-side heartbeat distorted the prior crash window's
  RSS profile.** Any `claude` process you see in old snapshots may be the
  watchdog itself, not user work. After the agent restart, fresh snapshots
  should be cleaner.
