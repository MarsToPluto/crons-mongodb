#!/bin/bash
# init-replica.sh

set -e # Exit immediately if a command exits with a non-zero status

# Use environment variables for credentials if they are set for this script's container
# Otherwise, it assumes local connection without auth for initial setup if mongo1 hasn't fully secured yet.
MONGOSH_HOST="mongo1"
MONGOSH_PORT="27017"
REPLICA_SET_NAME="rs0"

if [ -n "$MONGO_INITDB_ROOT_USERNAME" ] && [ -n "$MONGO_INITDB_ROOT_PASSWORD" ]; then
  MONGOSH_AUTH_CMD="mongosh --host ${MONGOSH_HOST} --port ${MONGOSH_PORT} -u ${MONGO_INITDB_ROOT_USERNAME} -p '${MONGO_INITDB_ROOT_PASSWORD}' --authenticationDatabase admin --quiet"
  MONGOSH_NO_AUTH_CMD="mongosh --host ${MONGOSH_HOST} --port ${MONGOSH_PORT} --quiet" # For initial ping/status before auth is enforced
else
  MONGOSH_AUTH_CMD="mongosh --host ${MONGOSH_HOST} --port ${MONGOSH_PORT} --quiet"
  MONGOSH_NO_AUTH_CMD=$MONGOSH_AUTH_CMD
fi

echo "Waiting for ${MONGOSH_HOST}:${MONGOSH_PORT} to be ready..."
# Loop until mongod is responsive or a timeout (e.g., 60 seconds)
COUNTER=0
MAX_RETRIES=30 # 30 * 2 seconds = 60 seconds timeout
until $MONGOSH_NO_AUTH_CMD --eval "db.adminCommand('ping')" &>/dev/null; do
    echo -n "."
    sleep 2
    COUNTER=$((COUNTER + 1))
    if [ $COUNTER -ge $MAX_RETRIES ]; then
        echo "Timeout waiting for ${MONGOSH_HOST} to start."
        exit 1
    fi
done
echo ""
echo "${MONGOSH_HOST} is ready."

# Check if replica set is already initiated by trying to get status
# If rs.status() throws an error (e.g., "not running with --replSet"), it's not initiated.
# If it returns a status object, it might be initiated.
ALREADY_INITIATED=$($MONGOSH_AUTH_CMD --eval "try { rs.status().ok } catch (e) { print(0) }" | tail -n1 | tr -d '\r')

if [ "$ALREADY_INITIATED" == "1" ]; then
    echo "Replica set '${REPLICA_SET_NAME}' already initiated."
    CURRENT_PRIMARY=$($MONGOSH_AUTH_CMD --eval "rs.status().members.find(m => m.stateStr === 'PRIMARY')?.name" | tail -n1 | tr -d '\r' | sed 's/"//g')
    if [ -n "$CURRENT_PRIMARY" ]; then
        echo "Current primary: $CURRENT_PRIMARY"
    else
        echo "No primary found, but replica set is configured. Check status manually."
    fi
    exit 0
fi

echo "Initiating replica set '${REPLICA_SET_NAME}'..."
# Note: priority 3 for mongo1 to make it more likely to be primary initially.
# Adjust priorities as needed.
INITIATE_CMD="rs.initiate({
  _id: \"${REPLICA_SET_NAME}\",
  members: [
    { _id: 0, host: \"mongo1:${MONGOSH_PORT}\", priority: 3 },
    { _id: 1, host: \"mongo2:${MONGOSH_PORT}\", priority: 2 },
    { _id: 2, host: \"mongo3:${MONGOSH_PORT}\", priority: 1 }
  ]
})"

$MONGOSH_AUTH_CMD --eval "${INITIATE_CMD}"

echo "Waiting for replica set to elect a primary..."
COUNTER=0
until $MONGOSH_AUTH_CMD --eval "rs.status().members.some(m => m.stateStr === 'PRIMARY')" &>/dev/null; do
    echo -n "."
    sleep 2
    COUNTER=$((COUNTER + 1))
    if [ $COUNTER -ge $MAX_RETRIES ]; then
        echo "Timeout waiting for primary to be elected."
        # Optionally print rs.status() for debugging
        $MONGOSH_AUTH_CMD --eval "rs.status()"
        exit 1
    fi
done
echo ""
echo "Replica set '${REPLICA_SET_NAME}' is up and has a primary."

echo "Replica set status:"
$MONGOSH_AUTH_CMD --eval "rs.status()"

exit 0