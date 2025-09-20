#!/bin/bash
set -e


RTSP_URL="${RTSP_URL}"
output_folder="./videos"
chunk_duration="300"   # 每段 5 分钟
output_pattern="$output_folder/%Y-%m-%d-%H-%M-%S.mkv"
PID_FILE="/tmp/ffmpeg_pid.txt"

mkdir -p "$output_folder"

# 检查 RTSP URL 格式
validate_rtsp_url() {
  if [[ -z "$RTSP_URL" ]]; then
    echo "ERROR: RTSP_URL environment variable is not set"
    return 1
  fi
  
  if [[ ! "$RTSP_URL" =~ ^rtsp:// ]]; then
    echo "ERROR: RTSP_URL must start with 'rtsp://'"
    echo "Current RTSP_URL: $RTSP_URL"
    return 1
  fi
  
  echo "RTSP URL format validated: $RTSP_URL"
  return 0
}

# 检查 ffmpeg RTSP 支持 - 简化版本
check_ffmpeg_rtsp() {
  echo "Checking ffmpeg availability..."
  
  if command -v ffmpeg >/dev/null 2>&1; then
    echo "✅ ffmpeg found: $(which ffmpeg)"
    ffmpeg -version 2>/dev/null | head -1
    echo "✅ Skipping protocol check - will test RTSP directly"
    return 0
  else
    echo "❌ ERROR: ffmpeg not found"
    return 1
  fi
}

# 检查网络连接
check_network_connectivity() {
  echo "Checking network connectivity..."
  
  # 检查 Tailscale 状态
  if command -v tailscale >/dev/null 2>&1; then
    echo "Tailscale status:"
    tailscale status || echo "Failed to get Tailscale status"
    echo "Tailscale IP:"
    tailscale ip || echo "Failed to get Tailscale IP"
  else
    echo "Tailscale command not found"
  fi
  
  # 从 RTSP URL 提取主机和端口
  if [[ "$RTSP_URL" =~ rtsp://([^:/]+)(:([0-9]+))? ]]; then
    local host="${BASH_REMATCH[1]}"
    local port="${BASH_REMATCH[3]:-554}"  # RTSP 默认端口 554
    
    echo "Testing connectivity to RTSP host: $host:$port"
    
    # 使用 nc (netcat) 测试端口连接
    if command -v nc >/dev/null 2>&1; then
      if timeout 10 nc -z "$host" "$port" 2>/dev/null; then
        echo "✓ Port $port on $host is reachable"
        return 0
      else
        echo "✗ Port $port on $host is NOT reachable"
        return 1
      fi
    else
      echo "netcat not available, skipping port test"
    fi
  else
    echo "Could not parse host from RTSP URL: $RTSP_URL"
    return 1
  fi
}

# 简化的 RTSP 流检查函数
check_stream2() {
  echo "🔍 Testing RTSP stream: $RTSP_URL"
  
  # 简单的URL验证
  if [[ -z "$RTSP_URL" || ! "$RTSP_URL" =~ ^rtsp:// ]]; then
    echo "❌ Invalid RTSP URL"
    return 1
  fi
  
  # 确认ffmpeg存在
  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "❌ ffmpeg not found"
    return 1
  fi
  
  echo "🎯 Testing RTSP connection (2 second test)..."
  
  # 直接测试RTSP流，简化参数
  local output=$(timeout 15 ffmpeg -hide_banner -loglevel error \
    -rtsp_transport tcp \
    -i "$RTSP_URL" \
    -t 2 \
    -f null - 2>&1)
  local status=$?

  # 简化的错误检查
  if [[ $status -eq 0 ]]; then
    echo "✅ RTSP stream is available"
    return 0
  elif [[ $status -eq 124 ]]; then
    echo "⏰ RTSP test timed out (15s) - treating as failure"
    return 1
  else
    echo "❌ RTSP stream test failed (exit code: $status)"
    [[ -n "$output" ]] && echo "Error: $output"
    return 1
  fi
}

start_recording() {
  ffmpeg -hide_banner -loglevel error -i "$RTSP_URL" -acodec copy -vcodec copy -f segment -segment_time "$chunk_duration" -reset_timestamps 1 -strftime 1 "$output_pattern" &
  echo $! > "$PID_FILE"
}

is_ffmpeg_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p $PID > /dev/null 2>&1; then
            return 0  # ffmpeg 进程正在运行
        fi
    fi
    return 1  # 没有 ffmpeg 进程在运行
}

kill_ffmpeg() {
    if is_ffmpeg_running; then
        PID=$(cat "$PID_FILE")
        kill -9 $PID
        echo "Killed previous ffmpeg process (PID: $PID)"
        rm "$PID_FILE"
    fi
}

# 后台监控文件夹并上传到 TeraBox
upload_loop() {
  echo "启动上传进程..."
  inotifywait -m -e close_write --format '%w%f' "$output_folder" | while read FILE
  do
    echo "检测到新文件: $FILE"
    # 使用MUNFAQQIHA的TeraBox上传脚本
    if ./terabox_upload_simple.sh "$FILE"; then
      echo "上传成功，删除本地文件: $FILE"
      rm "$FILE"
    else
      echo "上传失败，保留本地文件: $FILE"
    fi
  done
}

# 启动上传后台任务
upload_loop &

# 最大重试次数
MAX_RETRIES=5
RETRY_COUNT=0

while true; do
  echo "while start check!!!!"
  if check_stream2; then
    echo "ok"
      if ! is_ffmpeg_running; then
            echo "RTSP stream available, starting recording..."
            start_recording
            RETRY_COUNT=0  # 连接成功，重试次数归零
      else
            echo "RTSP stream available, recording is already running."
      fi 
  else
    echo "error"
    kill_ffmpeg
     RETRY_COUNT=$((RETRY_COUNT + 1))  # 失败，重试次数加一

    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
      echo "达到最大重试次数 $MAX_RETRIES，退出程序"
      break  # 达到最大重试次数，退出脚本
    fi
    sleep 60  # 延迟 60 秒再重试
  fi
  sleep 5
done
