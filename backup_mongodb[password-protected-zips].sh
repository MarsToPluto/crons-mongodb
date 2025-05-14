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
DATABASE_NAME="cognofi-app-dev" # Database to back up. Leave empty to dump all accessible databases.
MONGO_AUTH_DB="cognofi-app-dev" # The DB where MONGO_USER is defined.

# Backup Password for ZIP
ZIP_PASSWORD="XXX" # <<< ### CHOOSE A STRONG PASSWORD ###

# Local Host Configuration
BACKUP_DIR_HOST="/tmp/mongodb_backups_temp" # Temporary directory on the HOST for the final ZIP file

# Vultr Object Storage Configuration
VULTR_ENDPOINT_URL_REF="https://ewr1.vultrobjects.com" # For reference, s3cmd uses its own config
VULTR_BUCKET="mongo-dump" # Your Vultr bucket name
VULTR_PREFIX="mongodb_backups" # Optional: subfolder within the bucket

# Logging
LOG_FILE="/var/log/mongodb_backup.log"

# Paths INSIDE the container for temporary dump and zip
CONTAINER_BACKUP_BASE_PATH="/tmp/backup_mongo_data"

# --- END CONFIGURATION ---

# --- SCRIPT LOGIC ---

# Redirect all output (stdout and stderr) to console and log file
exec > >(tee -a "$LOG_FILE") 2>&1

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
DB_NAME_PART_FOR_FILENAME="${DATABASE_NAME:-all_dbs}" # Filename part based on DB_NAME

# Define names for the dump directory (inside container) and the final ZIP file
DUMP_DIR_NAME_IN_CONTAINER="mongodump_${DB_NAME_PART_FOR_FILENAME}_${TIMESTAMP}"
ZIP_FILENAME="mongodb_backup_${DB_NAME_PART_FOR_FILENAME}_${TIMESTAMP}.zip"

# Full paths for dump and zip INSIDE the container
FULL_DUMP_PATH_IN_CONTAINER="${CONTAINER_BACKUP_BASE_PATH}/${DUMP_DIR_NAME_IN_CONTAINER}"
FULL_ZIP_PATH_IN_CONTAINER="${CONTAINER_BACKUP_BASE_PATH}/${ZIP_FILENAME}"

# Full path for the final ZIP file on the HOST machine
FULL_BACKUP_PATH_ON_HOST="${BACKUP_DIR_HOST}/${ZIP_FILENAME}"

# Construct mongodump connection URI
MONGO_URI_BASE="mongodb://${MONGO_USER}:${MONGO_PASSWORD}@127.0.0.1:27017"
MONGO_URI_PATH="/"
# If DATABASE_NAME is set, add it to the URI path to target that specific database for the dump.
# mongodump with --uri and a database in the path only dumps that database.
if [ -n "$DATABASE_NAME" ]; then
  MONGO_URI_PATH="/${DATABASE_NAME}"
fi
MONGO_URI_QUERY="?authSource=${MONGO_AUTH_DB}&directConnection=true&serverSelectionTimeoutMS=2000"
ACTUAL_MONGO_URI="${MONGO_URI_BASE}${MONGO_URI_PATH}${MONGO_URI_QUERY}"

echo "----------------------------------------------------"
echo "--- MongoDB Password-Protected Backup Started: ${TIMESTAMP} ---"
echo "----------------------------------------------------"
echo "Using container: $CONTAINER_NAME"
echo "Target Vultr Bucket: $VULTR_BUCKET"
echo "Vultr Endpoint (for reference): $VULTR_ENDPOINT_URL_REF"
echo "Attempting MongoDB connection to: $(echo "${ACTUAL_MONGO_URI}" | sed 's#:\(.*\)@#:<password>@#')"
echo "Backup will be password-protected using ZIP_PASSWORD."
echo "IMPORTANT: Ensure 'zip' utility is installed inside container '${CONTAINER_NAME}'."

# 1. Ensure local host backup directory exists
mkdir -p "$BACKUP_DIR_HOST"
echo "[HOST] Ensured local backup directory exists: $BACKUP_DIR_HOST"

# 2. Perform mongodump to a directory and then zip it with a password, all INSIDE the container
echo "[CONTAINER] Starting backup process inside container '$CONTAINER_NAME'..."

# Construct the mongodump command to output to a directory inside the container.
# The --uri handles specifying the database if it's in the path.
# If DATABASE_NAME is set but not in the URI (e.g. if MONGO_URI_PATH was just "/"),
# you might add --db "${DATABASE_NAME}" but with current URI logic, it's covered.
MONGODUMP_CMD_IN_CONTAINER="mongodump --uri \"${ACTUAL_MONGO_URI}\" --out \"${FULL_DUMP_PATH_IN_CONTAINER}\""

# Prepare shell commands to be executed inside the container
# It's crucial that ZIP_PASSWORD doesn't contain characters that would break the shell command string itself.
# For simple alphanumeric passwords, this is usually fine.
COMMANDS_IN_CONTAINER="
    set -e; \
    echo '[CONTAINER] Creating base backup directory ${CONTAINER_BACKUP_BASE_PATH}...'; \
    mkdir -p '${CONTAINER_BACKUP_BASE_PATH}'; \
    echo '[CONTAINER] Running mongodump to ${FULL_DUMP_PATH_IN_CONTAINER}...'; \
    ${MONGODUMP_CMD_IN_CONTAINER}; \
    echo '[CONTAINER] mongodump finished. Zipping dump directory with password...'; \
    cd '${CONTAINER_BACKUP_BASE_PATH}'; \
    zip -qr -P '${ZIP_PASSWORD}' '${ZIP_FILENAME}' '${DUMP_DIR_NAME_IN_CONTAINER}'; \
    echo '[CONTAINER] Zipping complete. Removing raw dump directory ${DUMP_DIR_NAME_IN_CONTAINER}...'; \
    rm -rf '${DUMP_DIR_NAME_IN_CONTAINER}'; \
    echo '[CONTAINER] Backup and zip complete. ZIP file is ${FULL_ZIP_PATH_IN_CONTAINER}'
"
docker exec "$CONTAINER_NAME" bash -c "$COMMANDS_IN_CONTAINER"
echo "[CONTAINER] Backup and zip process inside container completed."

# 3. Copy the generated password-protected ZIP file from the container to the host
echo "[HOST] Copying ZIP file from container to host: ${CONTAINER_NAME}:${FULL_ZIP_PATH_IN_CONTAINER} -> ${FULL_BACKUP_PATH_ON_HOST}"
docker cp "${CONTAINER_NAME}:${FULL_ZIP_PATH_IN_CONTAINER}" "${FULL_BACKUP_PATH_ON_HOST}"
echo "[HOST] ZIP file copied."

# 4. Clean up the ZIP file from INSIDE the container (it's now on the host)
echo "[CONTAINER] Cleaning up ZIP file inside container: ${FULL_ZIP_PATH_IN_CONTAINER}"
docker exec "$CONTAINER_NAME" rm -f "${FULL_ZIP_PATH_IN_CONTAINER}"
echo "[CONTAINER] ZIP file removed from container."

# 5. Upload the password-protected ZIP file from the host to Vultr Object Storage
LOCAL_FILE_SIZE_ON_HOST=$(du -sh "$FULL_BACKUP_PATH_ON_HOST" | cut -f1)
echo "[HOST] Password-protected backup file available at: $FULL_BACKUP_PATH_ON_HOST (Size: $LOCAL_FILE_SIZE_ON_HOST)"

if [ -f "$FULL_BACKUP_PATH_ON_HOST" ]; then
  VULTR_S3_DEST="s3://${VULTR_BUCKET}/${VULTR_PREFIX}/${ZIP_FILENAME}"
  echo "[VULTR] Uploading backup to Vultr Object Storage using s3cmd: $VULTR_S3_DEST"

  # Using s3cmd for the upload (ensure s3cmd is configured for Vultr)
  s3cmd put "$FULL_BACKUP_PATH_ON_HOST" "$VULTR_S3_DEST"

  if [ $? -eq 0 ]; then
    echo "[VULTR] Upload to Vultr Object Storage successful using s3cmd."
    echo "[HOST] Removing local backup file: $FULL_BACKUP_PATH_ON_HOST"
    rm "$FULL_BACKUP_PATH_ON_HOST"
    echo "[HOST] Local backup file removed."
  else
    echo "[VULTR] Error: s3cmd put failed to Vultr Object Storage."
    echo "Check log file ($LOG_FILE) for details. Ensure s3cmd is installed and configured correctly for Vultr."
    exit 1
  fi
else
  echo "[HOST] Error: Local backup file ($FULL_BACKUP_PATH_ON_HOST) not found after attempting copy from container."
  exit 1
fi

echo "----------------------------------------------------"
echo "--- MongoDB Password-Protected Backup Finished Successfully ---"
echo "----------------------------------------------------"

exit 0