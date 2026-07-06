#!/usr/bin/env bash
# Deploy docker stack no swarm manager via SSH
# Envs necessárias: SWARM_HOST, SWARM_USER, SWARM_SSH_KEY, STACK_NAME, STACK_FILE
set -euo pipefail

: "${SWARM_HOST:?SWARM_HOST required}"
: "${SWARM_USER:?SWARM_USER required}"
: "${SWARM_SSH_KEY:?SWARM_SSH_KEY required}"
: "${STACK_NAME:?STACK_NAME required}"
: "${STACK_FILE:?STACK_FILE required}"

if [ ! -f "$STACK_FILE" ]; then
  echo "ERROR: Stack file not found: $STACK_FILE"; exit 1
fi

echo "=== Deploy $STACK_NAME → $SWARM_USER@$SWARM_HOST ==="

# Write SSH key temp
KEY_FILE="$(mktemp)"
chmod 600 "$KEY_FILE"
printf '%s\n' "$SWARM_SSH_KEY" > "$KEY_FILE"
trap 'rm -f "$KEY_FILE"' EXIT

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

# Upload stack file
scp $SSH_OPTS "$STACK_FILE" "${SWARM_USER}@${SWARM_HOST}:/tmp/${STACK_NAME}.yml"

# Deploy
ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
  "docker stack deploy --with-registry-auth --prune -c /tmp/${STACK_NAME}.yml ${STACK_NAME} && rm -f /tmp/${STACK_NAME}.yml"

echo "✓ Deploy complete: $STACK_NAME"

# Verify
ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
  "sleep 10; docker stack services ${STACK_NAME}"
