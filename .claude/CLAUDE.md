# ASA_Server — Project Notes

Private ARK: Survival Ascended dedicated server, managed via a PowerShell GUI + local-AI stack.
Git repo (GitHub `gustavraff/asa-server`), branch `feature/ai-assistant` off `main`. Previously operated via OpenAI Codex CLI sessions before switching to Claude Code — README-FIRST.txt / MOD-REVIEW-QUEUE.txt in the repo are **living operational docs**, treat as current state, not history.

## Key components
- `ASA-Manager.ps1` — main GUI manager (start/stop/restart/update/backup, rates, mod management, PS5 admin, offline advisor). Owns the server's startup configuration: writes `server-config.cmd` (`Set-CmdConfigValue`) and mirrors a few values (e.g. `MaxPlayers`) into the INI for display purposes only — the INI mirror is **not** what the server reads.
- `ASA-AI-Assistant.ps1` — local Ollama engine (`qwen3:8b` @ 127.0.0.1:11434; also has `gpt-oss:20b`, `qwen2.5-coder:7b`). Dot-sources `ASA-AI-Knowledge.ps1`. Runs in **full autonomy**: model output is constrained to a strict JSON schema over fixed allow-lists (`$script:AllowedSettings` — numeric INI rate settings; `$script:AllowedActions` — `StartServer`/`SafeStop`/`Restart`/`UpdateAndRestart`/`SafeBackup` mapped 1:1 to vetted scripts) — never raw shell/file access. `-Execute` runs live; omit it to preview only. **Always test new prompts without `-Execute` first.**
  - **Current-value awareness**: the system prompt injects each setting's actual current INI value (`Get-AsaAiAllowedSettingText`) before the model reasons about relative requests ("boost further", "lower it"), so it can't misread an already-high value as needing a boost.
  - **Recipes**: the AI can also propose `ConfigOverrideItemCraftingCosts` overrides via a verified item-class alias table (`$script:AsaItemClassAliases`, cross-checked against ark.wiki.gg). Proposals carry a `Recipes` array alongside `Changes`/`Actions`.
  - **Relocation**: safe, allow-listed setting relocation (moving a setting to its correct file/section) via `Get-AsaSettingRelocationPlan`.
- `ASA-AI-Knowledge.ps1` — deterministic (non-LLM) settings knowledge base + read-only diagnostics + current-configuration/effective-value resolution. See below.
- `ASA-AI-Panel.ps1` — GUI front-end; one button runs the request immediately (no separate confirm step), shows a per-step execution log. "Ask about a setting" / "Analyze ASA configuration" buttons call into `ASA-AI-Knowledge.ps1`.
- `DailyMaintenance.ps1` — 04:00 scheduled task: safe stop → verified backup → update (Steam App 2430930) → keep 14 daily backups → restart → update/validate mods → force-respawn wild dinos.
- Manual fallback scripts: `StartServer.bat`, `StopServer.ps1`, `RestartServer.bat`, `UpdateServer.bat`, `BackupServer.bat`, `SafeBackup-And-Restart.ps1`, `Update-And-Restart.ps1`. All player-facing restarts warn at 60/30/10s via `WarnPlayers-And-Wait.ps1` (sends both RCON `Broadcast` and `ServerChat`).
- `Invoke-Rcon.ps1` — local-only RCON client (TCP 27020, not exposed).
- `Test-ASA-Manager.ps1` / `Test-ASA-Knowledge.ps1` — test suites (see Testing below).
- Config: `server\ShooterGame\Saved\Config\WindowsServer\{GameUserSettings.ini,Game.ini}`. Current map: `Aberration_WP`.
- Startup source of truth: `server-config.cmd` (`set "KEY=value"` pairs, read with a fixed regex) + `StartServer.bat` (the actual `ArkAscendedServer.exe` invocation, which substitutes those variables and adds conditional args like `-mods=`, `-AllowSpeedLeveling`). This is the **only** place startup arguments are read from — never build a second/parallel startup-config source.

## Local ASA knowledge base (`asa_claude_package/`)
Curated ARK: Survival Ascended settings library, ~459 entries across `core/leveling/spawns/loot-items-engrams/dynamic-config/content-niche/archive-blocked` JSON files, each entry carrying: target file/section, type, default, valid range/enum, support status (`supported`/`unsupported`/`unverified`/`blocked`/`obsolete`), and (where relevant) a named replacement setting. A disk cache (`asa_claude_package/.knowledge-index.cache.json`) avoids reparsing when the source files are unchanged; `Sync-AsaKnowledgeIndex -Force` rebuilds it.

**Retrieval is deterministic, never model-generated**: `Find-AsaSettingExact` (exact name), `Search-AsaSettings` (keyword). `Get-AsaAiKnowledgeAnswer` answers natural-language questions using only these lookups plus fixed precedence rules — it never invents a setting and says "unknown"/"Unable to determine from current local configuration" when the package or current config has no answer. The generative model is **never** used to decide precedence or fabricate a value.

## Diagnostics (`Invoke-AsaConfigDiagnostics`)
Read-only comparison of the live `GameUserSettings.ini`/`Game.ini` against the package. Flags: unknown, unsupported, obsolete, unverified, blocked settings; wrong file/section; invalid type/range/enum; malformed complex-tuple syntax; duplicates; dependency hints. For `OBSOLETE`/`UNSUPPORTED` findings with a known replacement, it also resolves the replacement's actual effective value (via `Resolve-AsaSingleSettingEffectiveValue`) and reports "Effective replacement: X" plus "Safe cleanup candidate: legacy entry can be removed without changing the effective value." Findings carry `EffectiveValue`/`ValueSource`/`Replacement` fields, consumed by `Format-AsaDiagnosticFindingClipboardText`/`Format-AsaDiagnosticsReportClipboardText` for the panel's copy/export UI. **Diagnostics never write anything** — cleanup of a flagged legacy entry still requires an explicit user-initiated change through the normal preview/backup/apply pipeline.

## Effective-configuration resolution
Three sources feed one deterministic answer, in fixed precedence — **the generative model never decides this**:
1. Explicit current command-line/startup argument (from `server-config.cmd` + `StartServer.bat`, via `Get-AsaCurrentCmdConfig` / `Get-AsaEffectiveStartupArguments` / `Find-AsaEffectiveStartupArgumentValue`)
2. Explicit current INI value (`GameUserSettings.ini` / `Game.ini`)
3. Documented package default
4. If none apply: state plainly that there's no configured value/default — never guess.

If a setting is unsupported/obsolete with a known replacement (e.g. `MaxPlayers` → `-WinLiveMaxPlayers`), the replacement's value is authoritative and reported as effective; the original is reported separately as an inert legacy entry. `Resolve-AsaSingleSettingEffectiveValue` / `Get-AsaEffectiveSettingAnswer` implement this and are shared by both the Q&A path and diagnostics. If startup arguments can't be read, the answer is exactly "Unable to determine from current local configuration."

**Secret redaction**: startup arguments matching `Test-AsaKeyLooksSecret` (password/token/apikey/secret/credential patterns) are never shown in full — always reuse this function rather than adding new redaction logic.

## Write pipeline (settings changes, relocations, recipes)
Every AI-driven change — rate settings, actions, recipe overrides, relocations — flows through the same pipeline and is fully separate from the read-only knowledge base (a proposal referencing a knowledge-base-only setting is rejected here, not silently allowed):
`ConvertTo-AsaValidatedProposal` (schema + allow-list validation) → `Test-AsaAiApplyProposal` (preview) → `New-AsaAiPreparedApply` (stage + `.bak` + dated snapshot under `backups\ConfigHistory`) → `Invoke-AsaAiApplyProposal` (atomic apply). Settings writes are always atomic with a `.bak` plus a dated snapshot, enabling rollback. AI/Ollama writes only ever touch the fixed allow-list, only in the two named INI files, only while the server is stopped.

## Operating rules
- Never run the full Steam ASA client on this host while the server runs (16GB RAM insufficient) — join from PS5.
- Only install cross-platform-marked mods if PS5 players need them. Vet every new mod against `MOD-REVIEW-QUEUE.txt` (Project ID, PS5 support, dependencies/load order, RAM/save-size impact) before installing, in small tested batches with a world backup first.
- Networking: UDP 7777/7778/27015 forwarded to static IP `192.168.1.179`.

## Testing this repo — hard constraints
- **Never run `ASA-AI-Assistant.ps1 ... -Execute` as a blocking foreground shell call** when it triggers `SafeBackup`/`Restart`/`UpdateAndRestart`/`StartServer` — the detached `ArkAscendedServer.exe` child can entangle with the wrapping shell call and it may never return even after the real action succeeded. If a live `-Execute` test is required: run it with `run_in_background` and verify independently via `tasklist` / `ShooterGame.log` tail / backups folder timestamp — do not force-kill the wrapper afterward (process-tree lineage with the live server is unconfirmed).
- Gustav expects proactive discovery of silently-broken features, not just fixes to what he names. A script returning "success" is not proof — trace any "player sees a message" / "file changed" claim to an actual confirmed observation, and say so explicitly if it can't be confirmed live.
- Run tests with `.\Test-ASA-Manager.ps1` (GUI manager, report at `test-results\LATEST-PASS.txt`) and `.\Test-ASA-Knowledge.ps1` (knowledge base/diagnostics/effective-value resolution — no Ollama required). Run the full suite before committing changes to shared infrastructure; a targeted script/manual smoke test is enough for narrow changes.
- Launch the AI panel: `.\ASA-AI-Panel.ps1`. Command-line: `.\ASA-AI-Assistant.ps1 -Question "..."` / `-Diagnose` / (a change request, omit `-Execute` to preview).

## Git / commit expectations
- Only commit files relevant to the current task. If `git status` shows unrelated pre-existing modifications, leave them unstaged and mention them rather than folding them into your commit.
- Prefer new commits over amending; never force-push without explicit confirmation.

## LOW-USAGE WORKFLOW for future Claude sessions
1. Read this file first.
2. Inspect `git status` and recent `git log` before doing anything else.
3. Do not scan the entire repository unless the task genuinely requires it.
4. Identify the smallest set of task-relevant files first (usually one of: `ASA-Manager.ps1`, `ASA-AI-Assistant.ps1`, `ASA-AI-Knowledge.ps1`, `ASA-AI-Panel.ps1`, plus its matching test file).
5. Reuse existing helpers/architecture (see above) instead of building a parallel implementation — especially the startup-config reader, the effective-value resolver, and the secret-redaction function.
6. Read only the `asa_claude_package/` dataset file(s) relevant to the task, not the whole package.
7. Prefer deterministic logic over generative/model reasoning for anything correctness-critical (this is the established pattern throughout the project).
8. Do not spawn subagents unless the task genuinely requires parallel independent work.
9. Prefer targeted tests during implementation; save full-suite runs for before commit.
10. Run the full test suite before committing when the change affects shared infrastructure.
11. Commit completed work (only the files relevant to the task — see Git expectations above).
12. When switching to a substantially different task, prefer a fresh Claude Code session instead of carrying a large conversation context.
13. Use `/compact` during a long single task if context becomes large.
14. If the task changes substantially, the session has already been compacted, or work passes roughly 25 tool calls, create `AI-THREAD-HANDOFF.md` with `AI-Usage-Audit.ps1 -CreateHandoff -CurrentTask "..." -NextStep "..."` before another large phase. Then stop and ask Gustav to begin a fresh session. Use `/compact` only to finish the same coherent task; use a fresh session for a new task.

## USAGE AUDIT AND OVERUSE CONTROL
- `AI-Usage-Audit.ps1 -ShowWindow` records a local post-task audit. The user may enter official before/after credit values; never estimate an exact credit charge and present it as measured.
- Before a substantial task, provide a LOW/MEDIUM/HIGH preflight usage-risk estimate based on the planned files, tool calls, scans, research, and tests. `AI-Usage-Audit.ps1 -Preflight` provides the shared deterministic rating. If risk is HIGH, reduce the plan or ask Gustav before proceeding. This is a relative warning, never an exact credit prediction.
- Model routing: LOW tasks use a small/fast model such as Haiku when available; MEDIUM tasks use Sonnet; HIGH tasks start with Sonnet and escalate to Opus only when complexity, failed attempts, or live-system risk justifies it. Choose before starting rather than switching repeatedly mid-task.
- Keep the official `session-report` plugin enabled for periodic evidence-based optimization. Keep `claude-code-setup` installed but normally disabled after setup, avoiding its always-on prompt overhead.
- The audit is local efficiency evidence, not OpenAI/Anthropic billing data. It cannot refund, restore, or reimburse credits.
- Reuse already verified evidence unless a new change could invalidate it. Do not rerun map changes, full scans, server restarts, or full test suites merely to prove unrelated functionality again.
- For narrow changes, test the changed feature and its directly affected paths. For shared infrastructure, run the full suite once before commit.
- If a task uses more than 25 tool calls, repeats the same scan/test/action more than once, performs a full repository scan, or runs the full suite more than once, explicitly review whether that work was necessary and state a concrete optimization in the final handoff.
- For a substantial task, offer to record the audit after completion. Official before/after usage values must come from the user's Usage Dashboard.
