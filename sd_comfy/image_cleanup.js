#!/usr/bin/env node
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');
const { promisify } = require('util');

const execAsync = promisify(exec);
const readdirAsync = promisify(fs.readdir);
const statAsync = promisify(fs.stat);
const unlinkAsync = promisify(fs.unlink);

// Configuration
const CLEANUP_INTERVAL = 10 * 60 * 1000; // 10 minutes in milliseconds
const AGE_THRESHOLD = 20 * 60 * 1000; // 20 minutes in milliseconds
const LOG_FILE = '/tmp/comfyui_image_cleanup.log';

// Load environment variables from .env
function loadEnv() {
    const envPath = path.join(__dirname, '.env');
    if (fs.existsSync(envPath)) {
        const envContent = fs.readFileSync(envPath, 'utf8');
        envContent.split('\n').forEach(line => {
            const match = line.match(/^export\s+(\w+)=(.*)$/);
            if (match) {
                const key = match[1];
                const value = match[2].replace(/^["']|["']$/g, '');
                // Expand variables like $ROOT_REPO_DIR
                const expandedValue = value.replace(/\$(\w+)/g, (_, varName) => process.env[varName] || '');
                process.env[key] = expandedValue;
            }
        });
    }
}

// Load environment
loadEnv();

// Force correct paths for Paperspace environment
// ComfyUI is installed in /storage/stable-diffusion-comfy
const REPO_DIR = '/storage/stable-diffusion-comfy';
const OUTPUT_DIR = path.join(REPO_DIR, 'output');
const TEMP_DIR = path.join(REPO_DIR, 'temp');
const OUTPUT_TEMP_DIR = path.join(REPO_DIR, 'output', 'temp');

// Logging function
function log(message) {
    const timestamp = new Date().toISOString().replace('T', ' ').split('.')[0];
    const logMessage = `[${timestamp}] ${message}\n`;
    console.log(logMessage.trim());
    fs.appendFileSync(LOG_FILE, logMessage);
}

// Function to get directory size
async function getDirectorySize(dir) {
    try {
        const { stdout } = await execAsync(`du -sh "${dir}" 2>/dev/null | cut -f1`);
        return stdout.trim();
    } catch {
        return 'N/A';
    }
}

// Function to clean old images from a directory
async function cleanDirectory(dir) {
    let count = 0;
    
    if (!fs.existsSync(dir)) {
        log(`Directory not found: ${dir}`);
        return count;
    }
    
    log(`Cleaning images older than ${AGE_THRESHOLD / 1000 / 60} minutes in: ${dir}`);
    
    try {
        const files = await readdirAsync(dir);
        const now = Date.now();
        
        for (const file of files) {
            const filePath = path.join(dir, file);
            
            try {
                const stats = await statAsync(filePath);
                
                if (stats.isFile() && 
                    (file.endsWith('.png') || file.endsWith('.jpg') || 
                     file.endsWith('.jpeg') || file.endsWith('.webp'))) {
                    
                    const age = now - stats.mtimeMs;
                    
                    if (age > AGE_THRESHOLD) {
                        log(`  Deleting: ${file}`);
                        await unlinkAsync(filePath);
                        count++;
                    }
                }
            } catch (err) {
                log(`  Error processing ${file}: ${err.message}`);
            }
        }
    } catch (err) {
        log(`Error reading directory ${dir}: ${err.message}`);
    }
    
    log(`  Deleted ${count} image(s) from ${dir}`);
    return count;
}

// Main cleanup function
async function performCleanup() {
    log('Starting ComfyUI image cleanup');
    
    // Show disk usage before
    log('Disk usage before cleanup:');
    log(`  Output directory: ${await getDirectorySize(OUTPUT_DIR)}`);
    log(`  Temp directory: ${await getDirectorySize(TEMP_DIR)}`);
    
    // Clean each directory
    await cleanDirectory(OUTPUT_DIR);
    await cleanDirectory(TEMP_DIR);
    await cleanDirectory(OUTPUT_TEMP_DIR);
    
    // Show disk usage after
    log('Disk usage after cleanup:');
    log(`  Output directory: ${await getDirectorySize(OUTPUT_DIR)}`);
    log(`  Temp directory: ${await getDirectorySize(TEMP_DIR)}`);
    
    log('Image cleanup completed');
}

// Main execution
log('Starting continuous image cleanup service');
log(`Will clean images older than ${AGE_THRESHOLD / 1000 / 60} minutes every ${CLEANUP_INTERVAL / 1000 / 60} minutes`);

// Perform initial cleanup
performCleanup();

// Set up the cleanup interval
setInterval(async () => {
    await performCleanup();
    log(`Waiting ${CLEANUP_INTERVAL / 1000 / 60} minutes until next cleanup...`);
}, CLEANUP_INTERVAL);

// Handle graceful shutdown
process.on('SIGTERM', () => {
    log('Image cleanup service received SIGTERM, shutting down...');
    process.exit(0);
});

process.on('SIGINT', () => {
    log('Image cleanup service received SIGINT, shutting down...');
    process.exit(0);
});

// Keep the process running
process.stdin.resume();
