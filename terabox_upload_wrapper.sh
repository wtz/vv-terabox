#!/bin/bash

# TeraBox Upload Wrapper Script
# Tries Node.js official library first, falls back to custom implementation

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check if file exists
if [[ $# -eq 0 ]]; then
    log "Usage: $0 <file1> [file2] ..."
    exit 1
fi

# Check if Node.js is available
if command -v node >/dev/null 2>&1; then
    # Check if package.json and node_modules exist
    if [[ -f "package.json" && -d "node_modules" ]]; then
        log "Using Node.js TeraBox uploader (official third-party library)"
        node upload_terabox.js "$@"
        exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            log "Node.js upload successful"
            exit 0
        else
            log "Node.js upload failed, falling back to custom implementation"
        fi
    else
        log "Node.js dependencies not installed, falling back to custom implementation"
    fi
else
    log "Node.js not available, using custom implementation"
fi

# Fallback to custom bash implementation
log "Using custom TeraBox upload implementation"
./terabox_upload.sh "$@"