import { copyFile, mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { randomBytes } from 'node:crypto';

export const rateDefinitions = Object.freeze([
  ['XPMultiplier','Experience',0.1,100,'Higher gives players and tames more XP.','gus'],
  ['HarvestAmountMultiplier','Harvest amount',0.1,100,'Higher gives more resources per hit.','gus'],
  ['TamingSpeedMultiplier','Taming speed',0.1,100,'Higher makes active and knockout taming faster.','gus'],
  ['PassiveTameIntervalMultiplier','Passive feed interval',0.05,10,'Lower shortens the wait between passive feeds.','gus'],
  ['PlayerResistanceMultiplier','Damage players receive',0.1,5,'Lower reduces incoming damage.','gus'],
  ['ResourcesRespawnPeriodMultiplier','Resource respawn',0.1,10,'Lower respawns resources sooner.','gus'],
  ['PlayerCharacterFoodDrainMultiplier','Food drain',0.1,10,'Lower means hunger drains more slowly.','gus'],
  ['PlayerCharacterWaterDrainMultiplier','Water drain',0.1,10,'Lower means thirst drains more slowly.','gus'],
  ['MatingIntervalMultiplier','Mating cooldown',0.01,10,'Lower lets creatures mate again sooner.','game'],
  ['MatingSpeedMultiplier','Mating progress',0.1,100,'Higher fills the mating bar faster.','game'],
  ['EggHatchSpeedMultiplier','Egg hatch speed',0.1,100,'Higher makes fertilized eggs hatch faster.','game'],
  ['BabyMatureSpeedMultiplier','Baby maturation',0.1,100,'Higher makes babies mature faster.','game'],
  ['BabyCuddleIntervalMultiplier','Imprint interval',0.01,10,'Lower requests imprint care sooner.','game'],
  ['BabyImprintAmountMultiplier','Imprint per care',0.1,100,'Higher gives more imprint progress per care.','game'],
  ['CropGrowthSpeedMultiplier','Crop growth',0.1,100,'Higher makes crops grow faster.','game'],
  ['StructureResistanceMultiplier','Structure toughness',0.05,5,'Lower makes structures take less damage.','gus'],
  ['DinoCharacterFoodDrainMultiplier','Dino food drain',0.1,10,'Lower means dinos get hungry more slowly.','gus'],
  ['DinoCharacterStaminaDrainMultiplier','Dino stamina drain',0.1,10,'Lower means dinos tire more slowly.','gus'],
].map(([key,label,min,max,help,file]) => ({ key,label,min,max,help,file,section:file === 'game' ? '[/Script/ShooterGame.ShooterGameMode]' : '[ServerSettings]' })));

const clean = (text) => text.replace(/^\uFEFF/, '');
const numberText = (value) => Number(value).toFixed(4).replace(/0+$/,'').replace(/\.$/,'');

function iniValue(text, section, key, fallback = 1) {
  let active = false;
  for (const raw of clean(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (/^\[.*\]$/.test(line)) active = line.toLowerCase() === section.toLowerCase();
    else if (active && line.toLowerCase().startsWith(`${key.toLowerCase()}=`)) return Number(line.slice(line.indexOf('=') + 1)) || fallback;
  }
  return fallback;
}

function setIniValue(text, section, key, value) {
  const lines = clean(text).split(/\r?\n/);
  let sectionIndex = lines.findIndex((line) => line.trim().toLowerCase() === section.toLowerCase());
  if (sectionIndex < 0) { if (lines.at(-1)?.trim()) lines.push(''); lines.push(section); sectionIndex = lines.length - 1; }
  let end = lines.length;
  for (let index = sectionIndex + 1; index < lines.length; index++) if (/^\s*\[.*\]\s*$/.test(lines[index])) { end = index; break; }
  const keyIndex = lines.slice(sectionIndex + 1, end).findIndex((line) => line.trim().toLowerCase().startsWith(`${key.toLowerCase()}=`));
  if (keyIndex >= 0) lines[sectionIndex + 1 + keyIndex] = `${key}=${numberText(value)}`; else lines.splice(end, 0, `${key}=${numberText(value)}`);
  return lines.join('\r\n');
}

async function atomicWrite(path, content) {
  const temp = `${path}.web-${randomBytes(5).toString('hex')}.tmp`;
  await writeFile(temp, content, 'utf8');
  await rename(temp, path);
}

export async function loadManagerConfig(projectRoot) {
  const gusPath = join(projectRoot,'server','ShooterGame','Saved','Config','WindowsServer','GameUserSettings.ini');
  const gamePath = join(projectRoot,'server','ShooterGame','Saved','Config','WindowsServer','Game.ini');
  const cmdPath = join(projectRoot,'server-config.cmd');
  const [gus, game, cmd] = await Promise.all([readFile(gusPath,'utf8'),readFile(gamePath,'utf8'),readFile(cmdPath,'utf8')]);
  const rates = Object.fromEntries(rateDefinitions.map((definition) => [definition.key, iniValue(definition.file === 'game' ? game : gus, definition.section, definition.key)]));
  const match = clean(cmd).match(/^set\s+"MODS=([^"]*)"/im);
  const mods = (match?.[1] || '').split(',').map((id) => id.trim()).filter(Boolean);
  return { rates, rateDefinitions, mods };
}

export function validateManagerConfig(input) {
  if (!input || typeof input !== 'object') throw new Error('Configuration payload is missing.');
  const rates = {};
  for (const definition of rateDefinitions) {
    const value = Number(input.rates?.[definition.key]);
    if (!Number.isFinite(value) || value < definition.min || value > definition.max) throw new Error(`${definition.label} must be between ${definition.min} and ${definition.max}.`);
    rates[definition.key] = value;
  }
  if (!Array.isArray(input.mods) || input.mods.length > 100) throw new Error('The mod list is invalid.');
  const mods = input.mods.map((id) => String(id).trim());
  if (mods.some((id) => !/^\d+$/.test(id))) throw new Error('Mods must use numeric CurseForge project IDs.');
  if (new Set(mods).size !== mods.length) throw new Error('The mod list contains duplicates.');
  return { rates, mods };
}

export async function applyManagerConfig(projectRoot, validated) {
  const gusPath = join(projectRoot,'server','ShooterGame','Saved','Config','WindowsServer','GameUserSettings.ini');
  const gamePath = join(projectRoot,'server','ShooterGame','Saved','Config','WindowsServer','Game.ini');
  const cmdPath = join(projectRoot,'server-config.cmd');
  const stamp = new Date().toISOString().replace(/[:.]/g,'-');
  const snapshot = join(projectRoot,'backups','ConfigHistory',`web-manager-${stamp}`);
  await mkdir(snapshot,{recursive:true});
  await Promise.all([gusPath,gamePath,cmdPath].map((path) => copyFile(path,join(snapshot,basename(path)))));
  let [gus,game,cmd] = await Promise.all([readFile(gusPath,'utf8'),readFile(gamePath,'utf8'),readFile(cmdPath,'utf8')]);
  for (const definition of rateDefinitions) {
    if (definition.file === 'game') game = setIniValue(game,definition.section,definition.key,validated.rates[definition.key]);
    else gus = setIniValue(gus,definition.section,definition.key,validated.rates[definition.key]);
  }
  const modLine = `set "MODS=${validated.mods.join(',')}"`;
  cmd = clean(cmd).replace(/^set\s+"MODS=[^"]*"/im,modLine);
  await atomicWrite(gusPath,gus); await atomicWrite(gamePath,game); await atomicWrite(cmdPath,cmd);
  return { snapshot, restartRequired:true };
}
