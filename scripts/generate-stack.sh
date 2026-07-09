#!/usr/bin/env bash
# Gera stack docker compose por (client, environment) a partir de clients-config.yml
# Requer: yq
# Envs necessárias: CLIENT, ENVIRONMENT, SERVICE_NAME, IMAGE_TAG, STACK_NAME
# Env opcional: VARENV_CONTENT (conteúdo do arquivo .env — injetado como environment)
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-.gitlab/clients-config.yml}"
GENERATED_DIR=".gitlab/generated"
STACKS_DIR="${GENERATED_DIR}/stacks"
mkdir -p "$STACKS_DIR"

: "${CLIENT:?CLIENT required}"
: "${ENVIRONMENT:?ENVIRONMENT required}"
: "${SERVICE_NAME:?SERVICE_NAME required}"
: "${IMAGE_TAG:?IMAGE_TAG required}"
: "${STACK_NAME:?STACK_NAME required}"

echo "=== Generating stack $STACK_NAME ($SERVICE_NAME / $CLIENT / $ENVIRONMENT) ==="

Q=".clients[] | select(.name == \"$CLIENT\") | .environments[] | select(.name == \"$ENVIRONMENT\")"
NETWORK_NAME=$(yq -r ".globals.network_name // \"blockforce\"" "$CONFIG_FILE")
INGRESS_HOST=$(yq -r "$Q | .ingress.host // \"\"" "$CONFIG_FILE")
APP_PORT=$(yq -r "$Q | .application.port // .ingress.port // 8080" "$CONFIG_FILE")
MEM_LIMIT=$(yq -r "$Q | .application.resources.memory_limit // \"512m\"" "$CONFIG_FILE")
REPLICAS=$(yq -r "$Q | .application.replicas // 1" "$CONFIG_FILE")

STACK_FILE="${STACKS_DIR}/${CLIENT}-${ENVIRONMENT}.yml"

# Bloco environment a partir de VARENV_CONTENT (linhas KEY=value; ignora comentários/vazias)
ENV_BLOCK=""
if [ -n "${VARENV_CONTENT:-}" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    # remove aspas externas
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    # escapa pra YAML double-quoted
    val="${val//\\/\\\\}"; val="${val//\"/\\\"}"
    ENV_BLOCK+="        - \"${key}=${val}\"
"
  done <<< "$VARENV_CONTENT"
fi

cat > "$STACK_FILE" <<EOF
version: "3.8"

services:
  app:
    image: ${IMAGE_TAG}
    networks:
      - ${NETWORK_NAME}
    environment:
$( [ -n "$ENV_BLOCK" ] && printf '%s' "$ENV_BLOCK" || echo "        []" )
    deploy:
      replicas: ${REPLICAS}
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
        failure_action: rollback
      rollback_config:
        parallelism: 1
        delay: 5s
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
      resources:
        limits:
          memory: ${MEM_LIMIT}
      labels:
        - "traefik.enable=true"
        - "traefik.docker.network=${NETWORK_NAME}"
        - "traefik.http.routers.${STACK_NAME}.entrypoints=web"
        - "traefik.http.routers.${STACK_NAME}.rule=Host(\`${INGRESS_HOST}\`)"
        - "traefik.http.services.${STACK_NAME}.loadbalancer.server.port=${APP_PORT}"

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF

echo "✓ Stack: $STACK_FILE (host=$INGRESS_HOST port=$APP_PORT replicas=$REPLICAS)"
# não faz cat (VARENV tem secrets)
