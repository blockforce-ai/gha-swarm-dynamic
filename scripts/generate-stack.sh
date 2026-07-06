#!/usr/bin/env bash
# Gera stack docker compose por (client, environment) a partir de clients-config.yml
# Requer: yq, envsubst
# Envs necessárias:
#   CLIENT, ENVIRONMENT, SERVICE_NAME, IMAGE_TAG
set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-.gitlab/clients-config.yml}"
GENERATED_DIR=".gitlab/generated"
STACKS_DIR="${GENERATED_DIR}/stacks"

mkdir -p "$STACKS_DIR"

: "${CLIENT:?CLIENT required}"
: "${ENVIRONMENT:?ENVIRONMENT required}"
: "${SERVICE_NAME:?SERVICE_NAME required}"
: "${IMAGE_TAG:?IMAGE_TAG required}"

echo "=== Generating stack for $SERVICE_NAME / $CLIENT / $ENVIRONMENT ==="

# Extrai vars do config
NETWORK_NAME=$(yq -r ".globals.network_name // \"blockforce\"" "$CONFIG_FILE")
INGRESS_HOST=$(yq -r ".clients[] | select(.name == \"$CLIENT\") | .environments[] | select(.name == \"$ENVIRONMENT\") | .swarm.ingress_host // \"\"" "$CONFIG_FILE")
STACK_NAME="${SERVICE_NAME}-${CLIENT}-${ENVIRONMENT}"
STACK_FILE="${STACKS_DIR}/${CLIENT}-${ENVIRONMENT}.yml"

# Gera compose stack
cat > "$STACK_FILE" <<EOF
version: "3.8"

services:
  app:
    image: ${IMAGE_TAG}
    networks:
      - ${NETWORK_NAME}
    deploy:
      replicas: 1
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
      labels:
        - "traefik.enable=true"
        - "traefik.http.routers.${STACK_NAME}.entrypoints=web"
        - "traefik.http.routers.${STACK_NAME}.rule=Host(\`${INGRESS_HOST}\`)"
        - "traefik.http.services.${STACK_NAME}.loadbalancer.server.port=8080"

networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF

echo "✓ Stack file created: $STACK_FILE"
cat "$STACK_FILE"
