# Codex instructions for this ASA server project

Read `.claude/CLAUDE.md` first. Its architecture, safety, testing, and LOW-USAGE WORKFLOW rules apply to Codex too.

## Usage-audit rules

- Never claim access to the user's official Codex/Claude credit balance unless the product explicitly provides it in the current session.
- A local activity audit is not billing data and cannot issue refunds or restore credits.
- Before a potentially expensive task, identify the smallest relevant files and prefer combined targeted searches.
- Before a substantial task, provide a LOW/MEDIUM/HIGH preflight usage-risk estimate based on expected scope. `AI-Usage-Audit.ps1 -Preflight` can calculate the same deterministic local rating. Never present a guessed credit number as exact. If risk is HIGH, reduce scope or ask the user before continuing.
- Match model strength to risk when the product permits model selection: LOW uses a lightweight tier and low reasoning, MEDIUM uses the balanced default, and HIGH may use a frontier model only when complexity or risk justifies it. Never spawn a stronger-model subagent merely to avoid making a scoped decision locally.
- Codex cannot silently replace the current root model mid-thread. Present the recommendation to Gustav when a new thread/model choice would materially save usage.
- Reuse prior verified results unless the new change could invalidate them.
- Run targeted tests for narrow changes. Run the full suite once before committing shared-infrastructure changes, not repeatedly during every iteration.
- If a task shows likely overuse (repeated scans/actions, unnecessary full-suite runs, or more than 25 tool calls), acknowledge it in the handoff and state one concrete optimization for next time.
- For a substantial task, offer to record a local entry through `AI-Usage-Audit.ps1 -ShowWindow`. The user supplies official before/after credit values; never estimate them as measured usage.
- These rules optimize future work. They do not constitute or promise monetary reimbursement.
