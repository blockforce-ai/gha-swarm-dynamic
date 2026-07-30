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

# Traefik rule: host principal + additional_hosts (|| Host(extra))
TRAEFIK_RULE="Host(\`${INGRESS_HOST}\`)"
while IFS= read -r extra; do
  [ -z "$extra" ] || [ "$extra" = "null" ] && continue
  TRAEFIK_RULE="${TRAEFIK_RULE} || Host(\`${extra}\`)"
done < <(yq -r "$Q | .ingress.additional_hosts[]?" "$CONFIG_FILE" 2>/dev/null)
MEM_LIMIT=$(yq -r "$Q | .application.resources.memory_limit // \"512m\"" "$CONFIG_FILE")
REPLICAS=$(yq -r "$Q | .application.replicas // 1" "$CONFIG_FILE")

# ---------------------------------------------------------------------------
# Serviços auxiliares dedicados (redis / dgraph), opt-in por ambiente.
#
# Só são emitidos quando o ambiente declara `redis.provision: true` ou
# `dgraph.provision: true`. Nenhum clients-config existente tem essas chaves,
# então cea/arezzo/riachuelo continuam gerando exatamente o mesmo stack de antes.
#
# Nomes seguem a convenção já usada no swarm (redis-cea-dev, dgraph-alpha-cea-stg):
# `<componente>-<client>-<environment>`. Como a rede é compartilhada e externa, o
# DNS entre stacks seria `<stack>_<servico>`; o alias de rede devolve o nome curto,
# que é o que as apps esperam em REDIS_HOST / DGRAPH_HOST.
# ---------------------------------------------------------------------------
REDIS_PROVISION=$(yq -r "$Q | .redis.provision // false" "$CONFIG_FILE")
DGRAPH_PROVISION=$(yq -r "$Q | .dgraph.provision // false" "$CONFIG_FILE")

EXTRA_SERVICES=""
EXTRA_VOLUMES=""

if [ "$REDIS_PROVISION" = "true" ]; then
  REDIS_NAME="redis-${CLIENT}-${ENVIRONMENT}"
  REDIS_IMAGE=$(yq -r "$Q | .redis.image // \"redis:7-alpine\"" "$CONFIG_FILE")
  REDIS_MEM=$(yq -r "$Q | .redis.memory_limit // \"256m\"" "$CONFIG_FILE")
  EXTRA_SERVICES+="
  ${REDIS_NAME}:
    image: ${REDIS_IMAGE}
    command: redis-server --appendonly yes
    networks:
      ${NETWORK_NAME}:
        aliases:
          - ${REDIS_NAME}
    volumes:
      - ${REDIS_NAME}:/data
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          memory: ${REDIS_MEM}
"
  EXTRA_VOLUMES+="  ${REDIS_NAME}:
"
  echo "  + redis dedicado: ${REDIS_NAME}"
fi

if [ "$DGRAPH_PROVISION" = "true" ]; then
  DGRAPH_ZERO="dgraph-zero-${CLIENT}-${ENVIRONMENT}"
  DGRAPH_ALPHA="dgraph-alpha-${CLIENT}-${ENVIRONMENT}"
  DGRAPH_IMAGE=$(yq -r "$Q | .dgraph.image // \"dgraph/dgraph:v23.1.0\"" "$CONFIG_FILE")
  DGRAPH_MEM=$(yq -r "$Q | .dgraph.memory_limit // \"2g\"" "$CONFIG_FILE")
  EXTRA_SERVICES+="
  ${DGRAPH_ZERO}:
    image: ${DGRAPH_IMAGE}
    command: dgraph zero --my=${DGRAPH_ZERO}:5080 --replicas 1
    networks:
      ${NETWORK_NAME}:
        aliases:
          - ${DGRAPH_ZERO}
    volumes:
      - ${DGRAPH_ZERO}:/dgraph
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          memory: 512m

  ${DGRAPH_ALPHA}:
    image: ${DGRAPH_IMAGE}
    command: dgraph alpha --my=${DGRAPH_ALPHA}:7080 --zero=${DGRAPH_ZERO}:5080 --security whitelist=0.0.0.0/0
    networks:
      ${NETWORK_NAME}:
        aliases:
          - ${DGRAPH_ALPHA}
    volumes:
      - ${DGRAPH_ALPHA}:/dgraph
    deploy:
      replicas: 1
      restart_policy:
        condition: any
      resources:
        limits:
          memory: ${DGRAPH_MEM}
"
  EXTRA_VOLUMES+="  ${DGRAPH_ZERO}:
  ${DGRAPH_ALPHA}:
"
  echo "  + dgraph dedicado: ${DGRAPH_ZERO} + ${DGRAPH_ALPHA}"
fi

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
        failure_action: pause
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
        - "traefik.http.routers.${STACK_NAME}.rule=${TRAEFIK_RULE}"
        - "traefik.http.services.${STACK_NAME}.loadbalancer.server.port=${APP_PORT}"
${EXTRA_SERVICES}
networks:
  ${NETWORK_NAME}:
    external: true
    name: ${NETWORK_NAME}
EOF

# Bloco volumes só existe quando há serviço auxiliar (compose rejeita chave vazia).
if [ -n "$EXTRA_VOLUMES" ]; then
  { printf '\nvolumes:\n'; printf '%s' "$EXTRA_VOLUMES"; } >> "$STACK_FILE"
fi

echo "✓ Stack: $STACK_FILE (host=$INGRESS_HOST port=$APP_PORT replicas=$REPLICAS)"
# não faz cat (VARENV tem secrets)
