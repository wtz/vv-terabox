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

# 检查 ffmpeg RTSP 支持
check_ffmpeg_rtsp() {
  echo "Checking ffmpeg RTSP support..."
  
  # 检查ffmpeg版本和编译信息
  echo "FFmpeg version info:"
  ffmpeg -version 2>/dev/null | head -3
  
  # 获取完整的协议列表
  echo "Getting protocol list..."
  local protocol_output=$(ffmpeg -protocols 2>/dev/null)
  
  # 显示输入协议部分
  echo "Input protocols:"
  echo "$protocol_output" | sed -n '/Input:/,/Output:/p' | head -10
  
  # 检查RTSP协议支持（检查输入协议部分）
  if echo "$protocol_output" | sed -n '/Input:/,/Output:/p' | grep -q "rtsp"; then
    echo "✅ ffmpeg RTSP input support confirmed"
    return 0
  else
    echo "❌ WARNING: ffmpeg may not support RTSP protocol"
    echo ""
    echo "Let's try a different check - test RTSP directly with a timeout..."
    
    # 尝试直接测试RTSP（但不依赖于协议列表）
    # 这里我们跳过严格检查，让实际的RTSP测试来验证
    echo "⚠️  Skipping protocol check, will test RTSP directly in stream test"
    return 0
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

# 检查 RTSP 流是否可用的函数
check_stream2() {
  # 首先验证 URL 格式和 ffmpeg 支持
  if ! validate_rtsp_url; then
    return 1
  fi
  
  if ! check_ffmpeg_rtsp; then
    return 1
  fi
  
  # 检查网络连接
  if ! check_network_connectivity; then
    echo "Network connectivity test failed"
  fi

  # 使用 ffmpeg 拉取 RTSP 流并获取输出，增加更多调试参数
  echo "Testing RTSP connection to: $RTSP_URL"
  echo "Using enhanced connection parameters..."
  
  # 使用更短的超时时间进行快速测试
  output=$(ffmpeg -hide_banner -loglevel info \
    -rtsp_transport tcp \
    -rtsp_flags prefer_tcp \
    -stimeout 10000000 \
    -timeout 10000000 \
    -i "$RTSP_URL" \
    -t 2 \
    -f null - 2>&1)
  STATUS=$?

  # 打印 ffmpeg 的输出，查看详细错误信息
  echo "ffmpeg output:"
  echo "$output"

  # 打印返回码，帮助调试
  echo "ffmpeg return status code: $STATUS"

  # 判断 RTSP 流是否可用
  if [[ $output == *"Protocol not found"* ]]; then
    echo "RTSP stream is unavailable: Protocol not found (ffmpeg missing RTSP support)."
    return 1
  elif [[ $output == *"Connection timed out"* ]]; then
    echo "RTSP stream is unavailable: Connection timed out (network issue)."
    return 1
  elif [[ $output == *"No route to host"* ]]; then
    echo "RTSP stream is unavailable: No route to host."
    return 1
  elif [[ $output == *"Connection refused"* ]]; then
    echo "RTSP stream is unavailable: Connection refused."
    return 1
  elif [[ $output == *"Error opening input"* ]]; then
    echo "RTSP stream is unavailable: Error opening input."
    return 1
  elif [[ $output == *"401 Unauthorized"* ]]; then
    echo "RTSP stream is unavailable: Authentication required."
    return 1
  elif [ $STATUS -eq 0 ]; then
    echo "RTSP stream is available."
    return 0 # 返回 0 表示流可用
  else
    echo "Failed to retrieve RTSP stream. Status code: $STATUS"
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
