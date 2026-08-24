import { copyFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { applyManagerConfig, loadManagerConfig, validateManagerConfig } from './config-service.mjs';

const sourceRoot = join(import.meta.dirname, '..', '..');
const testRoot = await mkdtemp(join(tmpdir(), 'asa-web-config-'));
try {
  const configDir = join(testRoot, 'server', 'ShooterGame', 'Saved', 'Config', 'WindowsServer');
  await mkdir(configDir, { recursive: true });
  await Promise.all([
    copyFile(join(sourceRoot, 'server', 'ShooterGame', 'Saved', 'Config', 'WindowsServer', 'GameUserSettings.ini'), join(configDir, 'GameUserSettings.ini')),
    copyFile(join(sourceRoot, 'server', 'ShooterGame', 'Saved', 'Config', 'WindowsServer', 'Game.ini'), join(configDir, 'Game.ini')),
    copyFile(join(sourceRoot, 'server-config.cmd'), join(testRoot, 'server-config.cmd')),
    copyFile(join(sourceRoot, 'server', 'ShooterGame', 'Saved', 'AllowedCheaterAccountIDs.txt'), join(testRoot, 'server', 'ShooterGame', 'Saved', 'AllowedCheaterAccountIDs.txt')).catch(() => {}),
  ]);
  const before = await loadManagerConfig(testRoot);
  const input = {
    rates: { ...before.rates, XPMultiplier: before.rates.XPMultiplier + 0.125 }, mods: [...before.mods],
    progression: { ...before.progression, 'PerLevelStatsMultiplier_Player[7]': before.progression['PerLevelStatsMultiplier_Player[7]'] + 0.25 },
    allowSpeedLeveling: !before.allowSpeedLeveling,
    wild: { ...before.wild, DinoCountMultiplier: Math.max(0.1, before.wild.DinoCountMultiplier - 0.05) }, levelDistribution: 'high',
    important: { serverPVE: before.important.serverPVE, allowFlyerCarryPvE: before.important.allowFlyerCarryPvE, alwaysAllowStructurePickup: before.important.alwaysAllowStructurePickup, autosaveMinutes: 17, maxTamedDinos: before.important.maxTamedDinos, noRespawnPenalty: before.important.noRespawnPenalty, simpleBedCooldown: before.important.simpleBedCooldown, modernBedCooldown: before.important.modernBedCooldown, joinPassword: { mode: 'keep', value: '' }, adminPassword: { mode: 'keep', value: '' } },
    admins: ['0123456789abcdef0123456789abcdef'],
  };
  const validated = validateManagerConfig(input);
  const result = await applyManagerConfig(testRoot, validated);
  const after = await loadManagerConfig(testRoot);
  if (after.rates.XPMultiplier !== input.rates.XPMultiplier || after.progression['PerLevelStatsMultiplier_Player[7]'] !== input.progression['PerLevelStatsMultiplier_Player[7]'] || after.allowSpeedLeveling !== input.allowSpeedLeveling || after.levelDistribution !== 'high' || after.important.autosaveMinutes !== 17 || after.admins[0] !== input.admins[0] || !result.snapshot) throw new Error('Config round trip failed.');
  let rejected = false;
  try { validateManagerConfig({ ...input, mods: ['not-numeric'] }); } catch { rejected = true; }
  if (!rejected) throw new Error('Invalid mod ID was accepted.');
  console.log('PASS: copied config read, validation, backup, apply, and reload succeeded.');
} finally {
  await rm(testRoot, { recursive: true, force: true });
}
