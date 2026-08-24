# Security Policy

This repository operates a private ARK: Survival Ascended dedicated server. See
`.claude/CLAUDE.md` for the full architecture, safety rules, and write-pipeline
(Preview → Confirm → Backup → Apply) that all configuration changes must go
through.

## Reporting a vulnerability

Please report security issues privately via
[GitHub Security Advisories](https://github.com/gustavraff/asa-server/security/advisories/new)
rather than opening a public issue. Include:

- What component is affected (manager scripts, AI assistant, web manager, etc.)
- Reproduction steps
- Potential impact (e.g. could it affect the live server, expose credentials,
  or allow unintended configuration writes)

## Scope notes specific to this project

- Startup configuration (`server-config.cmd` / `StartServer.bat`) and INI
  writes are the sensitive surface — see `.claude/CLAUDE.md` for the
  allow-listed settings/actions and the atomic backup-and-apply pipeline.
- Secrets (RCON credentials, dashboard auth, tokens) must never be committed.
  `Test-AsaKeyLooksSecret` in the codebase is the shared redaction check —
  reuse it rather than adding new ad-hoc redaction logic.
- The AI assistant (`ASA-AI-Assistant.ps1`) only ever touches a fixed
  allow-list of settings/actions and never gets raw shell or file access.
- CI workflows in `.github/workflows/` must never run live-server actions
  (`-Execute` on `ASA-AI-Assistant.ps1`, server start/stop/update) or read
  live save/config directories — only checked-in fixtures and the
  `asa_claude_package/` dataset.
