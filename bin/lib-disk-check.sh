#!/usr/bin/env bash
# lib-disk-check.sh — fail fast before a multi-GB build if disk headroom is too low.
#
# Problem (hydra-agents#3): a shared machine running many concurrent agent
# worktrees accumulates large per-worktree build caches (e.g. Haskell's
# .stack-work, 5-7GB each). Twice on one fleet, root disk hit 0 bytes free
# while a heavy build was already in flight, and the build died mid-write
# with ENOSPC — not a clean failure, a crash partway through generating
# output, which can leave corrupted/truncated artifacts behind. Recovery both
# times was entirely manual. See docs/history (consuming project) for the
# incident writeups this issue was filed from.
#
# This library provides one reusable check: before a script commits to a
# build it expects to consume several GB, call ha_check_disk_headroom with
# the amount of headroom (in MB) the build needs. On insufficient space, it
# prints a clear message to stderr and returns non-zero — the CALLER decides
# whether to abort (the expected use), not this function, so a script with a
# different risk tolerance can still choose to proceed.
#
# Usage:
#   . "$(dirname "$0")/lib-disk-check.sh"   # or the hydra-agents checkout path
#   if ! ha_check_disk_headroom 6144; then
#       echo "aborting: not enough disk for this build" >&2
#       exit 1
#   fi
#
# Deliberately NOT a retention/eviction policy (clearing old caches) — see
# the issue's non-goals. This is just the fail-fast guard.

# ha_check_disk_headroom <needed_mb> [path]
# Checks available space (MB) on the filesystem containing `path` (default: .)
# against `needed_mb`. Prints a one-line diagnostic to stderr either way, so
# callers get visibility into the margin even when the check passes. Returns
# 0 if available >= needed, 1 otherwise (including if `df` itself fails —
# fail closed, since a disk check that can't run is not a disk check that
# passed).
ha_check_disk_headroom() {
    local needed_mb="$1"
    local path="${2:-.}"
    local avail_mb

    if [ -z "$needed_mb" ]; then
        echo "ha_check_disk_headroom: usage: ha_check_disk_headroom <needed_mb> [path]" >&2
        return 1
    fi

    # df -Pm: POSIX output format (stable column layout across platforms),
    # sizes in MB. Tail -1 skips the header; last field is "Avail" ONLY under
    # -P (POSIX locks the column order), which is why -P is load-bearing here,
    # not just a portability nicety.
    avail_mb=$(df -Pm "$path" 2>/dev/null | tail -1 | awk '{print $4}')

    if [ -z "$avail_mb" ] || ! [ "$avail_mb" -eq "$avail_mb" ] 2>/dev/null; then
        echo "ha_check_disk_headroom: could not determine free space for '$path' (df failed or gave unexpected output) — failing closed" >&2
        return 1
    fi

    if [ "$avail_mb" -lt "$needed_mb" ]; then
        echo "ha_check_disk_headroom: only ${avail_mb}MB free on '$path', need ~${needed_mb}MB for this build — aborting before ENOSPC corrupts output" >&2
        return 1
    fi

    echo "ha_check_disk_headroom: ${avail_mb}MB free on '$path' (need ~${needed_mb}MB) — OK" >&2
    return 0
}
