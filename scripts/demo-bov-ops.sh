#!/usr/bin/env bash
# Operações de infra do ambiente de demonstração `demo-bov` (cliente `bov`, env `demo`)
# Envs necessárias: ACTION, SWARM_HOST, SWARM_USER, SWARM_SSH_KEY
# Envs opcionais: DB_PASSWORD (ações de banco), CONFIRM (ações destrutivas)
#
# O swarm manager só é alcançável por SSH com a chave dos secrets da organização,
# então toda operação passa pelos runners self-hosted. Nenhuma ação aqui toca o
# ambiente `cea-dev`: todo recurso criado tem sufixo `-bov` ou `bov-demo`.
set -euo pipefail

: "${ACTION:?ACTION required}"
: "${SWARM_HOST:?SWARM_HOST required}"
: "${SWARM_USER:?SWARM_USER required}"
: "${SWARM_SSH_KEY:?SWARM_SSH_KEY required}"

# Os 5 bancos do ambiente. `DB_SCHEMA` das apps é o NOME DO BANCO
# (typeorm.config.ts: `database: configs.env.DB_SCHEMA`), então o isolamento é por
# banco, não por schema. Sem eles a migration de boot falha e o container entra em
# crash-loop.
DBS="tenant-api-bov traceability-api-bov traceability-platform-api-bov dpp-api-bov compliance360-api-bov"

# Write SSH key temp (mesmo padrão do deploy-stack.sh)
KEY_FILE="$(mktemp)"
chmod 600 "$KEY_FILE"
printf '%s\n' "$SWARM_SSH_KEY" > "$KEY_FILE"
trap 'rm -f "$KEY_FILE"' EXIT

SSH_OPTS="-i $KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15"

swarm() { ssh $SSH_OPTS "${SWARM_USER}@${SWARM_HOST}" "$@"; }

find_pg() { swarm "docker ps --filter 'name=postgres' --format '{{.Names}}' | head -1"; }

psql_do() {
  : "${DB_PASSWORD:?DB_PASSWORD required para ações de banco}"
  local sql="$1" pg
  pg="$(find_pg)"
  if [ -z "$pg" ]; then
    echo "ERROR: container do Postgres não encontrado no manager"; exit 1
  fi
  swarm "docker exec -e PGPASSWORD='${DB_PASSWORD}' '$pg' psql -U postgres -tAc \"$sql\""
}

require_confirm() {
  [ "${CONFIRM:-}" = "DESTRUIR" ] || { echo "ERROR: ação destrutiva exige CONFIRM=DESTRUIR"; exit 1; }
}

echo "=== demo-bov ops: $ACTION → $SWARM_USER@$SWARM_HOST ==="

case "$ACTION" in

preflight)
  echo "--- Nós e capacidade ---"
  swarm 'docker node ls; echo; free -h; echo; df -h / | tail -1'

  echo "--- Stacks existentes ---"
  swarm 'docker stack ls'

  echo "--- Rede blockforce ---"
  swarm "docker network inspect blockforce --format 'driver={{.Driver}} attachable={{.Attachable}} scope={{.Scope}}'" || echo "AUSENTE"

  echo "--- Postgres ---"
  PG="$(find_pg)"
  echo "container no manager: ${PG:-<não encontrado>}"
  if [ -z "$PG" ]; then
    # Pode estar num worker: descobre onde, para saber se o seed vai poder usar
    # `docker exec` ou se precisará de container transiente na overlay.
    swarm "docker service ls --format '{{.Name}}' | grep -i postgres || echo 'nenhum service postgres'"
  else
    psql_do "SELECT version()"
    echo "rolcreatedb: $(psql_do "SELECT rolcreatedb FROM pg_roles WHERE rolname = current_user")"
    echo "-- bancos existentes --"
    psql_do "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY 1"
    echo "-- nomes alvo (vazio = livre) --"
    for d in $DBS; do
      if [ -n "$(psql_do "SELECT 1 FROM pg_database WHERE datname = '$d'")" ]; then
        echo "  OCUPADO: $d"
      else
        echo "  livre:   $d"
      fi
    done
  fi

  echo "--- Dgraph/Redis existentes (referência de nomes) ---"
  swarm "docker service ls --format '{{.Name}}\t{{.Replicas}}\t{{.Image}}' | grep -Ei 'dgraph|redis'" || echo "nenhum"

  # Rede de segurança: se o cea-dev for atingido, estas são as imagens para
  # restaurar com `docker service update --image`.
  echo "--- Snapshot das imagens do cea-dev (rollback) ---"
  swarm "docker service ls --format '{{.Name}}' | grep -- '-cea-dev' | while read s; do printf '%s\t%s\n' \"\$s\" \"\$(docker service inspect \$s --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}')\"; done" | tee cea-dev-images.txt
  ;;

create-databases)
  for d in $DBS; do
    if [ -n "$(psql_do "SELECT 1 FROM pg_database WHERE datname = '$d'")" ]; then
      echo "  = $d já existe"
    else
      psql_do "CREATE DATABASE \\\"$d\\\"" >/dev/null
      echo "  + $d criado"
    fi
  done
  echo "--- conferência ---"
  psql_do "SELECT datname FROM pg_database WHERE datname LIKE '%-bov' ORDER BY 1"
  ;;

infra-up)
  # Dgraph e Redis dedicados. Os envs de dev apontam para `dgraph-alpha-cea-dev` e
  # `redis-cea-dev`; reusá-los faria o parse do ambiente bov escrever dentro do
  # grafo do cea e a árvore da demo atual passaria a mostrar boi.
  # Sem `ports:`: o pipeline não publica portas e o acesso é por DNS da overlay —
  # publicar colidiria com o Dgraph do cea (9080/8082).
  STACK_FILE="$(mktemp)"
  cat > "$STACK_FILE" <<'YAML'
version: "3.8"

services:
  dgraph-zero-bov-demo:
    image: dgraph/dgraph:v23.1.0
    command: dgraph zero --my=dgraph-zero-bov-demo:5080 --replicas 1
    networks: [blockforce]
    volumes:
      - dgraph-bov-demo-zero:/dgraph
    deploy:
      replicas: 1
      restart_policy: { condition: any }
      resources:
        limits: { memory: 512M }

  dgraph-alpha-bov-demo:
    image: dgraph/dgraph:v23.1.0
    command: dgraph alpha --my=dgraph-alpha-bov-demo:7080 --zero=dgraph-zero-bov-demo:5080 --security whitelist=0.0.0.0/0
    networks: [blockforce]
    volumes:
      - dgraph-bov-demo-alpha:/dgraph
    deploy:
      replicas: 1
      restart_policy: { condition: any }
      resources:
        limits: { memory: 2G }

  redis-bov-demo:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    networks: [blockforce]
    volumes:
      - redis-bov-demo:/data
    deploy:
      replicas: 1
      restart_policy: { condition: any }
      resources:
        limits: { memory: 256M }

networks:
  blockforce:
    external: true

volumes:
  dgraph-bov-demo-zero:
  dgraph-bov-demo-alpha:
  redis-bov-demo:
YAML
  scp $SSH_OPTS "$STACK_FILE" "${SWARM_USER}@${SWARM_HOST}:/tmp/infra-bov-demo.yml"
  rm -f "$STACK_FILE"
  swarm "docker stack deploy -c /tmp/infra-bov-demo.yml infra-bov-demo && rm -f /tmp/infra-bov-demo.yml"
  echo "aguardando convergência…"
  sleep 25
  swarm "docker service ls --filter name=infra-bov-demo"
  ;;

infra-status)
  swarm "docker stack ps infra-bov-demo --no-trunc" || echo "stack ausente"
  swarm "docker service ls --filter name=infra-bov-demo"
  ;;

infra-down)
  require_confirm
  swarm "docker stack rm infra-bov-demo"
  echo "✓ stack removida (volumes preservados)"
  ;;

drop-databases)
  require_confirm
  for d in $DBS; do
    psql_do "DROP DATABASE IF EXISTS \\\"$d\\\"" >/dev/null
    echo "  - $d removido"
  done
  ;;

*)
  echo "ERROR: ação desconhecida: $ACTION"; exit 1 ;;
esac

echo "✓ $ACTION OK"
