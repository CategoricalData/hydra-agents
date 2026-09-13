# Hydra Agents — documentation index

The [top-level README](../README.md) is the harness guide (conventions, session
procedures, worktree rules, the core model, hard rules). These `docs/` pages are
the deep-dive references it links into. Read the README first; come here for the
mechanics of a specific area.

The docs read as **project-agnostic** and **agent-runner-agnostic**: worked
examples cite the Hydra project (the reference consumer) as illustrations, and
genuinely Claude-Code-specific mechanisms are labelled where they appear.

## The model and the roles

- **[agent-hierarchy.md](agent-hierarchy.md)** — the organizing model. How the
  agent tree mirrors the GitHub issue tree, the two agent kinds (issue vs.
  staging) and the coordinator *responsibility*, the two homes for all work, the
  new-issue proposal lifecycle, the design-decision channel, model selection by
  role, capability-tiered mentoring, context minimization, the autonomy dial,
  provenance/completion ownership, and cross-machine staging coordination. **Start
  here** for the "why" behind everything else.
- **[coordinator-workflow.md](coordinator-workflow.md)** — the mechanics an issue
  agent uses when it coordinates children: spawn → review → rebase/squash/verify →
  pause → (reopen) → finalize, plus context-hygiene resets, fleet reconciliation
  (including cooperative cross-coordinator reconciliation), and the green-by-
  ancestry finalize check.
- **[agent-handoff.md](agent-handoff.md)** — the same lifecycle from the *assigned
  agent's* side: your assignment, the plan-doc as cold-resume brief, communicating
  up without blocking, discovered-work-becomes-a-proposal, review push-back, and
  what to do if you lose trust in your coordinator.

## Promotion and staging

- **[branch-flow.md](branch-flow.md)** — the feature → staging → main promotion
  ladder, where conflict resolution happens, the staging cycle (pull → validate →
  push → monitor-CI), the pipelined cadence, proactive fleet-sweeping, machine
  utilization on designated build boxes, handling pulled `WIP:` commits, and
  staging's top-level non-issue duties. The project's **validation pipeline** is
  configured here.

## Messaging and coordination

- **[cross-worktree-messages.md](cross-worktree-messages.md)** — the transport
  every workflow rides on: the `claude-hydra-messages/` inbox/outbox layout, the
  proposal and decision queues, filename format, the copy-verify-archive send
  discipline, tmux-ping mechanics, receiving, and the polling cadence.

## Machine operations

- **[external-alerts.md](external-alerts.md)** — how a staging agent handles
  signals from *non-agent* processes on its machine: resource/health watchdog
  alerts, fleet back-pressure, liveness heartbeats (where the signal is an
  *absence*), the ceased-heartbeat escalation ladder, and the disk-cache reclaim
  policy.
- **[crash-recovery.md](crash-recovery.md)** — the staging agent's playbook for
  bringing the fleet back after a machine freeze: what committed work survives,
  which sessions to restart vs. leave paused, relaunch mechanics, the one-time
  recovery brief, and repairing corrupted worktree wiring.
- **[sandbox-permissions.md](sandbox-permissions.md)** — the machine-marker model
  for permission bypass: why a fleet must not stall on prompts, how a machine opts
  in as a disposable sandbox, and the two enforcement points. (The bypass
  mechanism itself is Claude-Code-specific; the principle is not.)

## Foundations and traps

- **[worktree-workflow.md](worktree-workflow.md)** — the bare-repo + worktrees
  git mechanics: one branch per worktree, the shared object store, adding/removing
  worktrees, and what not to touch.
- **[pitfalls.md](pitfalls.md)** — framework-level operational gotchas that bite
  any agent fleet: verifying "pre-existing"/state claims, process-ownership and
  build-slot contention, tmux/session-dynamics traps, shell-tool mechanics, and
  coordination-hygiene failure modes. (Project-specific build/codegen pitfalls
  live in the consuming project's own docs.)
