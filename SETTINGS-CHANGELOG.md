# ASA Settings Changelog

Every settings change made through the AI assistant is logged here automatically
(newest entries appended at the bottom by `Add-AsaChangelogEntry` in
`ASA-AI-Assistant.ps1`). Manual mod-list/config changes made outside the AI
engine are logged here by hand at the same time they happen.

Each entry names the exact setting, old value, new value, the reason, and
(when applicable) the timestamped backup folder under `backups\AI-Config` or
`backups\ConfigHistory` that holds the pre-change file — use that folder to
restore the previous value if a change turns out to be wrong.

---

- **2026-08-21 21:37:28** &mdash; `DayTimeSpeedScale` in GameUserSettings.ini: `0.4` -> `0.9`. Reason: User requested longer days (live test of the AI engine's full-autonomy apply path). Backup: `backups\AI-Config\2026-08-21_21-37-28-456_5476a6d3`
- **2026-08-21 ~21:55** &mdash; `MODS` in server-config.cmd: removed `940975` (Cybers Structures QoL+). Reason: Suspected cause of repeated client crashes (log showed its periodic "Full Purge Garbage Collection" cycles correlating with structures being destroyed and players reconnecting). Manual edit, no snapshot taken at the time (gap now fixed going forward).
- **2026-08-21 ~22:00** &mdash; `MODS` in server-config.cmd: re-added `940975` (Cybers Structures QoL+). Reason: Deliberate A/B test at Gustav's request, to confirm whether it was really the cause before permanently dropping it. Result: crashes reduced substantially but not to zero, suggesting it was a real contributor but possibly not the only one.
- **2026-08-22 01:28:31** &mdash; Balance pass, 8 settings changed together (backup: `backups\AI-Config\2026-08-22_01-28-31-948_0ce61b05`):
  - `OverrideOfficialDifficulty` in GameUserSettings.ini: `5.0` -> `3.0`. Reason: max wild dino level was 150 (official-server max); too many/too tanky high-level dinos.
  - `SupplyCrateLootQualityMultiplier` in GameUserSettings.ini: `1.5` -> `2.0`. Reason: better supply crate loot quality (no native setting exists for crate spawn frequency).
  - `AutoSavePeriodMinutes` in GameUserSettings.ini: `15` -> `10`. Reason: more frequent autosave for extra crash protection.
  - `PerLevelStatsMultiplier_DinoWild[0]` (wild dino health per level) in Game.ini: unset (vanilla `1.0`) -> `0.6`. Reason: wild dinos were gaining health at vanilla rate all the way to level 150.
  - `PerLevelStatsMultiplier_DinoWild[8]` (wild dino melee damage per level) in Game.ini: unset (vanilla `1.0`) -> `0.6`. Reason: same as above, for damage output.
  - `PerLevelStatsMultiplier_Player[8]` (player melee damage per level) in Game.ini: `1.25` -> `1.6`. Reason: leveling up felt weak for combat compared to other stats.
  - `PerLevelStatsMultiplier_Player[9]` (player movement speed per level) in Game.ini: `1.0` -> `1.2`. Reason: same as above.
  - `PerLevelStatsMultiplier_Player[11]` (player crafting-speed stat per level) in Game.ini: `1.5` -> `2.0`. Reason: crafting felt slow; caveat, this only helps players who invest points in Crafting Speed, not raw station speed.
- **2026-08-22 01:38:01** &mdash; `DinoCharacterHealthRecoveryMultiplier` in GameUserSettings.ini: `(not previously set)` -> `4.0`. Reason: User asked for tamed dinos to regen health faster; this is the only working global regen lever, affects wild dinos too. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-38-01-533_a1520aa1`
- **2026-08-22 01:42:49** &mdash; `PerLevelStatsMultiplier_DinoTamed[0]` in Game.ini: `0.23` -> `1.0`. Reason: Tamed health per level was 0.23, weaker than wild dinos at 0.6 despite the effort of taming/leveling; raised to be clearly ahead. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-42-49-252_dd43e330`
- **2026-08-22 01:42:49** &mdash; `PerLevelStatsMultiplier_DinoTamed[8]` in Game.ini: `0.1955` -> `1.0`. Reason: Tamed melee per level was 0.1955, weaker than wild dinos at 0.6; raised to be clearly ahead. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-42-49-252_dd43e330`
- **2026-08-22 01:53:25** &mdash; `DinoCountMultiplier` in GameUserSettings.ini: `(not previously set)` -> `0.7`. Reason: Main complaint was too many dinos clustering at one spot; reducing overall map density. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-53-25-195_74554db7`
- **2026-08-22 01:53:25** &mdash; `WantsEqualLevels` in GameUserSettings.ini: `True` -> `False`. Reason: Custom Dino Levels mod was spawning every level with equal chance (flat distribution), which is why high levels were as common as low ones. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-53-25-195_74554db7`
- **2026-08-22 01:53:25** &mdash; `WantsHighLevels` in GameUserSettings.ini: `False` -> `True`. Reason: User wants the distribution to lean toward high-level dinos specifically, not flat/equal. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-53-25-195_74554db7`
- **2026-08-22 01:53:25** &mdash; `OverrideOfficialDifficulty` in GameUserSettings.ini: `3.0` -> `4.0`. Reason: User wants to still lean toward genuinely high-level dinos; raised back up from the temporary 3.0 since tankiness is now handled separately via PerLevelStatsMultiplier_DinoWild. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-53-25-195_74554db7`
- **2026-08-22 01:54:35** &mdash; `PlayerCharacterWaterDrainMultiplier` in GameUserSettings.ini: `0.5` -> `0.35`. Reason: User asked to lower water consumption 30% more; 0.5 x 0.7 = 0.35. Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_01-54-35-554_a9943f2b`
- **2026-08-22 ~01:56** &mdash; Action: `DestroyWildDinos` run via RCON (not a config change, no backup needed). Reason: apply the new wild dino density/level-distribution settings (DinoCountMultiplier, WantsEqualLevels/WantsHighLevels, OverrideOfficialDifficulty) to dinos already spawned in the world, which otherwise keep their old stats until they naturally despawn. Result: "All Wild Dinos Destroyed" — they will respawn fresh under the new settings.
- **2026-08-22 02:16:34** &mdash; `OverrideOfficialDifficulty` in GameUserSettings.ini: `4.0` -> `5.0`. Reason: User wants max wild dino level back at 150 (official max); tankiness is handled separately via PerLevelStatsMultiplier_DinoWild, and level distribution is skewed toward high end via WantsHighLevels, so raising the ceiling back to 5.0 no longer means "too many, too tanky." Backup: `C:\Users\Gustav\Documents\Codex\ASA_Server\backups\AI-Config\2026-08-22_02-16-34-212_86450bda`
- **2026-08-22 ~02:18** &mdash; Action: `DestroyWildDinos` run via RCON (not a config change, no backup needed). Reason: apply the restored 150-level cap to dinos already spawned in the world. Result: "All Wild Dinos Destroyed" — new spawns should now land on multiples of 5 (5, 10, 15, ... 150), skewed toward the high end.
