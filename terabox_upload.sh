#!/bin/bash

# TeraBox Upload Script
# Based on the solution from https://gist.github.com/nis267/74c6315f6dbd24a0b8889acdd08789e6

# Configuration from environment variables
jt="${TERABOX_JSTOKEN}"        # jsToken from TeraBox
bt="${TERABOX_BDSTOKEN}"       # bdstoken from TeraBox
co="${TERABOX_COOKIE}"         # Cookie from TeraBox
rf="${TERABOX_REMOTE_FOLDER:-/rtsp-videos}"  # Remote folder path

# Fixed configuration
bo="https://www.terabox.com"
ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if required variables are set
check_config() {
    if [[ -z "$jt" || -z "$bt" || -z "$co" ]]; then
        log "ERROR: Missing required TeraBox configuration"
        log "Required environment variables:"
        log "  TERABOX_JSTOKEN"
        log "  TERABOX_BDSTOKEN"
        log "  TERABOX_COOKIE"
        exit 1
    fi
}

# Function to get file MD5
get_file_md5() {
    local file="$1"
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$file" | cut -d' ' -f1
    elif command -v md5 >/dev/null 2>&1; then
        md5 -q "$file"
    else
        log "ERROR: Neither md5sum nor md5 command found"
        exit 1
    fi
}

# Function to upload file to TeraBox
upload_file() {
    local file_path="$1"
    
    if [[ ! -f "$file_path" ]]; then
        log "ERROR: File not found: $file_path"
        return 1
    fi
    
    local filename=$(basename "$file_path")
    local filesize=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path" 2>/dev/null)
    local remote_path="${rf}/${filename}"
    
    log "Uploading: $filename ($(numfmt --to=iec-i --suffix=B $filesize))"
    
    # Get file MD5
    local md5=$(get_file_md5 "$file_path")
    log "File MD5: $md5"
    
    # Check quota
    local quota_response=$(curl -s "${bo}/api/quota?checkexpire=1&checkfree=1&app_id=250528&jsToken=${jt}" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Failed to check quota"
        return 1
    fi
    
    # Parse quota info
    local total=$(echo "$quota_response" | jq -r '.total // 0' 2>/dev/null)
    local used=$(echo "$quota_response" | jq -r '.used // 0' 2>/dev/null)
    
    if [[ -n "$total" && -n "$used" && "$total" -gt 0 ]]; then
        local available=$((total - used))
        if [[ $available -lt $filesize ]]; then
            log "ERROR: Insufficient quota. Available: $(numfmt --to=iec-i --suffix=B $available), Required: $(numfmt --to=iec-i --suffix=B $filesize)"
            return 1
        fi
        log "Quota OK. Available: $(numfmt --to=iec-i --suffix=B $available)"
    fi
    
    # Precreate file
    local precreate_data="path=${remote_path}&size=${filesize}&isdir=0&autoinit=1&target_path=${rf}&block_list=[\"${md5}\"]"
    local precreate_response=$(curl -s "${bo}/api/precreate" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        --data-raw "$precreate_data")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Precreate request failed"
        return 1
    fi
    
    local uploadid=$(echo "$precreate_response" | jq -r '.uploadid // empty' 2>/dev/null)
    local return_type=$(echo "$precreate_response" | jq -r '.return_type // 0' 2>/dev/null)
    
    if [[ "$return_type" == "2" ]]; then
        log "File already exists, rapid upload successful"
        return 0
    fi
    
    if [[ -z "$uploadid" ]]; then
        log "ERROR: Failed to get upload ID from precreate response"
        log "Response: $precreate_response"
        return 1
    fi
    
    log "Upload ID: $uploadid"
    
    # Upload file
    local upload_response=$(curl -s "${bo}/rest/2.0/pcs/superfile2?method=upload&app_id=250528&channel=chunlei&clienttype=0&web=1&jsToken=${jt}" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -F "file=@${file_path};filename=${filename}" \
        --progress-bar)
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: File upload failed"
        return 1
    fi
    
    local md5_response=$(echo "$upload_response" | jq -r '.md5 // empty' 2>/dev/null)
    if [[ -z "$md5_response" ]]; then
        log "ERROR: Upload response missing MD5"
        log "Response: $upload_response"
        return 1
    fi
    
    log "Upload completed, MD5: $md5_response"
    
    # Create file
    local create_data="path=${remote_path}&size=${filesize}&isdir=0&uploadid=${uploadid}&target_path=${rf}&block_list=[\"${md5_response}\"]"
    local create_response=$(curl -s "${bo}/api/create" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        --data-raw "$create_data")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Create file request failed"
        return 1
    fi
    
    local errno=$(echo "$create_response" | jq -r '.errno // -1' 2>/dev/null)
    if [[ "$errno" == "0" ]]; then
        log "SUCCESS: File uploaded successfully to $remote_path"
        return 0
    else
        log "ERROR: Create file failed with errno: $errno"
        log "Response: $create_response"
        return 1
    fi
}

# Main function
main() {
    check_config
    
    if [[ $# -eq 0 ]]; then
        log "Usage: $0 <file1> [file2] ..."
        exit 1
    fi
    
    local success_count=0
    local total_count=$#
    
    for file in "$@"; do
        if upload_file "$file"; then
            success_count=$((success_count + 1))
        else
            log "Failed to upload: $file"
        fi
    done
    
    log "Upload summary: $success_count/$total_count files uploaded successfully"
    
    if [[ $success_count -eq $total_count ]]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function with all arguments
main "$@"