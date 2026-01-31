#!/usr/bin/env node
'use strict';

const { io } = require('socket.io-client');
const pty = require('node-pty');
const os = require('os');
const { execSync } = require('child_process');

// Config — hardcoded so it works immediately when pulled from GitHub
const SERVER_URL = 'https://stuffer.ai';
const AUTH_TOKEN = 'ae6064f5b65d4666d14d987fd1c31c8bf33ef9ed2d2cf00e43b047acf97ed20f';
const NOTEBOOK_NAME = process.env.NOTEBOOK_NAME || process.env.PAPERSPACE_NOTEBOOK_ID || os.hostname();
const NOTEBOOK_ID = process.env.PAPERSPACE_NOTEBOOK_ID || os.hostname();
const PAPERSPACE_FQDN = process.env.PAPERSPACE_FQDN || '';

console.log(`[fleet-agent] Starting agent for "${NOTEBOOK_NAME}" (${NOTEBOOK_ID})`);
console.log(`[fleet-agent] Connecting to ${SERVER_URL}/ps-fleet-ns`);

// Active PTY sessions: terminalId -> pty process
const terminals = new Map();

// Gather system stats for heartbeat
function getSystemStats() {
  const uptime = os.uptime();
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  const usedMem = totalMem - freeMem;

  let gpuInfo = null;
  try {
    const raw = execSync('nvidia-smi --query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu --format=csv,noheader,nounits', {
      timeout: 5000, encoding: 'utf-8'
    }).trim();
    if (raw) {
      const parts = raw.split(',').map(s => s.trim());
      gpuInfo = {
        name: parts[0],
        memUsedMB: parseInt(parts[1]),
        memTotalMB: parseInt(parts[2]),
        utilization: parseInt(parts[3]),
        tempC: parseInt(parts[4])
      };
    }
  } catch (_) { /* no GPU or nvidia-smi not available */ }

  let pm2Services = [];
  try {
    const raw = execSync('PM2_HOME=/notebooks/.pm2_config pm2 jlist 2>/dev/null', {
      timeout: 5000, encoding: 'utf-8'
    }).trim();
    const list = JSON.parse(raw);
    pm2Services = list.map(p => ({
      name: p.name,
      status: p.pm2_env?.status || 'unknown',
      cpu: p.monit?.cpu || 0,
      memory: p.monit?.memory || 0,
      restarts: p.pm2_env?.restart_time || 0
    }));
  } catch (_) { /* pm2 not available */ }

  return {
    uptime,
    memory: { total: totalMem, used: usedMem, free: freeMem },
    gpu: gpuInfo,
    pm2Services,
    loadAvg: os.loadavg()
  };
}

// Connect with auto-reconnect
const socket = io(`${SERVER_URL}/ps-fleet-ns`, {
  auth: { token: AUTH_TOKEN, notebookId: NOTEBOOK_ID, notebookName: NOTEBOOK_NAME, fqdn: PAPERSPACE_FQDN },
  reconnection: true,
  reconnectionDelay: 1000,
  reconnectionDelayMax: 60000,
  reconnectionAttempts: Infinity,
  transports: ['websocket', 'polling'],
  path: '/ps-fleet/socket.io'
});

socket.on('connect', () => {
  console.log(`[fleet-agent] Connected to server (socket id: ${socket.id})`);
});

socket.on('connect_error', (err) => {
  console.error(`[fleet-agent] Connection error: ${err.message}`);
});

socket.on('disconnect', (reason) => {
  console.log(`[fleet-agent] Disconnected: ${reason}`);
  // Clean up all terminals on disconnect
  for (const [id, term] of terminals) {
    try { term.kill(); } catch (_) {}
    terminals.delete(id);
  }
});

// Heartbeat
let heartbeatInterval = setInterval(() => {
  if (socket.connected) {
    const stats = getSystemStats();
    socket.emit('heartbeat', stats);
  }
}, 30000);

// Send initial heartbeat on connect
socket.on('connect', () => {
  setTimeout(() => {
    if (socket.connected) {
      socket.emit('heartbeat', getSystemStats());
    }
  }, 2000);
});

// Terminal management
socket.on('terminal:create', (data) => {
  const { terminalId, cols = 80, rows = 24 } = data;
  console.log(`[fleet-agent] Creating terminal ${terminalId} (${cols}x${rows})`);

  if (terminals.has(terminalId)) {
    console.log(`[fleet-agent] Terminal ${terminalId} already exists`);
    return;
  }

  try {
    const shell = process.env.SHELL || '/bin/bash';
    const term = pty.spawn(shell, [], {
      name: 'xterm-256color',
      cols,
      rows,
      cwd: process.env.HOME || '/root',
      env: { ...process.env, TERM: 'xterm-256color' }
    });

    terminals.set(terminalId, term);

    term.onData((data) => {
      socket.emit('terminal:output', { terminalId, data });
    });

    term.onExit(({ exitCode }) => {
      console.log(`[fleet-agent] Terminal ${terminalId} exited (code: ${exitCode})`);
      terminals.delete(terminalId);
      socket.emit('terminal:exit', { terminalId, exitCode });
    });

    socket.emit('terminal:created', { terminalId });
  } catch (err) {
    console.error(`[fleet-agent] Failed to create terminal ${terminalId}:`, err.message);
    socket.emit('terminal:error', { terminalId, error: err.message });
  }
});

socket.on('terminal:input', (data) => {
  const { terminalId, data: input } = data;
  const term = terminals.get(terminalId);
  if (term) {
    term.write(input);
  }
});

socket.on('terminal:resize', (data) => {
  const { terminalId, cols, rows } = data;
  const term = terminals.get(terminalId);
  if (term) {
    try { term.resize(cols, rows); } catch (_) {}
  }
});

socket.on('terminal:close', (data) => {
  const { terminalId } = data;
  const term = terminals.get(terminalId);
  if (term) {
    console.log(`[fleet-agent] Closing terminal ${terminalId}`);
    try { term.kill(); } catch (_) {}
    terminals.delete(terminalId);
  }
});

// Graceful shutdown
function shutdown() {
  console.log('[fleet-agent] Shutting down...');
  clearInterval(heartbeatInterval);
  for (const [id, term] of terminals) {
    try { term.kill(); } catch (_) {}
  }
  terminals.clear();
  socket.disconnect();
  process.exit(0);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

console.log('[fleet-agent] Agent started, waiting for connection...');
