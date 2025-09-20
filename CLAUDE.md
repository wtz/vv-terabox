# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an RTSP video recording system that automatically records from an RTSP stream and uploads to TeraBox. The system is designed to run on GitHub Actions with scheduled triggers during Beijing business hours (08:30-20:30, Mon-Fri).

## Key Components

- `record.sh` - Main recording script with retry logic and automatic upload
- `terabox_upload.sh` - TeraBox upload script using API authentication
- `.github/workflows/record.yml` - GitHub Actions workflow for automated recording

## Architecture

The system consists of three main components:

1. **Stream Monitoring**: Continuously checks RTSP stream availability using ffmpeg
2. **Recording Engine**: Uses ffmpeg to record video in 5-minute segments
3. **Upload System**: Uses TeraBox API with inotify to automatically upload completed video files to TeraBox

The recording script runs in a loop, checking stream availability every 5 seconds and automatically restarting recording if the stream becomes unavailable. Failed connections trigger a retry mechanism with a maximum of 5 attempts.

## Configuration Requirements

- `RTSP_URL` environment variable for the video stream
- `TERABOX_JSTOKEN` secret containing TeraBox jsToken
- `TERABOX_BDSTOKEN` secret containing TeraBox bdstoken
- `TERABOX_COOKIE` secret containing TeraBox cookie
- `TAILSCALE_AUTHKEY` for network access

### TeraBox Authentication Setup

To obtain TeraBox credentials:
1. Login to TeraBox in Chrome browser
2. Open Developer Tools (F12)
3. Go to Network tab and filter for "getinfo" requests
4. Extract the following values:
   - `jt` (jsToken) from request parameters
   - `bt` (bdstoken) from request parameters
   - Full cookie string from request headers

## Dependencies

- ffmpeg (video recording)
- curl (HTTP requests for TeraBox API)
- jq (JSON processing for TeraBox responses)
- inotify-tools (file system monitoring)
- tailscale (network connectivity)

## Common Development Tasks

Since this is a shell-based recording system, there are no traditional build/test commands. Testing is done by:

1. Manually running `./record.sh` with proper environment variables
2. Checking GitHub Actions workflow logs
3. Verifying video uploads to TeraBox

## Workflow Behavior

The GitHub Actions workflow:
- Runs on schedule (08:30 and 14:30 UTC = 16:30 and 22:30 Beijing time)
- Can be manually triggered via workflow_dispatch
- Auto-restarts itself if still within business hours
- Has a 6-hour timeout per run