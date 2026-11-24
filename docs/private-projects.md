# Setting up a private project

A recipe for running the harness on a **private** repository. The rules behind each step are in
[cross-worktree-messages.md § Project isolation](cross-worktree-messages.md#project-isolation);
read that first if any step is unclear. Examples use placeholders (`acme/secret`).

## 1. Declare the visibility

In the project's `hydra-agents.json`:

```json
"visibility": "private"
```

The harness would detect it with `gh repo view` and fail closed to private, but declaring it keeps
the decision explicit and works offline.

## 2. Check in the guard

From any worktree of the project:

```sh
<agents>/bin/project-guard --write     # merges the guard into .claude/settings.json
git add .claude/settings.json && git commit -m "Check in the cross-session isolation guard"
<agents>/bin/project-guard --check     # verifies it; exit 0 when complete
```

Merge the commit to `main` so that every new worktree (spawned from `origin/main`) and every
clone on every machine has it. If your `.gitignore` excludes `.claude/`, un-ignore
`.claude/settings.json` (for example `!.claude/settings.json`), while keeping
`.claude/settings.local.json` ignored.

**What it contains (Claude Code):** the peer-scope hook (`bin/claude-hooks/peer-scope.sh`, a
PreToolUse hook on `SendMessage` and `ListAgents`) and `isolatePeerMachines: true`:

| | Within the project | Outside the project |
|---|---|---|
| **Send** (`SendMessage`) | allowed, no prompt | asks the human (not blocked) |
| **Discover** (list sessions) | the project's own names are computed, no prompt | `ListAgents` asks the human |

The hook recognizes the project's own sessions by computing their names (every worktree, by folder
and by branch, plus `stagingPeers`); it never lists sessions to find them. `isolatePeerMachines`
also asks for every send to another machine. An `ask` rule for `SendMessage` would outrank the
hook's `allow`, so the guard has none: `--check` reports one left by an earlier guard as stale, and
`--write` removes it (and the old `ListAgents` deny; set `listAgents` to `"deny"` to keep listing
denied outright).
Incoming messages never need approval: protection rests on the sending side. Spawn and recovery
launch guarded sessions with `--settings '{"crossSessionInbound":"accept"}'`, because project
settings can make inbound stricter but not looser. If the project wants inbound held or refused
anyway, set `privateInbound` to `"hold"` or `"refuse"`, and `--write` checks that in too.
Until the guard lands, spawn and recovery print a warning for every worktree and write the same
settings locally, but clones elsewhere stay unguarded.

## 3. Names stay readable

Session, tmux and Remote Control names are `<prefix><branch>` (staging adds `-<host>`) in a private
project as in a public one. Projects are kept apart by scoping what an agent can reach and list,
not by hiding names: hashed names made `tmux ls` and terminal tabs unreadable to the person running
the fleet while the names stayed visible account-wide anyway. A project that still wants them can
set `"opaqueNames": true`, which names sessions, Remote Control labels, tmux and terminal titles
`p-<hash>` and makes the doorbell name nothing but the opaque sender and a file timestamp.
`<agents>/bin/session-name <branch>` prints any branch's name either way, and
`session-name --resolve <name>` maps one back to its worktree folder. Attention markers go to
`<worktrees>/.claude-attention/`, not the machine-wide `~/.cache/claude-attention/`.

Issue titles, commit messages and branch names stay inside the repo; keep them out of anything you
post elsewhere.

## 4. Doorbells are native

`bin/doorbell` rings natively (`SendMessage`), as in a public project. A ring to one of the
project's own sessions goes through without a prompt. If a send asks and the human declines it, the
agent doesn't ring tmux instead: a declined send is a decision. tmux remains the fallback for a
send that failed, was held or was refused, and for script senders. The file protocol is unchanged.

## 5. Cross-machine staging needs approval per send

If the project runs staging on more than one machine, list each one's name in `stagingPeers`:
`<agents>/bin/session-name staging` run on that machine prints it. The hook counts those as the
project's own sessions, and `isolatePeerMachines` still asks the human for each send to another
machine. The receiving staging session takes them without a prompt. If that is too slow,
coordinate across machines through another channel (for example the repository itself).

## 6. On a sensitive machine, add the machine-local layer

On a personal laptop, or any machine with data outside the project, declare it in
`hydra-agents.local.json` (gitignored) beside `hydra-agents.json`:

```json
{ "machineSensitivity": "sensitive", "sandboxBash": "true" }
```

A machine without `~/.hydra-sandbox` is treated as sensitive anyway. Spawn and recovery then add
filesystem deny rules for credential stores and personal folders, and the Bash sandbox if asked.
Every send from that machine to another machine needs a human's approval, whatever the repo, and
staging's sends too. Don't run a bypass-permissions fleet there.

## 7. Know the limits

The settings guard sessions started inside the repo; a session launched by hand elsewhere isn't
covered, and one launched by hand inside it lacks the launch-time inbound `accept`, so messages from
a session in another permission mode are held for it. An agent in bypass mode can edit its own
settings files, the guard included. The tmux fallback is a shell command, not a message the
runner gates. Claude Code documents that a hook's `ask` prompts in the default and auto modes; it
doesn't say so for bypass mode, so a bypass-permissions fleet should verify that sends outside the
project still prompt. The recipient field of `SendMessage` isn't documented either: the hook reads
`to` (or `recipient`, `target`) and asks when it finds none. It lets an in-session subagent through
by its id shape (`a` and 16 hex digits), since continuing a subagent also uses `SendMessage`.
Session names stay visible account-wide, readable or opaque. And messaging is one channel: `git push`, `gh` and web requests are others. For a machine shared with
other people's or other projects' work, a separate account is the strongest separation.
