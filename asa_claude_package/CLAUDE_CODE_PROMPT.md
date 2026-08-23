You are implementing the curated ARK: Survival Ascended server-settings library in this existing ASA Server Manager repository.

IMPORTANT: Do implementation, not just a plan. Do not scan the entire repository repeatedly. First locate the existing config parser/writer, AI proposal code, preview/apply flow, and tests. Reuse the current architecture; do not restructure unrelated code.

The attached `asa_claude_package` directory is the source of truth for the settings library.

IMPLEMENTATION REQUIREMENTS
1. Load `asa-core-settings.json` by default.
2. Load specialized files only when the user's request requires them:
   - leveling -> `asa-leveling-settings.json`
   - creature spawns/classes -> `asa-spawn-settings.json`
   - loot/items/engrams -> `asa-loot-items-engrams-settings.json`
   - explicit live/dynamic config -> `asa-dynamic-config-settings.json`
   - niche/map/content-specific -> `asa-content-niche-settings.json`
3. `asa-archive-blocked-settings.json` is validation/migration reference only. Never let the AI automatically propose or apply entries from it.
4. Unique setting identity is `name + target + section`, not name alone.
5. Reject unknown, unsupported, obsolete and unverified settings for automatic apply.
6. Validate exact target, section, value type, min/max/allowed values and complex syntax.
7. Never let free-form AI text write directly to GameUserSettings.ini, Game.ini or launch arguments.
8. Required flow: structured proposal -> validation -> preview/diff -> backup -> safe write -> post-write validation -> rollback on failure.
9. Never log secret values.
10. Preserve unrelated existing config content.
11. Add focused tests for core lookup, lazy loading, blocked settings, wrong section, invalid type/range, complex syntax, duplicate names across different targets, secret redaction, and rollback safety.

Before changing code, inspect only the files needed for this flow. After implementation, report only:
- files changed
- tests added/run and result
- count of settings loaded per library
- any conflicts or assumptions that could not be resolved from the supplied package
