'use client';

import { useEffect, useMemo, useState } from 'react';

type StatusPayload = {
  timestamp: string;
  readOnly: boolean;
  server: { running: boolean; pid: number | null; privateMemoryGb: number; name: string; map: string; mapId: string; maxPlayers: number | null; modCount: number };
  host: { cpuPercent: number; memoryPercent: number; memoryUsedGb: number; memoryTotalGb: number; diskFreeGb: number };
  backup: { found: boolean; timestamp: string | null; name: string | null };
};

type ActionId = 'start' | 'stop' | 'restart' | 'backup' | 'update' | 'save' | 'dinowipe';
type ActionJob = { id?: string; action?: ActionId; label?: string; state: 'idle' | 'running' | 'success' | 'failed'; startedAt?: string; finishedAt?: string | null; message?: string };
type RateDefinition = { key:string; label:string; min:number; max:number; help:string };
type ManagerConfig = { rates:Record<string,number>; rateDefinitions:RateDefinition[]; mods:string[] };
type ConfigPreview = { token:string; changedRates:{key:string;from:number;to:number}[]; modsChanged:boolean; fromMods:string[]; toMods:string[] };

const actions: { id: ActionId; icon: string; label: string; detail: string; warning: string }[] = [
  { id: 'start', icon: '▶', label: 'Start server', detail: 'Original startup script', warning: 'Start the ASA server now?' },
  { id: 'stop', icon: '■', label: 'Safe stop', detail: 'Save + graceful shutdown', warning: 'Safely save and stop the server? Everyone online will disconnect.' },
  { id: 'restart', icon: '↻', label: 'Restart', detail: 'Player warning first', warning: 'Warn players, save, stop, and restart the server?' },
  { id: 'backup', icon: '⬡', label: 'Backup + restart', detail: 'Verified save snapshot', warning: 'Warn players, save, create a full backup, and restart?' },
  { id: 'update', icon: '⇧', label: 'Update + restart', detail: 'ASA App 2430930', warning: 'Warn players, update and validate ASA, then restart? This can take several minutes.' },
  { id: 'save', icon: '✓', label: 'Save world', detail: 'Local RCON command', warning: 'Save the current world immediately?' },
  { id: 'dinowipe', icon: '◇', label: 'Reset wild dinos', detail: 'Tamed dinos are untouched', warning: 'Destroy and respawn every wild dino? Tamed creatures are not affected.' },
];

export default function Home() {
  const [status, setStatus] = useState<StatusPayload | null>(null);
  const [error, setError] = useState('');
  const [job, setJob] = useState<ActionJob>({ state: 'idle' });
  const [confirming, setConfirming] = useState<ActionId | null>(null);
  const [actionError, setActionError] = useState('');
  const [config, setConfig] = useState<ManagerConfig | null>(null);
  const [draftRates, setDraftRates] = useState<Record<string,number>>({});
  const [draftMods, setDraftMods] = useState<string[]>([]);
  const [newMod, setNewMod] = useState('');
  const [configMessage, setConfigMessage] = useState('');
  const [preview, setPreview] = useState<ConfigPreview | null>(null);

  useEffect(() => {
    let active = true;
    const load = async () => {
      try {
        const localPreview = ['localhost', '127.0.0.1'].includes(window.location.hostname) && window.location.port !== '8415';
        const api = localPreview ? 'http://127.0.0.1:8415/api/status' : '/api/status';
        const response = await fetch(api, { cache: 'no-store', credentials: 'include' });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const payload = await response.json() as StatusPayload;
        if (active) { setStatus(payload); setError(''); }
      } catch {
        if (active) setError('Local status service is offline');
      }
    };
    load();
    const timer = window.setInterval(load, 10000);
    return () => { active = false; window.clearInterval(timer); };
  }, []);

  const loadConfig = async () => {
    try {
      const response = await fetch('/api/config', { cache:'no-store', credentials:'include' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const payload = await response.json() as ManagerConfig;
      setConfig(payload); setDraftRates(payload.rates); setDraftMods(payload.mods); setConfigMessage('');
    } catch { setConfigMessage('Could not load manager settings.'); }
  };

  useEffect(() => {
    const timer = window.setTimeout(loadConfig, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    let active = true;
    const loadJob = async () => {
      try {
        const response = await fetch('/api/actions', { cache: 'no-store', credentials: 'include' });
        if (response.ok && active) setJob(await response.json() as ActionJob);
      } catch { /* status card already reports connectivity */ }
    };
    loadJob();
    const timer = window.setInterval(loadJob, 1500);
    return () => { active = false; window.clearInterval(timer); };
  }, []);

  const runAction = async (id: ActionId) => {
    setConfirming(null);
    setActionError('');
    try {
      const response = await fetch(`/api/actions/${id}`, { method: 'POST', credentials: 'include', headers: { 'Content-Type': 'application/json' } });
      const payload = await response.json() as ActionJob & { error?: string };
      if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
      setJob(payload);
    } catch (caught) { setActionError(caught instanceof Error ? caught.message : 'Action failed'); }
  };

  const previewConfig = async () => {
    setConfigMessage('');
    try {
      const response = await fetch('/api/config/preview',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify({rates:draftRates,mods:draftMods})});
      const payload = await response.json() as ConfigPreview & {error?:string};
      if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
      if (!payload.changedRates.length && !payload.modsChanged) { setConfigMessage('Nothing changed.'); return; }
      setPreview(payload);
    } catch (caught) { setConfigMessage(caught instanceof Error ? caught.message : 'Preview failed.'); }
  };

  const applyConfig = async () => {
    if (!preview) return;
    try {
      const response = await fetch('/api/config/apply',{method:'POST',credentials:'include',headers:{'Content-Type':'application/json'},body:JSON.stringify({token:preview.token})});
      const payload = await response.json() as {message?:string;error?:string};
      if (!response.ok) throw new Error(payload.error || `HTTP ${response.status}`);
      setPreview(null); setConfigMessage(payload.message || 'Settings saved.'); await loadConfig();
    } catch (caught) { setPreview(null); setConfigMessage(caught instanceof Error ? caught.message : 'Save failed.'); }
  };

  const addMod = () => {
    const id = newMod.trim();
    if (!/^\d+$/.test(id)) { setConfigMessage('Enter a numeric CurseForge project ID.'); return; }
    if (draftMods.includes(id)) { setConfigMessage('That mod is already listed.'); return; }
    setDraftMods([...draftMods,id]); setNewMod(''); setConfigMessage('');
  };

  const moveMod = (index:number, direction:-1|1) => {
    const target=index+direction; if(target<0||target>=draftMods.length)return;
    const next=[...draftMods]; [next[index],next[target]]=[next[target],next[index]]; setDraftMods(next);
  };

  const backupText = useMemo(() => {
    if (!status?.backup.found || !status.backup.timestamp) return 'Not found';
    return new Intl.DateTimeFormat('en', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }).format(new Date(status.backup.timestamp));
  }, [status]);

  const statCards = [
    { label: 'Server', value: status ? (status.server.running ? 'Online' : 'Stopped') : 'Checking…', detail: status?.server.running ? `PID ${status.server.pid} · ${status.server.privateMemoryGb} GB` : (error || 'Local Windows host'), tone: status?.server.running ? 'green' : 'cyan' },
    { label: 'Map', value: status?.server.map || 'Aberration', detail: status?.server.mapId || 'Aberration_WP', tone: 'violet' },
    { label: 'Capacity', value: status?.server.maxPlayers ? `0 / ${status.server.maxPlayers}` : '—', detail: status ? `${status.server.modCount} cross-platform mods` : 'Waiting for live status', tone: 'amber' },
    { label: 'Last backup', value: status ? backupText : 'Checking…', detail: status?.backup.found ? 'Full save snapshot' : 'Verified world backup', tone: 'green' },
  ];
  return (
    <main className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="brandMark" aria-hidden="true">A</span>
          <div><p className="eyebrow">Gustav&apos;s private server</p><h1>ASA Control Deck</h1></div>
        </div>
        <div className={`connectionBadge ${error ? 'offline' : ''}`}><span /> {error || 'Local service connected'}</div>
      </header>

      <section className="hero">
        <div>
          <p className="eyebrow">ARK: Survival Ascended</p>
          <h2>Your server, from any room.</h2>
          <p className="heroCopy">A remote companion to the original Windows manager. Run guarded server operations here while the Windows manager remains the configuration source of truth.</p>
        </div>
        <div className="modeCard"><span className="modeIcon">◉</span><div><strong>Guarded controls active</strong><small>Confirmation required</small></div></div>
      </section>

      <section className="stats" aria-label="Server overview">
        {statCards.map((card) => <article className={`statCard ${card.tone}`} key={card.label}><p>{card.label}</p><strong>{card.value}</strong><small>{card.detail}</small></article>)}
      </section>

      <div className="contentGrid">
        <section className="panel actionsPanel">
          <div className="sectionHeading"><div><p className="eyebrow">Operations</p><h3>Server controls</h3></div><span className={`locked ${job.state}`}>{job.state === 'running' ? 'Working…' : 'Protected'}</span></div>
          <div className="actionGrid">
            {actions.map((action) => <button key={action.id} disabled={job.state === 'running'} onClick={() => setConfirming(action.id)}><span>{action.icon}</span><b>{action.label}</b><small>{action.detail}</small></button>)}
          </div>
          <p className={`panelNote actionResult ${job.state}`}>{actionError || job.message || 'Choose an operation. Every disruptive action asks for confirmation first.'}</p>
        </section>

        <section className="panel healthPanel">
          <div className="sectionHeading"><div><p className="eyebrow">Host health</p><h3>Windows server PC</h3></div></div>
          <div className="meter"><div><span>Memory</span><b>{status ? `${status.host.memoryUsedGb} / ${status.host.memoryTotalGb} GB` : 'Waiting…'}</b></div><i><em style={{ width: `${status?.host.memoryPercent || 0}%` }} /></i></div>
          <div className="meter"><div><span>CPU</span><b>{status ? `${status.host.cpuPercent}%` : 'Waiting…'}</b></div><i><em style={{ width: `${status?.host.cpuPercent || 0}%` }} /></i></div>
          <div className="meter"><div><span>Disk free</span><b>{status ? `${status.host.diskFreeGb} GB` : 'Waiting…'}</b></div><i><em style={{ width: status ? '65%' : '0%' }} /></i></div>
          <div className="safetyRow"><span>✓</span><p><b>No cloud dependency</b><small>Works without Codex credits</small></p></div>
        </section>
      </div>

      <section className="panel managerSettings">
        <div className="sectionHeading"><div><p className="eyebrow">Configuration</p><h3>Guided server rates</h3></div><button className="saveConfigButton" onClick={previewConfig} disabled={!config}>Preview + save</button></div>
        <p className="sectionIntro">The same guarded values used by the Windows manager. Saving creates a config snapshot first; changes activate after an ASA restart.</p>
        <div className="ratesGrid">
          {config?.rateDefinitions.map((rate) => <label className="rateField" key={rate.key}><span><b>{rate.label}</b><small>{rate.help}</small></span><input type="number" min={rate.min} max={rate.max} step="0.01" value={draftRates[rate.key] ?? 1} onChange={(event)=>setDraftRates({...draftRates,[rate.key]:Number(event.target.value)})}/><em>{rate.min}–{rate.max}</em></label>)}
        </div>
      </section>

      <section className="panel modsPanel">
        <div className="sectionHeading"><div><p className="eyebrow">Cross-platform</p><h3>Mod order</h3></div><span className="modCount">{draftMods.length} mods</span></div>
        <p className="sectionIntro">Use numeric CurseForge ASA Project IDs. PS5 players need every mod to be marked cross-platform. Order can matter.</p>
        <div className="addModRow"><input inputMode="numeric" placeholder="CurseForge project ID" value={newMod} onChange={(event)=>setNewMod(event.target.value)} onKeyDown={(event)=>{if(event.key==='Enter')addMod();}}/><button onClick={addMod}>Add mod</button></div>
        <ol className="modList">{draftMods.map((id,index)=><li key={id}><span>{index+1}</span><code>{id}</code><div><button aria-label={`Move ${id} up`} onClick={()=>moveMod(index,-1)} disabled={index===0}>↑</button><button aria-label={`Move ${id} down`} onClick={()=>moveMod(index,1)} disabled={index===draftMods.length-1}>↓</button><button className="removeMod" onClick={()=>setDraftMods(draftMods.filter((item)=>item!==id))}>Remove</button></div></li>)}</ol>
        <div className="configFooter"><p className="panelNote">{configMessage || 'Edit rates and mods, then use Preview + save above to review everything together.'}</p><button className="saveConfigButton" onClick={previewConfig} disabled={!config}>Preview + save all</button></div>
      </section>

      <section className="panel logPanel">
        <div className="sectionHeading"><div><p className="eyebrow">Activity</p><h3>Local status feed</h3></div><button className="quietButton" disabled>Refresh</button></div>
        <div className="terminal" role="log">
          <p><time>LIVE</time><b>SERVER</b><span>{status?.server.running ? `Online · PID ${status.server.pid}` : 'Stopped'}</span></p>
          <p><time>SAFE</time><b>SOURCE</b><span>Original scripts and ASA Manager remain the source of truth</span></p>
          <p><time>LAN</time><b>NETWORK</b><span>No router exposure; local network only</span></p>
          {job.message && <p><time>NOW</time><b>{job.state.toUpperCase()}</b><span>{job.message}</span></p>}
        </div>
      </section>

      {confirming && <div className="modalBackdrop" role="presentation" onClick={() => setConfirming(null)}><div className="confirmModal" role="dialog" aria-modal="true" aria-labelledby="confirm-title" onClick={(event) => event.stopPropagation()}><p className="eyebrow">Confirm server action</p><h3 id="confirm-title">{actions.find((item) => item.id === confirming)?.label}</h3><p>{actions.find((item) => item.id === confirming)?.warning}</p><div><button className="cancelButton" onClick={() => setConfirming(null)}>Cancel</button><button className="confirmButton" onClick={() => runAction(confirming)}>Confirm</button></div></div></div>}
      {preview && <div className="modalBackdrop" role="presentation" onClick={()=>setPreview(null)}><div className="confirmModal previewModal" role="dialog" aria-modal="true" aria-labelledby="preview-title" onClick={(event)=>event.stopPropagation()}><p className="eyebrow">Preview → backup → apply</p><h3 id="preview-title">Review configuration</h3><p>{preview.changedRates.length} rate change(s){preview.modsChanged ? ' and a changed mod list' : ''}. A timestamped backup is created before writing. The running server is not restarted automatically.</p><ul>{preview.changedRates.map((change)=><li key={change.key}><code>{change.key}</code><span>{change.from} → {change.to}</span></li>)}{preview.modsChanged&&<li><code>MODS</code><span>{preview.fromMods.length} → {preview.toMods.length} entries</span></li>}</ul><div><button className="cancelButton" onClick={()=>setPreview(null)}>Cancel</button><button className="confirmButton" onClick={applyConfig}>Backup + apply</button></div></div></div>}

      <footer><span>ASA Control Deck · LAN manager</span><span>Original manager preserved</span></footer>
    </main>
  );
}
