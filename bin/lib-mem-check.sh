#!/usr/bin/env bash
# lib-mem-check.sh — hold a heavy build until the machine has enough free memory.
#
# Problem: a shared machine running many agent sessions can sit for weeks with
# its RAM and swap nearly full, because the sessions themselves are the base
# load. One more heavy build on top of that does not fail cleanly: the kernel
# keeps reclaiming instead of OOM-killing, the box livelocks, and userspace
# (SSH included) stops being scheduled until someone resets the VM. On one
# fleet this froze the machine twice (2026-07-08, 2026-10-30); the second time,
# a build slot was granted with swap ~93% full and two memory-hungry stages of
# the same build finished the box off 45 minutes later.
#
# Companion to lib-disk-check.sh, with one deliberate difference: disk space
# rarely comes back on its own, so the disk guard fails fast; memory pressure
# usually does pass (another build finishes, a session exits), so the useful
# behaviour here is to WAIT, bounded, and only then give up. A caller that
# serializes heavy builds (a lock/slot wrapper) should wait while holding its
# slot, so no other heavy build starts in the meantime either.
#
# Usage:
#   . "$(dirname "$0")/lib-mem-check.sh"   # or the hydra-agents checkout path
#   ha_wait_mem_headroom 6144 3600 || exit 1    # need ~6 GiB, wait up to 1 h
#
# Only the threshold and wait are project-specific; pick the threshold from
# the build's observed peak resident size plus a margin.

# ha_mem_available_mb
# Prints the kernel's estimate of memory available to a new workload, in MB,
# WITHOUT counting swap (swap is what the machine falls into, not headroom).
# Linux: MemAvailable from /proc/meminfo. macOS: free + inactive + speculative
# + purgeable pages from vm_stat. Prints nothing and returns 1 if unknown.
ha_mem_available_mb() {
    if [ -r /proc/meminfo ]; then
        awk '/^MemAvailable:/ { printf "%d\n", $2 / 1024; found=1 } END { exit !found }' /proc/meminfo
        return
    fi
    if command -v vm_stat >/dev/null 2>&1; then
        vm_stat | awk '
            /page size of/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) ps = $i }
            /^Pages (free|inactive|speculative|purgeable):/ { gsub(/\./, "", $NF); pages += $NF }
            END { if (ps > 0 && pages > 0) { printf "%d\n", pages * ps / 1048576 } else exit 1 }'
        return
    fi
    return 1
}

# ha_check_mem_headroom <needed_mb>
# One-shot check. Prints a one-line diagnostic to stderr either way. Returns 0
# if available >= needed, 1 if not. If available memory cannot be determined on
# this platform it warns and returns 0 (fails OPEN): unlike disk, a memory check
# that cannot run must not block every build on that platform forever.
ha_check_mem_headroom() {
    local needed_mb="$1" avail_mb
    if [ -z "$needed_mb" ]; then
        echo "ha_check_mem_headroom: usage: ha_check_mem_headroom <needed_mb>" >&2
        return 1
    fi
    if ! avail_mb=$(ha_mem_available_mb) || [ -z "$avail_mb" ]; then
        echo "ha_check_mem_headroom: cannot determine available memory on this platform; not blocking" >&2
        return 0
    fi
    if [ "$avail_mb" -lt "$needed_mb" ]; then
        echo "ha_check_mem_headroom: only ${avail_mb}MB memory available, need ~${needed_mb}MB" >&2
        return 1
    fi
    echo "ha_check_mem_headroom: ${avail_mb}MB memory available (need ~${needed_mb}MB) — OK" >&2
    return 0
}

# ha_wait_mem_headroom <needed_mb> [max_wait_secs=3600] [poll_secs=60]
# Waits until ha_check_mem_headroom passes, re-checking every poll_secs and
# printing a status line about every 5 minutes. Returns 0 once there is
# headroom, 1 if max_wait_secs elapses first. Set HA_MEM_CHECK_SKIP=1 to bypass
# (logged) when a human has decided to run anyway.
ha_wait_mem_headroom() {
    local needed_mb="$1" max_wait="${2:-3600}" poll="${3:-60}" waited=0 last_note=0
    if [ "${HA_MEM_CHECK_SKIP:-0}" = "1" ]; then
        echo "ha_wait_mem_headroom: HA_MEM_CHECK_SKIP=1 — skipping the memory guard" >&2
        return 0
    fi
    while ! ha_check_mem_headroom "$needed_mb" 2>/dev/null; do
        if [ "$waited" -ge "$max_wait" ]; then
            ha_check_mem_headroom "$needed_mb"   # print the final numbers
            echo "ha_wait_mem_headroom: still short of memory after ${waited}s — giving up rather than risk a livelock" >&2
            return 1
        fi
        if [ "$waited" -eq 0 ] || [ $((waited - last_note)) -ge 300 ]; then
            echo "ha_wait_mem_headroom: $(ha_mem_available_mb 2>/dev/null || echo '?')MB available, need ~${needed_mb}MB; waiting (${waited}s of ${max_wait}s)" >&2
            last_note="$waited"
        fi
        sleep "$poll"
        waited=$((waited + poll))
    done
    ha_check_mem_headroom "$needed_mb"
}
