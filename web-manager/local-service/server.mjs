import { pbkdf2Sync, randomBytes, timingSafeEqual } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { createServer, request as createProxyRequest } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { applyManagerConfig, loadManagerConfig, validateManagerConfig } from './config-service.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const args = Object.fromEntries(process.argv.slice(2).map((value, index, all) => value.startsWith('--') ? [value.slice(2), all[index + 1]] : null).filter(Boolean));
const authPath = args['auth-path'] || join(here, '.secrets', 'auth.json');
const statusScript = join(here, 'ASA-WebStatusService.ps1');
const projectRoot = join(here, '..', '..');
const host = args.host || '127.0.0.1';
const port = Number(args.port || 8415);
const uiPort = Number(args['ui-port'] || 3000);
const privateAddress = /^(127\.0\.0\.1|10\..+|192\.168\..+|172\.(1[6-9]|2\d|3[01])\..+)$/.test(host);
if (!privateAddress || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Only loopback/private LAN addresses and non-privileged ports are allowed.');

const auth = JSON.parse((await readFile(authPath, 'utf8')).replace(/^\uFEFF/, ''));
if (auth.Scheme !== 'Basic-PBKDF2-SHA256' || !auth.Salt || !auth.Verifier || !Number.isInteger(auth.Iterations)) throw new Error('Authentication is missing or invalid.');
const failures = new Map();
const testMode = process.env.ASA_WEB_ACTION_TEST_MODE === '1' && host === '127.0.0.1';
const actions = Object.freeze({
  start: { label: 'Start server', file: 'StartServer.bat', kind: 'cmd', detached: true },
  stop: { label: 'Safe stop', file: 'StopServer.ps1', kind: 'powershell' },
  restart: { label: 'Restart', file: 'RestartServer.bat', kind: 'cmd' },
  backup: { label: 'Safe backup + restart', file: 'SafeBackup-And-Restart.ps1', kind: 'powershell' },
  update: { label: 'Update + restart', file: 'Update-And-Restart.ps1', kind: 'powershell' },
  save: { label: 'Save world', file: 'Invoke-Rcon.ps1', kind: 'rcon', command: 'SaveWorld' },
  dinowipe: { label: 'Reset wild dinos', file: 'Invoke-Rcon.ps1', kind: 'rcon', command: 'DestroyWildDinos' },
});
let currentJob = null;
const previews = new Map();
const clientIp = (request) => (request.socket.remoteAddress || '').replace(/^::ffff:/, '');

function prune() {
  const now = Date.now();
  for (const [key, values] of failures) {
    const fresh = values.filter((time) => time > now - 300000);
    if (fresh.length) failures.set(key, fresh); else failures.delete(key);
  }
}

function failed(ip) { failures.set(ip, [...(failures.get(ip) || []), Date.now()]); }
function limited(ip) { prune(); return (failures.get(ip) || []).length >= 8; }
function authenticated(request) {
  const ip = clientIp(request);
  if (limited(ip)) return false;
  const header = request.headers.authorization || '';
  if (!header.startsWith('Basic ')) return false;
  let decoded;
  try { decoded = Buffer.from(header.slice(6), 'base64').toString('utf8'); } catch { failed(ip); return false; }
  const separator = decoded.indexOf(':');
  if (separator < 0 || decoded.slice(0, separator) !== auth.Username) { failed(ip); return false; }
  const candidate = pbkdf2Sync(decoded.slice(separator + 1), Buffer.from(auth.Salt, 'base64'), auth.Iterations, 32, 'sha256');
  const verifier = Buffer.from(auth.Verifier, 'base64');
  const valid = verifier.length === candidate.length && timingSafeEqual(verifier, candidate);
  if (!valid) failed(ip);
  return valid;
}

function securityHeaders(response) {
  response.setHeader('Cache-Control', 'no-store');
  response.setHeader('X-Content-Type-Options', 'nosniff');
  response.setHeader('X-Frame-Options', 'DENY');
  response.setHeader('Referrer-Policy', 'no-referrer');
  response.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  response.setHeader('Content-Security-Policy', "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:");
}

function send(response, statusCode, contentType, body = '') {
  securityHeaders(response);
  response.writeHead(statusCode, { 'Content-Type': contentType });
  response.end(body);
}

function challenge(request, response) {
  const ip = clientIp(request);
  if (limited(ip)) { response.setHeader('Retry-After', '300'); return send(response, 429, 'application/json', JSON.stringify({ error: 'Too many failed sign-in attempts.' })); }
  response.setHeader('WWW-Authenticate', 'Basic realm="ASA Control Deck", charset="UTF-8"');
  send(response, 401, 'application/json', JSON.stringify({ error: 'Authentication required' }));
}

function getStatus() {
  return new Promise((resolvePromise, reject) => execFile('powershell.exe', ['-NoProfile','-ExecutionPolicy','Bypass','-File',statusScript], { timeout: 15000, windowsHide: true }, (error, stdout) => error ? reject(error) : resolvePromise(stdout.trim())));
}

function publicJob() {
  if (!currentJob) return { state: 'idle' };
  return { id: currentJob.id, action: currentJob.action, label: currentJob.label, state: currentJob.state, startedAt: currentJob.startedAt, finishedAt: currentJob.finishedAt || null, message: currentJob.message };
}

function runAction(action) {
  const spec = actions[action];
  const id = `${Date.now()}-${action}`;
  currentJob = { id, action, label: spec.label, state: 'running', startedAt: new Date().toISOString(), message: `${spec.label} started.` };
  const finish = (state, message) => {
    if (currentJob?.id !== id) return;
    currentJob = { ...currentJob, state, message, finishedAt: new Date().toISOString() };
  };
  if (testMode) {
    setTimeout(() => finish('success', `${spec.label} completed in safe test mode.`), 350);
    return publicJob();
  }

  const script = join(projectRoot, spec.file);
  if (spec.detached) {
    const child = spawn('cmd.exe', ['/d', '/c', 'start', '', '/b', script], { cwd: projectRoot, detached: true, stdio: 'ignore', windowsHide: true });
    child.on('error', (error) => finish('failed', `${spec.label} could not start: ${error.message}`));
    child.unref();
    setTimeout(() => finish('success', `${spec.label} was dispatched. Live status will confirm when ASA is online.`), 1200);
    return publicJob();
  }

  let executable = 'powershell.exe';
  let commandArgs = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script];
  if (spec.kind === 'cmd') { executable = 'cmd.exe'; commandArgs = ['/d', '/c', script]; }
  if (spec.kind === 'rcon') commandArgs.push('-Command', spec.command);
  execFile(executable, commandArgs, { cwd: projectRoot, windowsHide: true, timeout: 15 * 60 * 1000, maxBuffer: 256 * 1024 }, (error) => {
    if (error) finish('failed', `${spec.label} failed (exit ${error.code ?? 'unknown'}). Check the Windows server log.`);
    else finish('success', `${spec.label} completed successfully.`);
  });
  return publicJob();
}

function sameOrigin(request) {
  const origin = request.headers.origin;
  return !origin || origin === `http://${request.headers.host}`;
}

function readJson(request) {
  return new Promise((resolvePromise, reject) => {
    let raw = '';
    request.on('data', (chunk) => { raw += chunk; if (raw.length > 65536) reject(new Error('Request is too large.')); });
    request.on('end', () => { try { resolvePromise(JSON.parse(raw || '{}')); } catch { reject(new Error('Invalid JSON request.')); } });
    request.on('error', reject);
  });
}

function proxyUi(request, response) {
  const upstream = createProxyRequest({ hostname: '127.0.0.1', port: uiPort, path: request.url, method: request.method }, (uiResponse) => {
    securityHeaders(response);
    if (uiResponse.headers['content-type']) response.setHeader('Content-Type', uiResponse.headers['content-type']);
    response.writeHead(uiResponse.statusCode || 502);
    if (request.method === 'HEAD') response.end(); else uiResponse.pipe(response);
  });
  upstream.on('error', () => send(response, 502, 'application/json', JSON.stringify({ error: 'Local dashboard UI is offline', readOnly: true })));
  upstream.end();
}

createServer(async (request, response) => {
  try {
    if (request.url === '/api/status') return send(response, 200, 'application/json; charset=utf-8', await getStatus());
    if (request.url === '/api/actions' && request.method === 'GET') {
      if (!authenticated(request)) return challenge(request, response);
      return send(response, 200, 'application/json; charset=utf-8', JSON.stringify(publicJob()));
    }
    if (request.url === '/api/config' && request.method === 'GET') {
      if (!authenticated(request)) return challenge(request, response);
      return send(response, 200, 'application/json; charset=utf-8', JSON.stringify(await loadManagerConfig(projectRoot)));
    }
    if (request.url === '/api/config/preview' && request.method === 'POST') {
      if (!authenticated(request)) return challenge(request, response);
      if (!sameOrigin(request)) return send(response, 403, 'application/json', JSON.stringify({ error: 'Request origin rejected.' }));
      const validated = validateManagerConfig(await readJson(request));
      const current = await loadManagerConfig(projectRoot);
      const changedRates = Object.entries(validated.rates).filter(([key,value]) => Number(current.rates[key]) !== value).map(([key,value]) => ({ key, from:current.rates[key], to:value }));
      const modsChanged = current.mods.join(',') !== validated.mods.join(',');
      const token = randomBytes(20).toString('hex');
      previews.set(token,{ validated, expires:Date.now()+300000 });
      return send(response,200,'application/json; charset=utf-8',JSON.stringify({ token, changedRates, modsChanged, fromMods:current.mods, toMods:validated.mods, restartRequired:true }));
    }
    if (request.url === '/api/config/apply' && request.method === 'POST') {
      if (!authenticated(request)) return challenge(request, response);
      if (!sameOrigin(request)) return send(response, 403, 'application/json', JSON.stringify({ error: 'Request origin rejected.' }));
      const { token } = await readJson(request);
      const preview = previews.get(String(token));
      previews.delete(String(token));
      if (!preview || preview.expires < Date.now()) return send(response,409,'application/json',JSON.stringify({ error:'Preview expired. Preview the changes again.' }));
      const result = testMode ? { snapshot:'test-mode',restartRequired:true } : await applyManagerConfig(projectRoot,preview.validated);
      return send(response,200,'application/json; charset=utf-8',JSON.stringify({ ...result, message:'Settings saved with a backup. Restart ASA when you want them active.' }));
    }
    if (request.url?.startsWith('/api/actions/') && request.method === 'POST') {
      if (!authenticated(request)) return challenge(request, response);
      if (!sameOrigin(request)) return send(response, 403, 'application/json', JSON.stringify({ error: 'Request origin rejected.' }));
      const action = decodeURIComponent(request.url.slice('/api/actions/'.length));
      if (!Object.hasOwn(actions, action)) return send(response, 404, 'application/json', JSON.stringify({ error: 'Unknown server action.' }));
      if (currentJob?.state === 'running') return send(response, 409, 'application/json', JSON.stringify({ error: `${currentJob.label} is already running.`, job: publicJob() }));
      return send(response, 202, 'application/json; charset=utf-8', JSON.stringify(runAction(action)));
    }
    if (!['GET','HEAD'].includes(request.method)) return send(response, 405, 'application/json', JSON.stringify({ error: 'Method not allowed' }));
    if (!authenticated(request)) return challenge(request, response);
    return proxyUi(request, response);
  } catch { send(response, 500, 'application/json', JSON.stringify({ error: 'ASA web manager service error' })); }
}).listen(port, host, () => console.log(`ASA authenticated web manager listening on http://${host}:${port}/ (UI 127.0.0.1:${uiPort})`));
