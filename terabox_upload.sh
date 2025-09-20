#!/bin/bash

# TeraBox Upload Script
# Enhanced version to handle GitHub Actions and verification issues

# Configuration from environment variables
jt="${TERABOX_JSTOKEN}"        # jsToken from TeraBox
bt="${TERABOX_BDSTOKEN}"       # bdstoken from TeraBox
co="${TERABOX_COOKIE}"         # Cookie from TeraBox
rf="${TERABOX_REMOTE_FOLDER:-/rtsp-videos}"  # Remote folder path

# Fixed configuration
bo="https://www.terabox.com"
ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if required variables are set
check_config() {
    if [[ -z "$jt" || -z "$co" ]]; then
        log "ERROR: Missing required TeraBox configuration"
        log "Required environment variables:"
        log "  TERABOX_JSTOKEN"
        log "  TERABOX_COOKIE"
        log "Optional environment variables:"
        log "  TERABOX_BDSTOKEN (recommended for GitHub Actions)"
        exit 1
    fi
    
    if [[ -z "$bt" ]]; then
        log "WARNING: TERABOX_BDSTOKEN not provided - GitHub Actions may fail"
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

# Function to perform single upload attempt
upload_file_attempt() {
    local file_path="$1"
    local filename="$2"
    local filesize="$3"
    local remote_path="$4"
    local md5="$5"
    
    # Check quota with enhanced headers
    local quota_url="${bo}/api/quota?checkexpire=1&checkfree=1&app_id=250528&jsToken=${jt}"
    if [[ -n "$bt" ]]; then
        quota_url="${quota_url}&bdstoken=${bt}"
    fi
    
    local quota_response=$(curl -s "$quota_url" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Accept: application/json, text/javascript, */*; q=0.01" \
        -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7" \
        -H "Cache-Control: no-cache" \
        -H "Origin: ${bo}")
    
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
    
    # Precreate file with enhanced authentication and headers
    local precreate_data="path=${remote_path}&size=${filesize}&isdir=0&autoinit=1&target_path=${rf}&block_list=[\"${md5}\"]"
    if [[ -n "$bt" ]]; then
        precreate_data="${precreate_data}&bdstoken=${bt}"
    fi
    
    # Add timestamp to avoid caching issues
    local timestamp=$(date +%s)
    precreate_data="${precreate_data}&_=${timestamp}"
    
    local precreate_response=$(curl -s "${bo}/api/precreate" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Accept: application/json, text/javascript, */*; q=0.01" \
        -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7" \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        -H "Origin: ${bo}" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
        --data-raw "$precreate_data")
    
    if [[ $? -ne 0 ]]; then
        log "ERROR: Precreate request failed"
        return 1
    fi
    
    local uploadid=$(echo "$precreate_response" | jq -r '.uploadid // empty' 2>/dev/null)
    local return_type=$(echo "$precreate_response" | jq -r '.return_type // 0' 2>/dev/null)
    local errno=$(echo "$precreate_response" | jq -r '.errno // -1' 2>/dev/null)
    local errmsg=$(echo "$precreate_response" | jq -r '.errmsg // ""' 2>/dev/null)
    
    # Enhanced error handling for verification issues
    if [[ "$errno" == "4000023" ]]; then
        log "ERROR: Account verification required (errno: 4000023)"
        log "Error message: $errmsg"
        log "This typically means:"
        log "  1. TERABOX_BDSTOKEN is missing or invalid"
        log "  2. Tokens have expired and need to be refreshed"
        log "  3. Account needs manual verification on terabox.com"
        log "Response: $precreate_response"
        return 1
    elif [[ "$errno" != "0" && "$errno" != "-1" ]]; then
        log "ERROR: Precreate failed with errno: $errno, message: $errmsg"
        log "Response: $precreate_response"
        return 1
    fi
    
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
    
    # Upload file with enhanced headers
    local upload_url="${bo}/rest/2.0/pcs/superfile2?method=upload&app_id=250528&channel=chunlei&clienttype=0&web=1&jsToken=${jt}"
    if [[ -n "$bt" ]]; then
        upload_url="${upload_url}&bdstoken=${bt}"
    fi
    
    local upload_response=$(curl -s "$upload_url" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -H "Accept: application/json, text/javascript, */*; q=0.01" \
        -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7" \
        -H "Origin: ${bo}" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
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
    
    # Create file with enhanced authentication
    local create_data="path=${remote_path}&size=${filesize}&isdir=0&uploadid=${uploadid}&target_path=${rf}&block_list=[\"${md5_response}\"]"
    if [[ -n "$bt" ]]; then
        create_data="${create_data}&bdstoken=${bt}"
    fi
    
    local create_response=$(curl -s "${bo}/api/create" \
        -H "User-Agent: ${ua}" \
        -H "Cookie: ${co}" \
        -H "Referer: ${bo}/" \
        -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
        -H "X-Requested-With: XMLHttpRequest" \
        -H "Accept: application/json, text/javascript, */*; q=0.01" \
        -H "Accept-Language: en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7" \
        -H "Cache-Control: no-cache" \
        -H "Origin: ${bo}" \
        -H "Sec-Fetch-Dest: empty" \
        -H "Sec-Fetch-Mode: cors" \
        -H "Sec-Fetch-Site: same-origin" \
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

# Function to upload file to TeraBox with retry mechanism
upload_file() {
    local file_path="$1"
    local max_retries=3
    local retry_delay=10
    
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
    
    # Try upload with retries
    for ((i=1; i<=max_retries; i++)); do
        log "Upload attempt $i/$max_retries"
        if upload_file_attempt "$file_path" "$filename" "$filesize" "$remote_path" "$md5"; then
            return 0
        fi
        
        if [[ $i -lt $max_retries ]]; then
            log "Retrying in ${retry_delay} seconds..."
            sleep $retry_delay
            # Increase delay for next retry
            retry_delay=$((retry_delay + 5))
        fi
    done
    
    log "ERROR: All upload attempts failed for $filename"
    return 1
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