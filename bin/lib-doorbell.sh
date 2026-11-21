#!/usr/bin/env bash
# lib-doorbell.sh — ring a recipient's doorbell after delivering an inbox file.
#
# The message is the file in the recipient's claude-hydra-messages/inbox/ (copy →
# verify → archive, docs/cross-worktree-messages.md). The doorbell only tells the
# recipient it is there. Delivery mechanisms differ by runner, so the doorbell is
# pluggable (hydra-agents#7): each backend is a function ha_doorbell_<backend>,
# tried in the order given by the config's `doorbells` (default: the runner
# adapter's HA_RUNNER_DOORBELLS), with tmux always last as the baseline.
#
# Backend contract: ha_doorbell_<name> <recipient-session> <recipient-branch> <text>
#   returns 0  delivered, or (for a backend only the agent itself can perform, such
#              as a tool call) printed exact instructions for the agent to perform
#   returns 2  not applicable here (e.g. no such tmux session); try the next one
#   returns 1  tried and failed; try the next one
#
# Backends:
#   claude-sendmessage  Claude Code's SendMessage is a tool the agent calls, not a
#                       command, so this prints the recipient and text to send. It
#                       applies only inside a Claude Code session (CLAUDECODE set).
#   tmux                types the text into the recipient's tmux pane: text and
#                       Enter as separate keystroke events, then checks the pane.
#
# A new runner adds its backend here (or in its adapter file) and lists it in its
# HA_RUNNER_DOORBELLS.

# ha_doorbell_text <sender-branch> <filename> <reply-dir>
ha_doorbell_text() {
    printf 'From %s: new message %s in your inbox; reply to %s' "$1" "$2" "$3"
}

ha_doorbell_claude-sendmessage() {
    [ -n "${CLAUDECODE:-}" ] || return 2
    cat <<EOF
doorbell: send this with your SendMessage tool (backend claude-sendmessage):
  to:      $1
  message: $3
If the send fails, or its result says the message was held or refused, rerun
this command with --fallback to ring the tmux doorbell instead.
EOF
    return 0
}

ha_doorbell_tmux() {
    local session="$1" branch="$2" text="$3" target="" t pane
    command -v tmux >/dev/null 2>&1 || return 2
    # The computed name first; then the bare branch, the session name used before
    # the project prefix existed (hydra-agents#1).
    for t in "$session" "$branch"; do
        if tmux has-session -t "=$t" 2>/dev/null; then target="$t"; break; fi
    done
    [ -n "$target" ] || return 2
    tmux send-keys -t "=$target:" "$text" && sleep 0.3 && tmux send-keys -t "=$target:" Enter || return 1
    sleep 2
    pane="$(tmux capture-pane -t "=$target:" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -5)"
    echo "doorbell: rang tmux session $target; its pane now ends with:"
    printf '%s\n' "$pane" | sed 's/^/  | /'
    echo "doorbell: confirm the line above was submitted, not left in the input box."
    return 0
}

# ha_ring_doorbell <recipient-session> <recipient-branch> <text> [--fallback]
# Tries each backend in order; --fallback skips backends the agent performs itself
# (those whose output is instructions), going straight to the scripted ones.
ha_ring_doorbell() {
    local session="$1" branch="$2" text="$3" fallback="${4:-}" b list rc tried=""
    list="${HA_DOORBELLS:-${HA_RUNNER_DOORBELLS:-}}"
    case " $list " in *" tmux "*) ;; *) list="$list tmux" ;; esac
    for b in $list; do
        if [ "$fallback" = "--fallback" ] && [ "$b" = "claude-sendmessage" ]; then continue; fi
        if ! declare -F "ha_doorbell_$b" >/dev/null; then
            echo "doorbell: unknown backend '$b' (no function ha_doorbell_$b); skipping" >&2
            continue
        fi
        "ha_doorbell_$b" "$session" "$branch" "$text"; rc=$?
        [ "$rc" -eq 0 ] && return 0
        tried="$tried $b(${rc})"
    done
    echo "doorbell: no backend could ring $session (tried:${tried:- none}). The inbox file is" >&2
    echo "          delivered; the recipient will find it on its next inbox sweep." >&2
    return 1
}
