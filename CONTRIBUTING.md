# Contributing

This is a personal/private project, but the same workflow applies whether
changes come from Gustav, Claude Code, Codex, or a future collaborator.

## Before you start

Read `.claude/CLAUDE.md` (architecture, safety rules, testing, LOW-USAGE
WORKFLOW) and `AGENTS.md` first — they're the source of truth, not duplicated
here.

## Workflow

1. Branch from `main` (or the current working branch — check `git status` and
   recent commits first; don't assume `main` is up to date locally).
2. Make the smallest coherent change that fully solves the task. No drive-by
   refactors of unrelated code.
3. Run targeted tests for the area you changed:
   - `.\Test-ASA-Manager.ps1` for GUI manager changes
   - `.\Test-ASA-Knowledge.ps1` for knowledge-base/diagnostics changes
   - `npm run lint && npm run build` in `web-manager/` for web manager changes
   - Run the full suite once before committing changes to shared
     infrastructure.
4. Never test `ASA-AI-Assistant.ps1 ... -Execute` as a blocking foreground
   call when it would trigger a live action (`SafeBackup`/`Restart`/
   `UpdateAndRestart`/`StartServer`). See `.claude/CLAUDE.md` for the safe way
   to test this.
5. Open a pull request using the provided template. Fill in live-system
   impact, tests performed, and rollback plan honestly — these gate review.

## Rollback

- Configuration writes always go through Preview → Confirm → Backup → Apply
  and produce a `.bak` plus a dated snapshot under `backups\ConfigHistory` —
  restore from there if an applied change needs to be undone.
- A bad commit to `main` (workflow, template, or code) can be reverted with a
  normal `git revert` — avoid `git reset --hard` on shared branches.
- CI workflows are read-only/validation-only and never modify the live server,
  so a bad workflow run has no live-system blast radius — just fix and re-run.

## What CI will and won't catch

- PSScriptAnalyzer and the knowledge-base tests run automatically on relevant
  paths. They do not replace a live-server smoke test for GUI/manager changes
  — those still need a manual run per `.claude/CLAUDE.md`.
- The web manager's lint/build run automatically; there is currently no
  automated test suite for it.
