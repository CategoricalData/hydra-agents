# Hydra Agents

An opinionated, versioned harness for running fleets of AI coding agents against a project —
roles and a promotion ladder, a cross-worktree messaging protocol, spawn/attention/recovery
tooling, hooks, and session procedures. Extracted from the [Hydra](https://github.com/CategoricalData/hydra)
repository (see hydra#583), which is its first consuming project.

**Status:** early extraction. Today the repo holds the previously "homeless" machine-level pieces
(`bin/`) that used to live loose in `$HOME`; the generic docs, hooks, commands, config contract,
and installer are still to come.

## Layout

- `bin/` — harness tooling and machine-level scripts (`claude-remote`, `recover-agents.sh`,
  `term-style.sh`, and the `watchdog/` suite). Flat for now; a per-project vs per-machine split
  will come with the installer.

## License

Apache-2.0. See [LICENSE](LICENSE).
