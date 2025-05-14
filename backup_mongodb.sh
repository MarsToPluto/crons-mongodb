#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# The return value of a pipeline is the status of the last command to exit with a non-zero status.
# set -o pipefail # Optional, but good practice

# --- BEGIN CONFIGURATION ---

# Docker Configuration
CONTAINER_NAME="my-mongodb"

# MongoDB Credentials & Info
MONGO_USER="uranium"
MONGO_PASSWORD="xxx"
DATABASE_NAME="cognofi-app-dev" # The database you want to back up. Leave empty to backup all accessible databases.
MONGO_AUTH_DB="cognofi-app-dev" # <<< ### VERIFY THIS IS CORRECT if Mongo auth issues arise ###

# Local Host Configuration
BACKUP_DIR="/tmp/mongodb_backups_temp" # Temporary directory on the host for the backup file

# Vultr Object Storage Configuration
# VULTR_ENDPOINT_URL is not directly used by s3cmd if configured globally, but good to keep for reference
VULTR_ENDPOINT_URL_REF="https://ewr1.vultrobjects.com"
VULTR_BUCKET="mongo-dump" # Your Vultr bucket name
VULTR_PREFIX="mongodb_backups" # Optional: subfolder within the bucket

# Logging
LOG_FILE="/var/log/mongodb_backup.log"

# --- END CONFIGURATION ---

# --- SCRIPT LOGIC ---

exec > >(tee -a "$LOG_FILE") 2>&1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILENAME_DB_PART="${DATABASE_NAME:-all_dbs}"
BACKUP_FILENAME="mongodb_backup_${BACKUP_FILENAME_DB_PART}_${TIMESTAMP}.gz"
FULL_BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILENAME}"

MONGO_URI_BASE="mongodb://${MONGO_USER}:${MONGO_PASSWORD}@127.0.0.1:27017"
MONGO_URI_PATH="/"
if [ -n "$DATABASE_NAME" ]; then
  MONGO_URI_PATH="/${DATABASE_NAME}"
fi
MONGO_URI_QUERY="?authSource=${MONGO_AUTH_DB}&directConnection=true&serverSelectionTimeoutMS=2000"
ACTUAL_MONGO_URI="${MONGO_URI_BASE}${MONGO_URI_PATH}${MONGO_URI_QUERY}"

echo "----------------------------------------------------"
echo "--- MongoDB Backup Started: ${TIMESTAMP} ---"
echo "----------------------------------------------------"
echo "Using container: $CONTAINER_NAME"
echo "Target Vultr Bucket: $VULTR_BUCKET"
echo "Vultr Endpoint (for reference): $VULTR_ENDPOINT_URL_REF"
echo "Attempting connection to: $(echo "${ACTUAL_MONGO_URI}" | sed 's#:\(.*\)@#:<password>@#')"

mkdir -p "$BACKUP_DIR"
echo "Ensured local backup directory exists: $BACKUP_DIR"

echo "Starting mongodump from container '$CONTAINER_NAME'..."
docker exec "$CONTAINER_NAME" mongodump --uri "${ACTUAL_MONGO_URI}" --archive --gzip > "$FULL_BACKUP_PATH"

LOCAL_FILE_SIZE=$(du -h "$FULL_BACKUP_PATH" | cut -f1)
if [ $? -eq 0 ]; then
  echo "mongodump completed successfully. Backup file created: $FULL_BACKUP_PATH (Size: $LOCAL_FILE_SIZE)"
else
  echo "Error: mongodump failed."
  echo "Check log file ($LOG_FILE) for details."
  exit 1
fi

if [ -f "$FULL_BACKUP_PATH" ]; then
  VULTR_S3_DEST="s3://${VULTR_BUCKET}/${VULTR_PREFIX}/${BACKUP_FILENAME}"
  echo "Uploading backup to Vultr Object Storage using s3cmd: $VULTR_S3_DEST"

  # Using s3cmd for the upload
  s3cmd put "$FULL_BACKUP_PATH" "$VULTR_S3_DEST"

  if [ $? -eq 0 ]; then
    echo "Upload to Vultr Object Storage successful using s3cmd."
    echo "Removing local backup file: $FULL_BACKUP_PATH"
    rm "$FULL_BACKUP_PATH"
    echo "Local backup file removed."
  else
    echo "Error: s3cmd put failed to Vultr Object Storage."
    echo "Check log file ($LOG_FILE) for details. Ensure s3cmd is installed and configured correctly for Vultr."
    exit 1
  fi
else
  echo "Error: Local backup file ($FULL_BACKUP_PATH) not found after mongodump."
  exit 1
fi

echo "----------------------------------------------------"
echo "--- MongoDB Backup Finished Successfully ---"
echo "----------------------------------------------------"

exit 0