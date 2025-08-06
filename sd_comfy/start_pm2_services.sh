#!/bin/bash

# Robust PM2 service startup script with verification and retry logic
# This ensures PM2 services start reliably even after system reboots

echo "=== Starting PM2 Services for ComfyUI ==="
echo "Time: $(date)"

# Set PM2 home to persistent location since /root gets wiped on reboot
export PM2_HOME=/notebooks/.pm2_config
mkdir -p $PM2_HOME

# Make PM2_HOME permanent for all future shell sessions
if ! grep -q "PM2_HOME=/notebooks/.pm2_config" /root/.bashrc 2>/dev/null; then
    echo "export PM2_HOME=/notebooks/.pm2_config" >> /root/.bashrc
    echo "Added PM2_HOME to .bashrc"
fi
if ! grep -q "PM2_HOME=/notebooks/.pm2_config" /root/.profile 2>/dev/null; then
    echo "export PM2_HOME=/notebooks/.pm2_config" >> /root/.profile
    echo "Added PM2_HOME to .profile"
fi

# Also add to system-wide environment for all processes
if ! grep -q "PM2_HOME=/notebooks/.pm2_config" /etc/environment 2>/dev/null; then
    echo "PM2_HOME=/notebooks/.pm2_config" >> /etc/environment
    echo "Added PM2_HOME to /etc/environment"
fi

# Create a PM2 config file that sets the home directory permanently
mkdir -p /etc/pm2
echo "PM2_HOME=/notebooks/.pm2_config" > /etc/pm2/pm2.conf

# Set up PM2 startup script to always use the correct home
cat > /usr/local/bin/pm2-wrapper << 'EOF'
#!/bin/bash
export PM2_HOME=/notebooks/.pm2_config
exec /usr/bin/pm2 "$@"
EOF
chmod +x /usr/local/bin/pm2-wrapper

# Create alias in bashrc for pm2 to always use correct home
if ! grep -q "alias pm2=" /root/.bashrc 2>/dev/null; then
    echo "alias pm2='PM2_HOME=/notebooks/.pm2_config pm2'" >> /root/.bashrc
    echo "Added PM2 alias to .bashrc"
fi

# Function to verify a PM2 service is actually running
verify_pm2_service() {
    local service_name="$1"
    local script_path="$2"
    local max_attempts=5
    local attempt=1
    
    echo "Verifying $service_name..."
    
    while [ $attempt -le $max_attempts ]; do
        echo "  Attempt $attempt/$max_attempts..."
        
        # Check if service exists and is online in PM2
        if pm2 list 2>/dev/null | grep -q "$service_name.*online"; then
            # Double-check by looking at the process details
            if pm2 describe "$service_name" 2>/dev/null | grep -q "status.*online"; then
                # Final check - ensure the node process is actually running
                local pid=$(pm2 describe "$service_name" 2>/dev/null | grep "pid :" | awk '{print $3}')
                if [ -n "$pid" ] && ps -p "$pid" > /dev/null 2>&1; then
                    echo "  ✓ $service_name is running (PID: $pid)"
                    return 0
                fi
            fi
        fi
        
        echo "  ⚠ $service_name not running properly, attempting to start..."
        
        # Stop/delete if it exists in any state
        pm2 stop "$service_name" > /dev/null 2>&1 || true
        pm2 delete "$service_name" > /dev/null 2>&1 || true
        sleep 2
        
        # Start the service with explicit settings
        echo "  Starting $service_name..."
        pm2 start "$script_path" \
            --name "$service_name" \
            --cwd /notebooks/sd_comfy \
            --interpreter node \
            --max-memory-restart 500M \
            --time \
            --merge-logs \
            --log-date-format "YYYY-MM-DD HH:mm:ss" \
            --restart-delay 5000 \
            --kill-timeout 3000
        
        # Wait for service to stabilize
        echo "  Waiting for service to stabilize..."
        sleep 5
        
        # Check if it started successfully
        if pm2 list 2>/dev/null | grep -q "$service_name.*online"; then
            # Verify it's actually working by checking logs
            sleep 2
            if pm2 logs "$service_name" --lines 5 --nostream 2>&1 | grep -q "started\|Starting\|Cleaning\|queue\|cleanup service\|auto-restart service\|cleanup completed\|continuous.*cleanup"; then
                echo "  ✓ $service_name started and functioning"
                return 0
            else
                echo "  ⚠ $service_name started but may not be functioning properly"
            fi
        fi
        
        attempt=$((attempt + 1))
        
        if [ $attempt -le $max_attempts ]; then
            echo "  Retrying in 5 seconds..."
            sleep 5
        fi
    done
    
    echo "  ✗ Failed to start $service_name after $max_attempts attempts"
    return 1
}

# Change to ComfyUI directory
cd /notebooks/sd_comfy

# Ensure scripts are executable
chmod +x auto_restart.js image_cleanup.js

# Check if ComfyUI instances are running - if so, be gentle with PM2 cleanup
COMFYUI_RUNNING=$(ps aux | grep "python main.py" | grep -v grep | wc -l)
if [ "$COMFYUI_RUNNING" -gt 0 ]; then
    echo "Found $COMFYUI_RUNNING running ComfyUI instances - performing gentle PM2 cleanup..."
    # Only stop our specific services, don't kill the entire PM2 daemon
    pm2 stop comfyui-auto-restart > /dev/null 2>&1 || true
    pm2 stop comfyui-image-cleanup > /dev/null 2>&1 || true
    pm2 delete comfyui-auto-restart > /dev/null 2>&1 || true
    pm2 delete comfyui-image-cleanup > /dev/null 2>&1 || true
    sleep 2
else
    echo "No ComfyUI instances detected - performing full PM2 cleanup..."
    pm2 kill > /dev/null 2>&1 || true
    rm -rf /tmp/pm2* > /dev/null 2>&1 || true
    sleep 3
fi

# Start PM2 daemon with persistent home
echo "Starting PM2 daemon with persistent home at $PM2_HOME..."
pm2 ping > /dev/null 2>&1
sleep 2

# Try to resurrect saved processes first
echo "Attempting to resurrect saved PM2 processes..."
pm2 resurrect > /dev/null 2>&1 || echo "  No saved processes to resurrect"
sleep 2

# Check what's running
echo "Current PM2 status:"
pm2 list

# Start and verify each service
echo ""
echo "Starting/verifying PM2 services..."
echo "=================================="

# Track overall success
ALL_SERVICES_OK=true

# Auto-restart service
echo "1. Auto-restart service:"
if verify_pm2_service "comfyui-auto-restart" "/notebooks/sd_comfy/auto_restart.js"; then
    echo "  ✓ Auto-restart service setup complete"
else
    echo "  ✗ WARNING: Auto-restart service failed to start!"
    ALL_SERVICES_OK=false
fi

echo ""

# Image cleanup service
echo "2. Image cleanup service:"
if verify_pm2_service "comfyui-image-cleanup" "/notebooks/sd_comfy/image_cleanup.js"; then
    echo "  ✓ Image cleanup service setup complete"
else
    echo "  ✗ WARNING: Image cleanup service failed to start!"
    ALL_SERVICES_OK=false
fi

# Save PM2 process list
echo ""
echo "Saving PM2 configuration..."
pm2 save --force

# Install log rotation if not already installed
echo "Setting up log rotation..."
pm2 install pm2-logrotate > /dev/null 2>&1 || echo "  Log rotation already installed"
pm2 set pm2-logrotate:max_size 50M > /dev/null 2>&1
pm2 set pm2-logrotate:retain 5 > /dev/null 2>&1
pm2 set pm2-logrotate:compress true > /dev/null 2>&1

# Final status report
echo ""
echo "==================================="
echo "Final PM2 Status:"
echo "==================================="
pm2 list

echo ""
echo "==================================="
echo "Service Verification:"
echo "==================================="

# Detailed verification
if pm2 list 2>/dev/null | grep -q "comfyui-auto-restart.*online"; then
    echo "✓ Auto-restart: ONLINE"
    RECENT_LOG=$(pm2 logs comfyui-auto-restart --lines 1 --nostream 2>&1 | tail -1)
    echo "  Last log: $RECENT_LOG"
else
    echo "✗ Auto-restart: OFFLINE"
fi

if pm2 list 2>/dev/null | grep -q "comfyui-image-cleanup.*online"; then
    echo "✓ Image cleanup: ONLINE"
    RECENT_LOG=$(pm2 logs comfyui-image-cleanup --lines 1 --nostream 2>&1 | tail -1)
    echo "  Last log: $RECENT_LOG"
else
    echo "✗ Image cleanup: OFFLINE"
fi

echo "==================================="

if [ "$ALL_SERVICES_OK" = true ]; then
    echo "✓ All PM2 services started successfully!"
else
    echo "⚠ WARNING: Some PM2 services failed to start!"
    echo "Check logs with: pm2 logs [service-name]"
fi

echo "PM2 home directory: $PM2_HOME"
echo "=== PM2 Service Startup Complete ==="
