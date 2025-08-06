#!/usr/bin/env node
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');

// Configuration
const RESTART_INTERVAL = 2 * 60 * 60 * 1000; // 2 hours in milliseconds
const QUEUE_CHECK_INTERVAL = 30 * 1000; // Check queue every 30 seconds
const QUEUE_THRESHOLD = 5; // Restart if queue_remaining > 5
const LOG_FILE = '/tmp/comfyui_auto_restart.log';

// Instance configuration (matches manage.sh)
const INSTANCES = {
    1: { port: 7005, path: '/sd-comfy/' },
    2: { port: 7100, path: '/com2/' },
    3: { port: 7101, path: '/com3/' },
    4: { port: 7102, path: '/com4/' }
};

// Get current hostname from environment
const PAPERSPACE_FQDN = process.env.PAPERSPACE_FQDN || 'localhost';

// Logging function
function log(message) {
    const timestamp = new Date().toISOString().replace('T', ' ').split('.')[0];
    const logMessage = `[${timestamp}] ${message}\n`;
    console.log(logMessage.trim());
    fs.appendFileSync(LOG_FILE, logMessage);
}

// Function to check queue status for a single instance
function checkInstanceQueue(instanceId) {
    return new Promise((resolve) => {
        const instance = INSTANCES[instanceId];
        if (!instance) {
            resolve({ instanceId, error: 'Invalid instance ID' });
            return;
        }
        
        const url = `https://${PAPERSPACE_FQDN}${instance.path}prompt`;
        
        https.get(url, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                try {
                    const response = JSON.parse(data);
                    const queueRemaining = response.exec_info?.queue_remaining || 0;
                    resolve({ instanceId, queueRemaining, success: true });
                } catch (error) {
                    resolve({ instanceId, error: 'Failed to parse response', success: false });
                }
            });
        }).on('error', (error) => {
            resolve({ instanceId, error: error.message, success: false });
        });
    });
}

// Function to restart a single instance
function restartSingleInstance(instanceId) {
    return new Promise((resolve) => {
        const manageScript = path.join(__dirname, 'manage.sh');
        
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
                exec(`bash "${manageScript}" start ${instanceId}`, (error, stdout, stderr) => {
                    if (error) {
                        log(`ERROR starting instance ${instanceId}: ${error.message}`);
                        resolve(false);
                        return;
                    }
                    
                    log(`Successfully restarted instance ${instanceId}`);
                    if (stdout) log(stdout);
                    resolve(true);
                });
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
    
    for (const result of results) {
        if (result.success && result.queueRemaining > QUEUE_THRESHOLD) {
            log(`Instance ${result.instanceId} has ${result.queueRemaining} items in queue (threshold: ${QUEUE_THRESHOLD}) - restarting...`);
            await restartSingleInstance(result.instanceId);
        } else if (result.success) {
            // Only log occasionally to avoid spam
            if (Math.random() < 0.1) { // 10% chance to log normal status
                log(`Instance ${result.instanceId} queue: ${result.queueRemaining} items`);
            }
        } else if (result.error) {
            // Only log errors occasionally to avoid spam
            if (Math.random() < 0.2) { // 20% chance to log errors
                log(`Instance ${result.instanceId} check failed: ${result.error}`);
            }
        }
    }
}

// Main execution
log('ComfyUI auto-restart service started');
log(`Will restart all instances every ${RESTART_INTERVAL / 1000 / 60} minutes`);
log(`Will check queues every ${QUEUE_CHECK_INTERVAL / 1000} seconds (threshold: ${QUEUE_THRESHOLD})`);

// Initial wait before first restart
log(`Waiting ${RESTART_INTERVAL / 1000 / 60} minutes until first restart...`);

// Set up queue monitoring
log('Starting queue monitoring...');
setInterval(async () => {
    await checkAllQueues();
}, QUEUE_CHECK_INTERVAL);

// Set up the scheduled restart interval
setInterval(async () => {
    await restartAllInstances();
    log(`Waiting ${RESTART_INTERVAL / 1000 / 60} minutes until next restart...`);
}, RESTART_INTERVAL);

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
