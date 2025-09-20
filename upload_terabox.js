#!/usr/bin/env node

/**
 * TeraBox Upload Script using Official Third-party Library
 * Uses terabox-upload-tool npm package
 */

const TeraboxUploader = require("terabox-upload-tool");
const fs = require('fs');
const path = require('path');

// Configuration from environment variables
const credentials = {
  ndus: process.env.TERABOX_NDUS,
  appId: process.env.TERABOX_APPID,
  uploadId: process.env.TERABOX_UPLOADID,
  jsToken: process.env.TERABOX_JSTOKEN,
  browserId: process.env.TERABOX_BROWSERID
};

const remoteFolder = process.env.TERABOX_REMOTE_FOLDER || "/rtsp-videos";

// Function to log messages with timestamp
function log(message) {
  console.log(`[${new Date().toISOString().replace('T', ' ').substr(0, 19)}] ${message}`);
}

// Validate credentials
function validateCredentials() {
  const required = ['ndus', 'appId', 'uploadId', 'jsToken', 'browserId'];
  const missing = required.filter(key => !credentials[key]);
  
  if (missing.length > 0) {
    log(`ERROR: Missing required environment variables: ${missing.map(k => 'TERABOX_' + k.toUpperCase()).join(', ')}`);
    log("Please set all required TeraBox credentials:");
    log("  TERABOX_NDUS");
    log("  TERABOX_APPID");
    log("  TERABOX_UPLOADID");
    log("  TERABOX_JSTOKEN");
    log("  TERABOX_BROWSERID");
    return false;
  }
  
  return true;
}

// Upload a single file
async function uploadFile(filePath) {
  try {
    if (!fs.existsSync(filePath)) {
      log(`ERROR: File not found: ${filePath}`);
      return false;
    }
    
    const fileName = path.basename(filePath);
    const fileSize = fs.statSync(filePath).size;
    
    log(`Uploading: ${fileName} (${(fileSize / 1024 / 1024).toFixed(2)} MB)`);
    
    // Initialize uploader
    const uploader = new TeraboxUploader(credentials);
    
    // Upload with progress tracking
    const result = await uploader.uploadFile(
      filePath,
      true,  // show progress
      remoteFolder
    );
    
    if (result && result.success) {
      log(`SUCCESS: File uploaded successfully to ${remoteFolder}/${fileName}`);
      return true;
    } else {
      log(`ERROR: Upload failed - ${result ? result.message : 'Unknown error'}`);
      return false;
    }
    
  } catch (error) {
    log(`ERROR: Upload failed with exception: ${error.message}`);
    
    // Handle specific error cases
    if (error.message.includes('authentication') || error.message.includes('credentials')) {
      log("This may indicate expired or invalid credentials");
      log("Please refresh your TeraBox session and update the environment variables");
    } else if (error.message.includes('network') || error.message.includes('timeout')) {
      log("Network error - this method may work better than direct API calls from GitHub Actions");
    }
    
    return false;
  }
}

// Main function
async function main() {
  const args = process.argv.slice(2);
  
  if (args.length === 0) {
    log("Usage: node upload_terabox.js <file1> [file2] ...");
    log("Environment variables required:");
    log("  TERABOX_NDUS, TERABOX_APPID, TERABOX_UPLOADID");
    log("  TERABOX_JSTOKEN, TERABOX_BROWSERID");
    log("  TERABOX_REMOTE_FOLDER (optional, default: /rtsp-videos)");
    process.exit(1);
  }
  
  if (!validateCredentials()) {
    process.exit(1);
  }
  
  let successCount = 0;
  const totalCount = args.length;
  
  // Process each file
  for (const filePath of args) {
    if (await uploadFile(filePath)) {
      successCount++;
    }
  }
  
  log(`Upload summary: ${successCount}/${totalCount} files uploaded successfully`);
  
  if (successCount === totalCount) {
    process.exit(0);
  } else {
    process.exit(1);
  }
}

// Handle uncaught errors
process.on('uncaughtException', (error) => {
  log(`FATAL ERROR: ${error.message}`);
  process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
  log(`UNHANDLED REJECTION: ${reason}`);
  process.exit(1);
});

// Run main function
if (require.main === module) {
  main();
}