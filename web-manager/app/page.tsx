'use client';

import { useEffect, useMemo, useState } from 'react';

type StatusPayload = {
  timestamp: string;
  readOnly: boolean;
  server: { running: boolean; pid: number | null; privateMemoryGb: number; name: string; map: string; mapId: string; maxPlayers: number | null; modCount: number };
  host: { cpuPercent: number; memoryPercent: number; memoryUsedGb: number; memoryTotalGb: number; diskFreeGb: number };
  backup: { found: boolean; timestamp: string | null; name: string | null };
};

const logLines = [
  ['SYSTEM', 'Web panel started in read-only mode'],
  ['SAFETY', 'Original ASA Manager remains the source of truth'],
  ['NETWORK', 'No router or Windows Firewall changes applied'],
  ['STATUS', 'Waiting for the local Windows status service'],
];

export default function Home() {
  const [status, setStatus] = useState<StatusPayload | null>(null);
  const [error, setError] = useState('');

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
          <p className="heroCopy">A lightweight companion to the original Windows manager. This first build observes only—it cannot change server files or run actions.</p>
        </div>
        <div className="modeCard"><span className="modeIcon">◉</span><div><strong>Read-only shield active</strong><small>Zero configuration writes</small></div></div>
      </section>

      <section className="stats" aria-label="Server overview">
        {statCards.map((card) => <article className={`statCard ${card.tone}`} key={card.label}><p>{card.label}</p><strong>{card.value}</strong><small>{card.detail}</small></article>)}
      </section>

      <div className="contentGrid">
        <section className="panel actionsPanel">
          <div className="sectionHeading"><div><p className="eyebrow">Operations</p><h3>Server controls</h3></div><span className="locked">Read-only</span></div>
          <div className="actionGrid">
            <button disabled><span>▶</span><b>Start server</b><small>Original script</small></button>
            <button disabled><span>■</span><b>Safe stop</b><small>Save + shutdown</small></button>
            <button disabled><span>↻</span><b>Restart</b><small>Player warning first</small></button>
            <button disabled><span>⬡</span><b>Safe backup</b><small>Verified snapshot</small></button>
          </div>
          <p className="panelNote">Controls unlock only after the read-only service and safety checks pass.</p>
        </section>

        <section className="panel healthPanel">
          <div className="sectionHeading"><div><p className="eyebrow">Host health</p><h3>Windows server PC</h3></div></div>
          <div className="meter"><div><span>Memory</span><b>{status ? `${status.host.memoryUsedGb} / ${status.host.memoryTotalGb} GB` : 'Waiting…'}</b></div><i><em style={{ width: `${status?.host.memoryPercent || 0}%` }} /></i></div>
          <div className="meter"><div><span>CPU</span><b>{status ? `${status.host.cpuPercent}%` : 'Waiting…'}</b></div><i><em style={{ width: `${status?.host.cpuPercent || 0}%` }} /></i></div>
          <div className="meter"><div><span>Disk free</span><b>{status ? `${status.host.diskFreeGb} GB` : 'Waiting…'}</b></div><i><em style={{ width: status ? '65%' : '0%' }} /></i></div>
          <div className="safetyRow"><span>✓</span><p><b>No cloud dependency</b><small>Works without Codex credits</small></p></div>
        </section>
      </div>

      <section className="panel logPanel">
        <div className="sectionHeading"><div><p className="eyebrow">Activity</p><h3>Local status feed</h3></div><button className="quietButton" disabled>Refresh</button></div>
        <div className="terminal" role="log">{logLines.map(([kind, message]) => <p key={kind}><time>NOW</time><b>{kind}</b><span>{message}</span></p>)}</div>
      </section>

      <footer><span>ASA Control Deck · Phase 1</span><span>Original manager preserved</span></footer>
    </main>
  );
}
