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

# Expected image (used pra sanity check pós-deploy)
EXPECTED_IMAGE=$(grep -m1 -E '^\s+image:\s' "$STACK_FILE" | awk '{print $2}')

# GHCR login remoto: sem isso o swarm pode ter credencial expirada e resolver-image falha
# silenciosamente → auto-rollback pra image antiga com update reportando "completed".
if [ -n "${GHCR_TOKEN:-}" ] && [ -n "${GHCR_USER:-}" ]; then
  ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
    "echo '${GHCR_TOKEN}' | docker login ghcr.io -u '${GHCR_USER}' --password-stdin >/dev/null"
fi

# Deploy
ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
  "docker stack deploy --with-registry-auth --resolve-image always --prune -c /tmp/${STACK_NAME}.yml ${STACK_NAME} && rm -f /tmp/${STACK_NAME}.yml"

echo "✓ Deploy comando OK: $STACK_NAME"

# Sanity check: detecta rollback silencioso comparando image esperada vs running
if [ -n "$EXPECTED_IMAGE" ]; then
  sleep 8
  EXPECTED_CLEAN=$(echo "$EXPECTED_IMAGE" | sed 's|@sha256:.*||')
  RUNNING_IMAGE=$(ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
    "docker service inspect ${STACK_NAME}_app --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null | sed 's|@sha256:.*||'" || echo "")
  if [ -n "$RUNNING_IMAGE" ] && [ "$RUNNING_IMAGE" != "$EXPECTED_CLEAN" ]; then
    echo ""
    echo "❌ ROLLBACK SILENCIOSO DETECTADO"
    echo "  Esperado: $EXPECTED_CLEAN"
    echo "  Rodando:  $RUNNING_IMAGE"
    echo "  Swarm falhou pull da image nova → auto-rollback pra spec anterior."
    exit 1
  fi
fi

# Verify
ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
  "docker stack services ${STACK_NAME}"
