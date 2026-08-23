# ASA Server Settings — Claude Code Package

This package is a curated settings library for an **ARK: Survival Ascended Windows Dedicated Server**. It was built from the supplied `Server_configuration.txt` source and the DeepSeek extraction, with the missing DynamicConfig batch merged back in.

## Load policy

- `asa-core-settings.json` — default settings context for normal server changes.
- `asa-leveling-settings.json` — load only for player/tame levels and stat-per-level changes.
- `asa-spawn-settings.json` — load only for spawn/class replacement and per-creature overrides.
- `asa-loot-items-engrams-settings.json` — load only for loot crates, items, crafting and engrams.
- `asa-dynamic-config-settings.json` — load only when live DynamicConfig changes are explicitly requested.
- `asa-content-niche-settings.json` — valid but niche/map/content-specific settings; do not load by default.
- `asa-archive-blocked-settings.json` — obsolete, unsupported, unverified, legacy/platform-specific or intentionally blocked settings. Never auto-apply these.

## Required validator behavior

1. Identify settings by `name + target + section`; never deduplicate by name alone.
2. Reject unknown settings.
3. Reject automatic apply for `unsupported`, `obsolete`, and `unverified`.
4. Require exact target file/section and validate type/range/allowed values/syntax.
5. Complex tuple/array settings must be validated structurally; do not flatten them.
6. Never write AI free-form output directly to INI files. Use proposal -> validation -> preview/diff -> backup -> write -> post-write validation.
7. Never log secret values (`ServerAdminPassword`, `ServerPassword`, `SpectatorPassword`).
8. Preserve current valid config lines that are outside the curated active context unless explicitly changed.

## Important curation choice

The package intentionally does **not** try to make every wiki option part of normal AI context. Niche content is on-demand, and risky/obsolete/unverified material is isolated. This reduces context size and prevents the assistant from choosing unusual settings when a simple core setting is sufficient.

## Counts

- core: 147
- leveling: 10
- spawns: 14
- loot_items_engrams: 9
- dynamic_config: 37
- content_niche: 219
- archive_blocked: 23
