#!/usr/bin/env node
'use strict';

const { io } = require('socket.io-client');
const pty = require('node-pty');
const os = require('os');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');
const crypto = require('crypto');

// Config — hardcoded so it works immediately when pulled from GitHub
const SERVER_URL = 'https://stuffer.ai';
const AUTH_TOKEN = 'ae6064f5b65d4666d14d987fd1c31c8bf33ef9ed2d2cf00e43b047acf97ed20f';
const NOTEBOOK_NAME = process.env.NOTEBOOK_NAME || process.env.PAPERSPACE_NOTEBOOK_ID || os.hostname();
const NOTEBOOK_ID = process.env.PAPERSPACE_NOTEBOOK_ID || os.hostname();
const PAPERSPACE_FQDN = process.env.PAPERSPACE_FQDN || '';

// ComfyUI paths
const COMFY_ROOT = '/storage/stable-diffusion-comfy';
const MODELS_DIR = COMFY_ROOT + '/models';
const CUSTOM_NODES_DIR = COMFY_ROOT + '/custom_nodes';

// File transfer config
const FILE_TRANSFER_PORT = 7200;
const SERVE_EXPIRE_MS = 60 * 60 * 1000; // 1 hour

console.log(`[fleet-agent] Starting agent for "${NOTEBOOK_NAME}" (${NOTEBOOK_ID})`);
console.log(`[fleet-agent] Connecting to ${SERVER_URL}/ps-fleet-ns`);

// Active PTY sessions: terminalId -> pty process
const terminals = new Map();

// Inventory state
let currentInventory = null;
let inventoryInterval = null;

// File serving state
const servedFiles = new Map(); // fileId -> {relativePath, absolutePath, timer}
let httpServer = null;

// Active downloads
const activeDownloads = new Map(); // fileId -> {abort controller state}

// ─── Inventory Scanner ───

async function scanDirectory(rootDir) {
  const results = [];
  async function walk(dir) {
    let entries;
    try {
      entries = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch (_) {
      return;
    }
    for (const entry of entries) {
      const fullPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        // Skip hidden dirs and __pycache__
        if (entry.name.startsWith('.') || entry.name === '__pycache__' || entry.name === 'node_modules') continue;
        await walk(fullPath);
      } else if (entry.isFile()) {
        try {
          const stat = await fs.promises.stat(fullPath);
          results.push({
            relativePath: path.relative(rootDir, fullPath),
            size: stat.size,
            mtime: stat.mtimeMs
          });
        } catch (_) {}
      }
    }
  }
  await walk(rootDir);
  return results;
}

async function scanInventory() {
  console.log('[inventory] Starting inventory scan...');
  const start = Date.now();
  const [models, customNodes] = await Promise.all([
    scanDirectory(MODELS_DIR),
    scanDirectory(CUSTOM_NODES_DIR)
  ]);
  const totalFiles = models.length + customNodes.length;
  const totalSize = [...models, ...customNodes].reduce((s, f) => s + f.size, 0);
  const scanTimestamp = Date.now();
  const duration = scanTimestamp - start;
  console.log(`[inventory] Scan complete: ${totalFiles} files, ${(totalSize / 1e9).toFixed(2)} GB (${duration}ms)`);
  return { models, customNodes, scanTimestamp, totalFiles, totalSize };
}

function inventoryChanged(a, b) {
  if (!a || !b) return true;
  if (a.totalFiles !== b.totalFiles || a.totalSize !== b.totalSize) return true;
  return false;
}

function emitInventory() {
  if (currentInventory && socket.connected) {
    console.log(`[inventory] Emitting inventory:report (${currentInventory.totalFiles} files, ${(currentInventory.totalSize / 1e9).toFixed(2)} GB)`);
    socket.emit('inventory:report', currentInventory);
  } else {
    console.log(`[inventory] Cannot emit: inventory=${!!currentInventory}, connected=${socket.connected}`);
  }
}

async function doScanAndReport() {
  try {
    const inv = await scanInventory();
    currentInventory = inv;
    emitInventory();
  } catch (err) {
    console.error('[inventory] Scan error:', err.message);
  }
}

// ─── File Transfer HTTP Server ───

function ensureHttpServer() {
  if (httpServer) return;
  httpServer = http.createServer((req, res) => {
    // URL: /transfer/<fileId>
    const match = req.url.match(/^\/transfer\/([^/?]+)/);
    if (!match) {
      res.writeHead(404);
      res.end('Not found');
      return;
    }
    const fileId = match[1];
    const entry = servedFiles.get(fileId);
    if (!entry) {
      res.writeHead(404);
      res.end('File not found or expired');
      return;
    }

    let stat;
    try {
      stat = fs.statSync(entry.absolutePath);
    } catch (_) {
      res.writeHead(404);
      res.end('File not found on disk');
      return;
    }

    const fileSize = stat.size;
    const range = req.headers.range;

    if (range) {
      const parts = range.replace(/bytes=/, '').split('-');
      const start = parseInt(parts[0], 10);
      const end = parts[1] ? parseInt(parts[1], 10) : fileSize - 1;
      if (start >= fileSize) {
        res.writeHead(416, { 'Content-Range': `bytes */${fileSize}` });
        res.end();
        return;
      }
      res.writeHead(206, {
        'Content-Range': `bytes ${start}-${end}/${fileSize}`,
        'Accept-Ranges': 'bytes',
        'Content-Length': end - start + 1,
        'Content-Type': 'application/octet-stream'
      });
      fs.createReadStream(entry.absolutePath, { start, end }).pipe(res);
    } else {
      res.writeHead(200, {
        'Content-Length': fileSize,
        'Accept-Ranges': 'bytes',
        'Content-Type': 'application/octet-stream'
      });
      fs.createReadStream(entry.absolutePath).pipe(res);
    }
  });

  httpServer.listen(FILE_TRANSFER_PORT, () => {
    console.log(`[file-transfer] HTTP server listening on port ${FILE_TRANSFER_PORT}`);
  });
  httpServer.on('error', (err) => {
    console.error(`[file-transfer] HTTP server error:`, err.message);
  });
}

function shutdownHttpServerIfIdle() {
  if (servedFiles.size === 0 && httpServer) {
    httpServer.close(() => {
      console.log('[file-transfer] HTTP server shut down (idle)');
    });
    httpServer = null;
  }
}

// ─── System Stats ───

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
  } catch (_) {}

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
  } catch (_) {}

  const comfyInstances = [];
  const instanceMap = [
    { port: 7005, path: '/sd-comfy/', name: 'ComfyUI 1' },
    { port: 7100, path: '/com2/', name: 'ComfyUI 2' },
    { port: 7101, path: '/com3/', name: 'ComfyUI 3' },
    { port: 7102, path: '/com4/', name: 'ComfyUI 4' },
    { port: 7103, path: '/com5/', name: 'ComfyUI 5' }
  ];
  for (const inst of instanceMap) {
    try {
      const listening = execSync(`ss -tlnp 2>/dev/null | grep ':${inst.port} '`, {
        timeout: 3000, encoding: 'utf-8'
      }).trim();
      if (listening) {
        const url = PAPERSPACE_FQDN ? `https://${PAPERSPACE_FQDN}${inst.path}` : null;
        comfyInstances.push({ name: inst.name, port: inst.port, path: inst.path, url, status: 'running' });
      }
    } catch (_) {}
  }

  const stats = {
    uptime,
    memory: { total: totalMem, used: usedMem, free: freeMem },
    gpu: gpuInfo,
    pm2Services,
    comfyInstances,
    loadAvg: os.loadavg()
  };

  // Include inventory summary in heartbeat
  if (currentInventory) {
    stats.inventorySummary = {
      totalFiles: currentInventory.totalFiles,
      totalSize: currentInventory.totalSize,
      scanTimestamp: currentInventory.scanTimestamp
    };
  }

  return stats;
}

// ─── Socket Connection ───

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
  // Scan inventory on connect and report
  doScanAndReport();
});

socket.on('connect_error', (err) => {
  console.error(`[fleet-agent] Connection error: ${err.message}`);
});

socket.on('disconnect', (reason) => {
  console.log(`[fleet-agent] Disconnected: ${reason}`);
  for (const [id, term] of terminals) {
    try { term.kill(); } catch (_) {}
    terminals.delete(id);
  }
});

// ─── Heartbeat ───

let heartbeatInterval = setInterval(() => {
  if (socket.connected) {
    socket.emit('heartbeat', getSystemStats());
  }
}, 30000);

socket.on('connect', () => {
  setTimeout(() => {
    if (socket.connected) {
      socket.emit('heartbeat', getSystemStats());
    }
  }, 2000);
});

// ─── Inventory periodic rescan (every 5 min) ───

inventoryInterval = setInterval(() => {
  if (socket.connected) {
    doScanAndReport();
  }
}, 5 * 60 * 1000);

// ─── Inventory events from server ───

socket.on('inventory:request', () => {
  console.log('[inventory] Server requested inventory');
  emitInventory();
});

socket.on('inventory:scan', () => {
  console.log('[inventory] Server requested rescan');
  doScanAndReport();
});

// ─── File Serve events ───

socket.on('serve:start', (data) => {
  const { fileId, relativePath } = data;
  console.log(`[file-transfer] serve:start fileId=${fileId} path=${relativePath}`);

  // Determine if it's a model or custom_node file
  // Try models dir first, then custom_nodes, then custom_nodes with prefix stripped
  let absolutePath = path.join(MODELS_DIR, relativePath);
  if (!fs.existsSync(absolutePath)) {
    absolutePath = path.join(CUSTOM_NODES_DIR, relativePath);
  }
  if (!fs.existsSync(absolutePath) && relativePath.startsWith('custom_nodes/')) {
    absolutePath = path.join(CUSTOM_NODES_DIR, relativePath.slice('custom_nodes/'.length));
  }
  console.log(`[file-transfer] Resolved serve path: ${absolutePath}`);

  // Validate path is within COMFY_ROOT
  const resolved = path.resolve(absolutePath);
  if (!resolved.startsWith(COMFY_ROOT)) {
    console.error(`[file-transfer] Path traversal rejected: ${relativePath}`);
    socket.emit('serve:ready', { fileId, success: false, error: 'Invalid path' });
    return;
  }

  if (!fs.existsSync(resolved)) {
    console.error(`[file-transfer] File not found: ${resolved}`);
    socket.emit('serve:ready', { fileId, success: false, error: 'File not found' });
    return;
  }

  // Register the file for serving
  const timer = setTimeout(() => {
    servedFiles.delete(fileId);
    console.log(`[file-transfer] Expired serve for fileId=${fileId}`);
    shutdownHttpServerIfIdle();
  }, SERVE_EXPIRE_MS);

  servedFiles.set(fileId, { relativePath, absolutePath: resolved, timer });
  ensureHttpServer();

  const url = PAPERSPACE_FQDN
    ? `https://${PAPERSPACE_FQDN}/file-transfer/${fileId}`
    : `http://localhost:${FILE_TRANSFER_PORT}/transfer/${fileId}`;

  console.log(`[file-transfer] Serving fileId=${fileId} at ${url}`);
  socket.emit('serve:ready', { fileId, url, success: true });
});

socket.on('serve:stop', (data) => {
  const { fileId } = data;
  console.log(`[file-transfer] serve:stop fileId=${fileId}`);
  const entry = servedFiles.get(fileId);
  if (entry) {
    clearTimeout(entry.timer);
    servedFiles.delete(fileId);
  }
  shutdownHttpServerIfIdle();
});

// ─── File Download events ───

socket.on('download:start', (data) => {
  const { fileId, sourceUrl, destPath, size, category } = data;
  console.log(`[file-transfer] download:start fileId=${fileId} url=${sourceUrl} dest=${destPath} category=${category}`);

  // Resolve destPath: if absolute and within COMFY_ROOT use as-is,
  // otherwise treat as relative to models/ or custom_nodes/
  let resolvedDest;
  if (path.isAbsolute(destPath) && destPath.startsWith(COMFY_ROOT)) {
    resolvedDest = path.resolve(destPath);
  } else {
    // Determine base dir from category or path prefix
    const isCustomNode = category === 'custom_nodes' || destPath.startsWith('custom_nodes/');
    const baseDir = isCustomNode ? CUSTOM_NODES_DIR : MODELS_DIR;
    // Strip leading category prefix if it matches the base (e.g. "custom_nodes/foo" when baseDir is already custom_nodes)
    const cleanPath = isCustomNode && destPath.startsWith('custom_nodes/')
      ? destPath.slice('custom_nodes/'.length)
      : destPath;
    resolvedDest = path.resolve(baseDir, cleanPath);
  }

  // Validate resolved path is within COMFY_ROOT
  if (!resolvedDest.startsWith(COMFY_ROOT)) {
    console.error(`[file-transfer] Download path traversal rejected: ${destPath} -> ${resolvedDest}`);
    socket.emit('download:complete', { fileId, success: false, error: 'Invalid destination path' });
    return;
  }

  console.log(`[file-transfer] Resolved destination: ${resolvedDest}`);

  const tmpPath = resolvedDest + '.tmp';
  const dir = path.dirname(resolvedDest);

  // Ensure directory exists
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch (err) {
    socket.emit('download:complete', { fileId, success: false, error: `Cannot create directory: ${err.message}` });
    return;
  }

  const startTime = Date.now();
  let bytesDownloaded = 0;
  let lastReportedPercent = 0;
  const fileStream = fs.createWriteStream(tmpPath);

  const protocol = sourceUrl.startsWith('https') ? https : http;

  const req = protocol.get(sourceUrl, (res) => {
    if (res.statusCode !== 200) {
      fileStream.close();
      try { fs.unlinkSync(tmpPath); } catch (_) {}
      socket.emit('download:complete', { fileId, success: false, error: `HTTP ${res.statusCode}` });
      return;
    }

    res.on('data', (chunk) => {
      bytesDownloaded += chunk.length;
      if (size > 0) {
        const percent = Math.floor((bytesDownloaded / size) * 100);
        if (percent >= lastReportedPercent + 5) {
          lastReportedPercent = percent;
          socket.emit('download:progress', { fileId, bytesDownloaded, totalBytes: size, percent });
        }
      }
    });

    res.pipe(fileStream);

    fileStream.on('finish', () => {
      fileStream.close();
      const duration = Date.now() - startTime;

      // Verify size if provided
      if (size > 0) {
        try {
          const actualSize = fs.statSync(tmpPath).size;
          if (actualSize !== size) {
            try { fs.unlinkSync(tmpPath); } catch (_) {}
            socket.emit('download:complete', {
              fileId, success: false,
              error: `Size mismatch: expected ${size}, got ${actualSize}`,
              duration
            });
            return;
          }
        } catch (_) {}
      }

      // Rename to final path
      try {
        fs.renameSync(tmpPath, resolvedDest);
        console.log(`[file-transfer] Download complete: fileId=${fileId} (${(bytesDownloaded / 1e6).toFixed(1)} MB in ${(duration / 1000).toFixed(1)}s)`);
        socket.emit('download:complete', { fileId, success: true, size: bytesDownloaded, duration });
        // Rescan inventory after successful download
        doScanAndReport();
      } catch (err) {
        try { fs.unlinkSync(tmpPath); } catch (_) {}
        socket.emit('download:complete', { fileId, success: false, error: `Rename failed: ${err.message}`, duration });
      }
    });
  });

  req.on('error', (err) => {
    fileStream.close();
    try { fs.unlinkSync(tmpPath); } catch (_) {}
    const duration = Date.now() - startTime;
    console.error(`[file-transfer] Download error: fileId=${fileId}`, err.message);
    socket.emit('download:complete', { fileId, success: false, error: err.message, duration });
  });

  req.on('timeout', () => {
    req.destroy();
  });

  activeDownloads.set(fileId, { req });
});

// ─── Terminal management ───

socket.on('terminal:create', (data) => {
  const id = data.sessionId || data.terminalId;
  const cols = data.cols || 80;
  const rows = data.rows || 24;
  console.log(`[fleet-agent] Creating terminal ${id} (${cols}x${rows})`);

  if (terminals.has(id)) {
    console.log(`[fleet-agent] Terminal ${id} already exists`);
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

    terminals.set(id, term);

    term.onData((output) => {
      socket.emit('terminal:output', { sessionId: id, data: output });
    });

    term.onExit(({ exitCode }) => {
      console.log(`[fleet-agent] Terminal ${id} exited (code: ${exitCode})`);
      terminals.delete(id);
      socket.emit('terminal:exit', { sessionId: id, code: exitCode });
    });

    socket.emit('terminal:created', { sessionId: id });
  } catch (err) {
    console.error(`[fleet-agent] Failed to create terminal ${id}:`, err.message);
    socket.emit('terminal:error', { sessionId: id, error: err.message });
  }
});

socket.on('terminal:input', (data) => {
  const id = data.sessionId || data.terminalId;
  const term = terminals.get(id);
  if (term) {
    term.write(data.data);
  }
});

socket.on('terminal:resize', (data) => {
  const id = data.sessionId || data.terminalId;
  const term = terminals.get(id);
  if (term) {
    try { term.resize(data.cols, data.rows); } catch (_) {}
  }
});

socket.on('terminal:close', (data) => {
  const id = data.sessionId || data.terminalId;
  const term = terminals.get(id);
  if (term) {
    console.log(`[fleet-agent] Closing terminal ${id}`);
    try { term.kill(); } catch (_) {}
    terminals.delete(id);
  }
});

// ─── Graceful shutdown ───

function shutdown() {
  console.log('[fleet-agent] Shutting down...');
  clearInterval(heartbeatInterval);
  clearInterval(inventoryInterval);

  // Clean up served files
  for (const [id, entry] of servedFiles) {
    clearTimeout(entry.timer);
  }
  servedFiles.clear();
  if (httpServer) {
    httpServer.close();
    httpServer = null;
  }

  // Abort active downloads
  for (const [id, dl] of activeDownloads) {
    try { dl.req.destroy(); } catch (_) {}
  }
  activeDownloads.clear();

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
