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
  ]);
  const before = await loadManagerConfig(testRoot);
  const input = { rates: { ...before.rates, XPMultiplier: before.rates.XPMultiplier + 0.125 }, mods: [...before.mods] };
  const validated = validateManagerConfig(input);
  const result = await applyManagerConfig(testRoot, validated);
  const after = await loadManagerConfig(testRoot);
  if (after.rates.XPMultiplier !== input.rates.XPMultiplier || !result.snapshot) throw new Error('Config round trip failed.');
  let rejected = false;
  try { validateManagerConfig({ ...input, mods: ['not-numeric'] }); } catch { rejected = true; }
  if (!rejected) throw new Error('Invalid mod ID was accepted.');
  console.log('PASS: copied config read, validation, backup, apply, and reload succeeded.');
} finally {
  await rm(testRoot, { recursive: true, force: true });
}
