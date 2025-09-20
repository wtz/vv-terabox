#!/bin/bash
set -e


RTSP_URL="${RTSP_URL}"
output_folder="./videos"
chunk_duration="300"   # 每段 5 分钟
output_pattern="$output_folder/%Y-%m-%d-%H-%M-%S.mkv"
PID_FILE="/tmp/ffmpeg_pid.txt"

mkdir -p "$output_folder"

# 检查 RTSP 流是否可用的函数
check_stream2() {
  local frame_stuck_count=0
  local last_frame=0
  local current_frame=0

  # 使用 ffmpeg 拉取 RTSP 流并获取输出
  output=$(ffmpeg -hide_banner -loglevel error -timeout 5000000 -rtsp_transport tcp -i "$RTSP_URL" -t 1 -f null - 2>&1)
  STATUS=$?

  # 打印 ffmpeg 的输出，查看详细错误信息
  echo "ffmpeg output:"
  echo "$output"

  # 打印返回码，帮助调试
  echo "ffmpeg return status code: $STATUS"

  # 判断 RTSP 流是否可用
  if [[ $output == *"No route to host"* ]]; then
    echo "RTSP stream is unavailable: No route to host."
    return 1
  elif [[ $output == *"Connection refused"* ]]; then
    echo "RTSP stream is unavailable: Connection refused."
    return 1
  elif [[ $output == *"Error opening input"* ]]; then
    echo "RTSP stream is unavailable: Error opening input."
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
    # 使用 TeraBox 上传脚本
    if ./terabox_upload.sh "$FILE"; then
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
