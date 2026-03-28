#!/usr/bin/env node
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

// Configuration
const RESTART_INTERVAL = 0; // Disabled — Paperspace restarts every 6h, and torch.compile caches are lost on restart
const QUEUE_CHECK_INTERVAL = 30 * 1000; // Check queue every 30 seconds
const CONSECUTIVE_FAILURE_THRESHOLD = 3;
const LOG_FILE = '/tmp/comfyui_auto_restart.log';
const COMFY_LOG_DIR = process.env.LOG_DIR || '/tmp/log';
const INSTANCE_ACTIVITY_GRACE_MS = 90 * 1000;
const WARMUP_STATUS_FILE = '/tmp/comfy_warmup_status.json';
const WARMUP_STATUS_STALE_MS = 10 * 60 * 1000;
const DEDICATED_WARMUP_MAX_GRACE_MS = 45 * 60 * 1000;
const DEDICATED_WARMUP_TARGETS = {
    '1': 'wai',
    '2': 'pornmaster'
};

// Instance configuration (matches manage.sh)
const INSTANCES = {
    1: {
        port: 7005,
        path: '/sd-comfy/',
        logFile: 'sd_comfy.log',
        queueThreshold: 18,
        disableQueueDepthRestart: true,
        warmupGracePeriod: 25 * 60 * 1000,
        stagnantQueueRestartAfter: 15 * 60 * 1000
    },
    2: {
        port: 7100,
        path: '/com2/',
        logFile: 'sd_comfy2.log',
        queueThreshold: 18,
        disableQueueDepthRestart: true,
        warmupGracePeriod: 25 * 60 * 1000,
        stagnantQueueRestartAfter: 15 * 60 * 1000
    },
    3: {
        port: 7101,
        path: '/com3/',
        logFile: 'sd_comfy3.log',
        queueThreshold: 10,
        warmupGracePeriod: 15 * 60 * 1000,
        stagnantQueueRestartAfter: 10 * 60 * 1000
    },
    4: {
        port: 7102,
        path: '/com4/',
        logFile: 'sd_comfy4.log',
        queueThreshold: 10,
        warmupGracePeriod: 15 * 60 * 1000,
        stagnantQueueRestartAfter: 10 * 60 * 1000
    }
};

// Track when each instance was last started (for warmup grace period)
const instanceStartTimes = {};
const instanceState = {};
for (const id of Object.keys(INSTANCES)) {
    instanceStartTimes[id] = Date.now(); // Assume all instances just started
    instanceState[id] = {
        consecutiveFailures: 0,
        lastQueueRemaining: null,
        lastQueueChangeAt: Date.now()
    };
}

// Logging function
function log(message) {
    const timestamp = new Date().toISOString().replace('T', ' ').split('.')[0];
    const logMessage = `[${timestamp}] ${message}\n`;
    console.log(logMessage.trim());
    fs.appendFileSync(LOG_FILE, logMessage);
}

function getInstanceLogAgeMs(instanceId, now = Date.now()) {
    const instance = INSTANCES[instanceId];
    if (!instance?.logFile) {
        return null;
    }

    try {
        const logPath = path.join(COMFY_LOG_DIR, instance.logFile);
        const stats = fs.statSync(logPath);
        return Math.max(0, now - stats.mtimeMs);
    } catch (_) {
        return null;
    }
}

function hasRecentInstanceLogActivity(instanceId, now = Date.now()) {
    const logAgeMs = getInstanceLogAgeMs(instanceId, now);
    return logAgeMs !== null && logAgeMs <= INSTANCE_ACTIVITY_GRACE_MS;
}

function readWarmupStatus() {
    try {
        if (!fs.existsSync(WARMUP_STATUS_FILE)) {
            return null;
        }

        return JSON.parse(fs.readFileSync(WARMUP_STATUS_FILE, 'utf8'));
    } catch (_) {
        return null;
    }
}

function getDedicatedWarmupTargetStatus(instanceId, warmupStatus) {
    const targetName = DEDICATED_WARMUP_TARGETS[String(instanceId)];
    if (!targetName || !warmupStatus?.targets) {
        return null;
    }

    return warmupStatus.targets[targetName] || null;
}

function isWarmupStatusFresh(warmupStatus, now = Date.now()) {
    const updatedAt = warmupStatus?.updated_at ? Date.parse(warmupStatus.updated_at) : NaN;
    if (!Number.isFinite(updatedAt)) {
        return false;
    }

    return now - updatedAt <= WARMUP_STATUS_STALE_MS;
}

function isDedicatedWarmupStillRunning(instanceId, warmupStatus, elapsed, now = Date.now()) {
    if (elapsed >= DEDICATED_WARMUP_MAX_GRACE_MS || !isWarmupStatusFresh(warmupStatus, now)) {
        return false;
    }

    const targetStatus = getDedicatedWarmupTargetStatus(instanceId, warmupStatus);
    if (!targetStatus) {
        return false;
    }

    return targetStatus.state === 'pending' || targetStatus.state === 'running';
}

// Function to check queue status for a single instance
function checkInstanceQueue(instanceId) {
    return new Promise((resolve) => {
        const instance = INSTANCES[instanceId];
        if (!instance) {
            resolve({ instanceId, error: 'Invalid instance ID' });
            return;
        }

        const url = `http://127.0.0.1:${instance.port}/prompt`;
        const request = http.get(url, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                if (res.statusCode && res.statusCode >= 400) {
                    resolve({ instanceId, error: `HTTP ${res.statusCode}`, success: false });
                    return;
                }
                try {
                    const response = JSON.parse(data);
                    const queueRemaining = response.exec_info?.queue_remaining || 0;
                    resolve({ instanceId, queueRemaining, success: true });
                } catch (error) {
                    resolve({ instanceId, error: 'Failed to parse response', success: false });
                }
            });
        });

        request.setTimeout(5000, () => {
            request.destroy(new Error('Request timed out'));
        });

        request.on('error', (error) => {
            resolve({ instanceId, error: error.message, success: false });
        });
    });
}

// Function to restart a single instance
function restartSingleInstance(instanceId) {
    return new Promise((resolve) => {
        const manageScript = path.join(__dirname, 'manage.sh');
        const recoveryLog = `/tmp/comfy_recover_instance${instanceId}.log`;
        
        if (!fs.existsSync(manageScript)) {
            log(`ERROR: manage.sh not found at ${manageScript}`);
            resolve(false);
            return;
        }
        
        log(`Restarting stuck instance ${instanceId}...`);
        
        // Use stop, verify, then start approach
        exec(`bash "${manageScript}" stop ${instanceId}`, (error, stdout, stderr) => {
            if (error) {
                log(`ERROR stopping instance ${instanceId}: ${error.message}`);
                resolve(false);
                return;
            }
            
            // Wait 2 seconds, then start
            setTimeout(() => {
                exec(
                    `nohup env -u MPLBACKEND bash "${manageScript}" start ${instanceId} > "${recoveryLog}" 2>&1 < /dev/null &`,
                    (error, stdout, stderr) => {
                    if (error) {
                        log(`ERROR starting instance ${instanceId}: ${error.message}`);
                        resolve(false);
                        return;
                    }
                    
                    log(`Triggered detached restart for instance ${instanceId} (log: ${recoveryLog})`);
                    instanceStartTimes[instanceId] = Date.now();
                    instanceState[instanceId] = {
                        consecutiveFailures: 0,
                        lastQueueRemaining: null,
                        lastQueueChangeAt: Date.now()
                    };
                    if (stdout) log(stdout);
                    resolve(true);
                    }
                );
            }, 2000);
        });
    });
}

// Function to run image cleanup
function runImageCleanup() {
    return new Promise((resolve, reject) => {
        const cleanupScript = path.join(__dirname, 'image_cleanup.sh');
        
        if (!fs.existsSync(cleanupScript)) {
            log('WARNING: image_cleanup.sh not found, skipping cleanup');
            resolve();
            return;
        }
        
        log('Running image cleanup before restart...');
        exec(`bash "${cleanupScript}" run`, (error, stdout, stderr) => {
            if (error) {
                log(`ERROR during cleanup: ${error.message}`);
            }
            if (stdout) log(stdout);
            if (stderr) log(`Cleanup stderr: ${stderr}`);
            resolve();
        });
    });
}

// Function to verify all instances are stopped
function verifyAllStopped() {
    return new Promise((resolve) => {
        const manageScript = path.join(__dirname, 'manage.sh');
        
        exec(`bash "${manageScript}" status all`, (error, stdout, stderr) => {
            if (error) {
                log(`ERROR checking status: ${error.message}`);
                resolve(false);
                return;
            }
            
            // Check if output contains "STOPPED" for all instances
            const stoppedCount = (stdout.match(/STOPPED/g) || []).length;
            const expectedCount = Object.keys(INSTANCES).length;
            
            log(`Status check: ${stoppedCount}/${expectedCount} instances stopped`);
            resolve(stoppedCount === expectedCount);
        });
    });
}

// Function to restart all ComfyUI instances using stop/verify/start approach
async function restartAllInstances() {
    log('Starting scheduled restart of all ComfyUI instances');
    
    // Run image cleanup first
    await runImageCleanup();
    
    const manageScript = path.join(__dirname, 'manage.sh');
    
    if (!fs.existsSync(manageScript)) {
        log(`ERROR: manage.sh not found at ${manageScript}`);
        return;
    }
    
    return new Promise((resolve) => {
        // Step 1: Stop all instances
        log('Stopping all instances...');
        exec(`bash "${manageScript}" stop all`, async (error, stdout, stderr) => {
            if (error) {
                log(`ERROR stopping instances: ${error.message}`);
                resolve(false);
                return;
            }
            
            if (stdout) log(stdout);
            
            // Step 2: Wait and verify they're stopped
            await new Promise(res => setTimeout(res, 3000)); // Wait 3 seconds
            
            const allStopped = await verifyAllStopped();
            if (!allStopped) {
                log('WARNING: Not all instances stopped properly, proceeding anyway...');
            }
            
            // Step 3: Start all instances
            log('Starting all instances...');
            exec(`bash "${manageScript}" start all`, (error, stdout, stderr) => {
                if (error) {
                    log(`ERROR starting instances: ${error.message}`);
                    resolve(false);
                    return;
                }
                
                if (stdout) log(stdout);
                if (stderr) log(`Start stderr: ${stderr}`);
                
                log('Successfully restarted all ComfyUI instances');
                resolve(true);
            });
        });
    });
}

// Function to check all instances for stuck queues
async function checkAllQueues() {
    const instanceIds = Object.keys(INSTANCES);
    const checks = instanceIds.map(id => checkInstanceQueue(parseInt(id)));
    const results = await Promise.all(checks);
    const warmupStatus = readWarmupStatus();
    
    for (const result of results) {
        const instanceId = String(result.instanceId);
        const instance = INSTANCES[instanceId];
        const state = instanceState[instanceId];
        const now = Date.now();
        const elapsed = now - (instanceStartTimes[instanceId] || 0);
        const dedicatedWarmupPending = isDedicatedWarmupStillRunning(instanceId, warmupStatus, elapsed, now);
        const dedicatedWarmupStatus = getDedicatedWarmupTargetStatus(instanceId, warmupStatus);
        const dedicatedWarmupFailed = dedicatedWarmupStatus?.state === 'failed';

        if (result.success) {
            state.consecutiveFailures = 0;

            if (state.lastQueueRemaining === null || state.lastQueueRemaining !== result.queueRemaining) {
                state.lastQueueRemaining = result.queueRemaining;
                state.lastQueueChangeAt = now;
            }

            if (instance.disableQueueDepthRestart) {
                if (Math.random() < 0.1) {
                    log(`Instance ${instanceId} queue: ${result.queueRemaining} items (depth restart disabled for hot dedicated lane)`);
                }
                continue;
            }

            if (result.queueRemaining > instance.queueThreshold) {
                if (dedicatedWarmupPending) {
                    const completedCount = dedicatedWarmupStatus?.completed_resolutions?.length || 0;
                    const totalCount = dedicatedWarmupStatus?.total_resolutions || 0;
                    log(
                        `Instance ${instanceId} queue ${result.queueRemaining} exceeds threshold ${instance.queueThreshold} ` +
                        `but dedicated warmup is still ${dedicatedWarmupStatus?.state || 'pending'} ` +
                        `(${completedCount}/${totalCount} resolutions compiled) - skipping restart`
                    );
                    continue;
                }

                if (elapsed < instance.warmupGracePeriod) {
                    const remaining = Math.round((instance.warmupGracePeriod - elapsed) / 1000);
                    log(
                        `Instance ${instanceId} queue ${result.queueRemaining} exceeds threshold ${instance.queueThreshold} ` +
                        `but is still in warmup (${remaining}s left) - skipping restart`
                    );
                    continue;
                }

                const stagnantFor = now - state.lastQueueChangeAt;
                if (stagnantFor < instance.stagnantQueueRestartAfter) {
                    const stagnantSeconds = Math.round(stagnantFor / 1000);
                    log(
                        `Instance ${instanceId} queue ${result.queueRemaining} exceeds threshold ${instance.queueThreshold} ` +
                        `but queue is still changing (${stagnantSeconds}s since last change) - keeping instance online`
                    );
                    continue;
                }

                if (hasRecentInstanceLogActivity(instanceId, now)) {
                    const logAgeSeconds = Math.round(getInstanceLogAgeMs(instanceId, now) / 1000);
                    state.lastQueueChangeAt = now;
                    log(
                        `Instance ${instanceId} queue ${result.queueRemaining} exceeds threshold ${instance.queueThreshold} ` +
                        `but Comfy log was active ${logAgeSeconds}s ago - keeping instance online`
                    );
                    continue;
                }

                log(
                    `Instance ${instanceId} queue ${result.queueRemaining} has been stagnant for ` +
                    `${Math.round(stagnantFor / 1000)}s after warmup - restarting instance`
                );
                await restartSingleInstance(result.instanceId);
            } else if (Math.random() < 0.1) {
                log(`Instance ${instanceId} queue: ${result.queueRemaining} items`);
            }
        } else if (result.error) {
            state.consecutiveFailures += 1;

            if (dedicatedWarmupPending) {
                const remaining = Math.round((DEDICATED_WARMUP_MAX_GRACE_MS - elapsed) / 1000);
                log(
                    `Instance ${instanceId} check failed while dedicated warmup is still ` +
                    `${dedicatedWarmupStatus?.state || 'pending'} (${remaining}s extended grace left): ${result.error}`
                );
                continue;
            }

            if (!dedicatedWarmupFailed && elapsed < instance.warmupGracePeriod) {
                if (Math.random() < 0.25) {
                    const remaining = Math.round((instance.warmupGracePeriod - elapsed) / 1000);
                    log(
                        `Instance ${instanceId} check failed during warmup (${remaining}s left): ${result.error}`
                    );
                }
                continue;
            }

            if (dedicatedWarmupFailed) {
                log(
                    `Instance ${instanceId} check failed after dedicated warmup already failed: ${result.error}`
                );
            }

            log(
                `Instance ${instanceId} check failed (${state.consecutiveFailures}/${CONSECUTIVE_FAILURE_THRESHOLD}): ` +
                `${result.error}`
            );

            if (hasRecentInstanceLogActivity(instanceId, now)) {
                const logAgeSeconds = Math.round(getInstanceLogAgeMs(instanceId, now) / 1000);
                state.consecutiveFailures = 0;
                log(
                    `Instance ${instanceId} check is failing, but Comfy log was active ${logAgeSeconds}s ago - skipping restart`
                );
                continue;
            }

            if (state.consecutiveFailures >= CONSECUTIVE_FAILURE_THRESHOLD) {
                log(
                    `Instance ${instanceId} failed ${state.consecutiveFailures} queue checks consecutively ` +
                    `after warmup - restarting instance`
                );
                await restartSingleInstance(result.instanceId);
            }
        }
    }
}

// Main execution
log('ComfyUI auto-restart service started');
log(`Will restart all instances every ${RESTART_INTERVAL / 1000 / 60} minutes`);
log(`Will check queues every ${QUEUE_CHECK_INTERVAL / 1000} seconds with per-instance thresholds and warmup windows`);

// Set up queue monitoring (restarts stuck instances with deep queues)
log('Starting queue monitoring...');
setInterval(async () => {
    await checkAllQueues();
}, QUEUE_CHECK_INTERVAL);

// Set up the scheduled restart interval (if enabled)
if (RESTART_INTERVAL > 0) {
    log(`Will restart all instances every ${RESTART_INTERVAL / 1000 / 60} minutes`);
    setInterval(async () => {
        await restartAllInstances();
        log(`Waiting ${RESTART_INTERVAL / 1000 / 60} minutes until next restart...`);
    }, RESTART_INTERVAL);
} else {
    log('Scheduled restarts disabled (relying on Paperspace 6h restart cycle)');
}

// Handle graceful shutdown
process.on('SIGTERM', () => {
    log('Auto-restart service received SIGTERM, shutting down...');
    process.exit(0);
});

process.on('SIGINT', () => {
    log('Auto-restart service received SIGINT, shutting down...');
    process.exit(0);
});

// Keep the process running
process.stdin.resume();
