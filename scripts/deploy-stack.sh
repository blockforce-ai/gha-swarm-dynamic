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

# ---------------------------------------------------------------------------
# Migration one-shot (opt-in: application.migrations.command no clients-config).
#
# Roda a migration como container efemero, no manager, ANTES do stack deploy.
# Por que nao no CMD da imagem: com replicas > 1 o Swarm sobe N tasks e TODAS
# executariam a migration ao mesmo tempo; e com `order: start-first` o container
# novo roda migration enquanto o antigo ainda serve. TypeORM nao tem advisory
# lock entre processos, entao a corrida aparece como duplicate key em
# `migrations` — ou pior, como deploy verde com schema pela metade.
#
# A env vem do arquivo .env gerado junto do stack (mesmo VARENV/Vault), copiado
# para o manager e apagado no fim.
# ---------------------------------------------------------------------------
if [ -n "${MIGRATIONS_CMD:-}" ]; then
  NET="${NETWORK_NAME:-blockforce}"
  ENV_ARG=""
  if [ -n "${ENV_FILE:-}" ] && [ -f "$ENV_FILE" ]; then
    scp $SSH_OPTS "$ENV_FILE" "${SWARM_USER}@${SWARM_HOST}:/tmp/${STACK_NAME}.env"
    ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" "chmod 600 /tmp/${STACK_NAME}.env"
    ENV_ARG="--env-file /tmp/${STACK_NAME}.env"
  else
    echo "⚠ MIGRATIONS_CMD setado sem ENV_FILE — migration roda sem env do app"
  fi
  echo "=== Migration one-shot: ${MIGRATIONS_CMD} ==="
  ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" \
    "docker run --rm --pull always --network ${NET} ${ENV_ARG} '${EXPECTED_IMAGE}' sh -lc '${MIGRATIONS_CMD}'"
  ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" "rm -f /tmp/${STACK_NAME}.env"
  echo "✓ Migration OK"
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

# ---------------------------------------------------------------------------
# Grafana deploy annotation — best-effort, NUNCA falha o deploy.
# Marca no dashboard de uptime "o que subiu, quando, qual sha" → dá pra saber se
# o que roda é o que foi deployado e correlacionar deploy × queda.
# Token vem de /opt/gha/grafana-annotation.env no runner (GRAFANA_TOKEN + opc GRAFANA_URL).
# Sem o arquivo/token, só pula (não quebra nada).
# ---------------------------------------------------------------------------
[ -f /opt/gha/grafana-annotation.env ] && . /opt/gha/grafana-annotation.env || true
if [ -n "${GRAFANA_TOKEN:-}" ]; then
  GRAFANA_URL="${GRAFANA_URL:-https://grafana.blockforce.ai}"
  SHORT_SHA="${DEPLOY_SHA:0:8}"
  TS_MS="$(date +%s)000"
  A_SVC="${SERVICE_NAME:-$STACK_NAME}"
  BODY=$(printf '{"time":%s,"tags":["deploy","%s","%s","%s"],"text":"deploy %s %s/%s sha=%s"}' \
    "$TS_MS" "${DEPLOY_ENV:-}" "${DEPLOY_CLIENT:-}" "$A_SVC" \
    "$A_SVC" "${DEPLOY_CLIENT:-}" "${DEPLOY_ENV:-}" "${SHORT_SHA:-?}")
  if curl -sS -m 8 -X POST "${GRAFANA_URL}/api/annotations" \
       -H "Authorization: Bearer ${GRAFANA_TOKEN}" -H "Content-Type: application/json" \
       -d "$BODY" >/dev/null 2>&1; then
    echo "✓ Grafana annotation postada (sha=${SHORT_SHA:-?})"
  else
    echo "⚠ Grafana annotation falhou (ignorado)"
  fi
fi
