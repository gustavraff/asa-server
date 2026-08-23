import { pbkdf2Sync, timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { createServer, request as createProxyRequest } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const authPath = join(here, '.secrets', 'auth.json');
const statusScript = join(here, 'ASA-WebStatusService.ps1');
const args = Object.fromEntries(process.argv.slice(2).map((value, index, all) => value.startsWith('--') ? [value.slice(2), all[index + 1]] : null).filter(Boolean));
const host = args.host || '127.0.0.1';
const port = Number(args.port || 8415);
const uiPort = Number(args['ui-port'] || 3000);
const privateAddress = /^(127\.0\.0\.1|10\..+|192\.168\..+|172\.(1[6-9]|2\d|3[01])\..+)$/.test(host);
if (!privateAddress || !Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Only loopback/private LAN addresses and non-privileged ports are allowed.');

const auth = JSON.parse(await readFile(authPath, 'utf8'));
if (auth.Scheme !== 'Basic-PBKDF2-SHA256' || !auth.Salt || !auth.Verifier || !Number.isInteger(auth.Iterations)) throw new Error('Authentication is missing or invalid.');
const failures = new Map();
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
  response.setHeader('Content-Security-Policy', "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; connect-src 'self'; img-src 'self' data:");
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
    if (!['GET','HEAD'].includes(request.method)) return send(response, 405, 'application/json', JSON.stringify({ error: 'Method not allowed', readOnly: true }));
    if (!authenticated(request)) return challenge(request, response);
    if (request.url === '/api/status') return send(response, 200, 'application/json; charset=utf-8', await getStatus());
    return proxyUi(request, response);
  } catch { send(response, 500, 'application/json', JSON.stringify({ error: 'Read-only status service error', readOnly: true })); }
}).listen(port, host, () => console.log(`ASA authenticated read-only web manager listening on http://${host}:${port}/ (UI 127.0.0.1:${uiPort})`));
