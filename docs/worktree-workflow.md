# Worktree workflow

Day-to-day git operations work normally inside a worktree —
`git status`, `git commit`, `git push`, `git log` all behave as expected.
This page covers the mechanics that are specific to the bare-repo + worktrees layout.

For the read/modify rules, see the project's harness guide ("Working with worktrees").
For the promotion ladder between long-lived branches (feature → staging → main),
see [branch-flow.md](branch-flow.md).
For sibling messaging, see [cross-worktree-messages.md](cross-worktree-messages.md).

## One branch per worktree

Git refuses to check out the same branch in two worktrees simultaneously.
This is a feature: it prevents two agent sessions from racing on the same branch.
If a branch is already checked out elsewhere, either work on it in that worktree
or add a new worktree for a different branch.

## Naming: branches are per-repo, tmux sessions are per-machine

Qualify each name exactly as far as its namespace reaches:

| | namespace | name |
|---|---|---|
| branch / worktree | one repo | `staging`, `feature_42_foo` |
| **tmux session / agent** | **the machine** | `<prefix>staging`, `<prefix>feature_42_foo` |

Branch and worktree names are scoped to one repository, so `staging` and
`feature_42_foo` are unambiguous there. But **tmux session names are
machine-global** — two projects (fleets) on one host would collide on `staging`
and on any shared issue number (numbering restarts per repo). The failure is
quiet: a second spawn errors, or the recovery path attaches to another project's
session and relaunches a duplicate agent.

So `spawn-issue-worktree.sh` and `recover-agents.sh` prefix the **session name**
(and every `tmux -t` target) with a per-machine `sessionPrefix` from the
project's `hydra-agents.json` — defaulting to the repo name (e.g. `myproj-`).
Window and pane **titles** stay the short branch name: by the time you are
reading those, you are already inside the project's session, and `term-style.sh`
sets them from the branch. Set `sessionPrefix` in `hydra-agents.json` only if the
repo name is awkward. (See hydra-agents#1.)

## Shared object store

Commits made in any worktree are immediately visible from every other worktree
(`git log` in worktree A will see a commit made in worktree B).
You only ever push or fetch from *one* worktree; the result is global.
This also means `git cherry-pick <sha>` from another branch's commits works
without any fetch step — useful when a sibling feature branch carries a fix
or capability you need now and waiting for its merge to staging would block progress.

## Adding a new worktree

From inside any existing worktree or from the bare repo:

```sh
# from <project>/worktrees/<existing>/
git worktree add ../<branch-name> <branch-name>

# from <project>/
git -C <project>/<project>.git worktree add worktrees/<branch-name> <branch-name>
```

## Removing a worktree

Use `git worktree remove <path>`, not `rm -rf`.
Manual removal leaves dangling metadata in `<project>.git/worktrees/`.
If you did remove one by hand, run `git worktree prune` to clean up.

## Don't edit files under `<project>.git/`

It is the shared object store and should only be modified by git commands themselves.
