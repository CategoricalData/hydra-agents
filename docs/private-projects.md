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

**What it contains (Claude Code):** `permissions.ask: ["SendMessage"]`, so every outgoing message
needs a human's approval, even to a session on the same machine (another private repo's
included); `isolatePeerMachines: true`; and a `ListAgents` deny. Bypass mode honors the `ask` rule,
and a "don't ask again" answer at the prompt doesn't override it, so the guard doesn't disable
bypass mode (the trade-off is in
[Project isolation § With Claude Code](cross-worktree-messages.md#with-claude-code)).
Incoming messages never need approval: protection rests on the sending side. Spawn and recovery
launch guarded sessions with `--settings '{"crossSessionInbound":"accept"}'`, because project
settings can make inbound stricter but not looser. If the project wants inbound held or refused
anyway, set `privateInbound` to `"hold"` or `"refuse"`, and `--write` checks that in too.
Until the guard lands, spawn and recovery print a warning for every worktree and guard each one
with local settings, but clones elsewhere stay unguarded. A guard written before this change
carries `crossSessionInbound: "hold"` and no `ask` rule: rerun `project-guard --write` and commit.

## 3. Expect opaque names everywhere outside the project

The project's name, branch names and issue titles are confidential: the harness never emits them
outside the project's own worktrees. So sessions are named `p-<hash>` instead of
`<prefix><branch>`, and so are Remote Control labels, tmux session, window and pane titles,
terminal titles (`claude-remote`, `term-style.sh`), and doorbells. The names are deterministic:
`<agents>/bin/session-name <branch>` prints any branch's name, `session-name --resolve <name>`
maps one back, and spawn, recovery and `bin/doorbell` compute them the same way. Attention
markers go to `<worktrees>/.claude-attention/`, not the machine-wide `~/.cache/claude-attention/`.
Inside the worktrees (branches, plan docs, inbox filenames) real names are fine.

Write issue titles, commit messages and branch names knowing that they stay inside the repo,
and keep them out of anything you post elsewhere.

## 4. Doorbells are native, and each one asks

With inbound accepted, `bin/doorbell` rings natively (`SendMessage`), as in a public project, and
each ring is a send that prompts the human. If the human declines it, the agent doesn't ring tmux
instead: a declined send is a decision. tmux remains the fallback for a send that failed, was held
or was refused, and for script senders. The doorbell names the sender by its opaque name and the
file by its timestamp only: `From p-<hash>: new message <timestamp>* in your inbox`. The file
protocol is unchanged.

## 5. Cross-machine staging needs approval per send

If the project runs staging on more than one machine, list each one's name in `stagingPeers`:
`<agents>/bin/session-name staging` run on that machine prints it. Those sends are allowed (same
project), but each one needs a human's approval, like every send from a private repo. The
receiving staging session takes them without a prompt. If that is too slow, coordinate across
machines through another channel (for example the repository itself).

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
runner gates. Session names stay visible account-wide; opaque names only make them say less. And
messaging is one channel: `git push`, `gh` and web requests are others. For a machine shared with
other people's or other projects' work, a separate account is the strongest separation.
