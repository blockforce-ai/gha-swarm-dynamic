# gha-swarm-dynamic

GitHub Actions reusable workflows para deploy Docker Swarm multi-cliente.

Port do template GitLab CI `chaingrid/devops/swarm-dynamic` (1762 linhas) pra GitHub Actions.

## Como usar (no repo consumidor)

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [develop, stage, main]
  workflow_dispatch:

jobs:
  pipeline:
    uses: blockforce-ai/gha-swarm-dynamic/.github/workflows/pipeline.yml@main
    with:
      service_name: tenant-api
    secrets: inherit
```

Config por cliente/ambiente em `.gitlab/clients-config.yml` (mesmo formato do GitLab CI).

## Stages

```
1. generate-matrix   → Lê clients-config.yml e monta matrix (client × env)
2. build             → Docker build + push GHCR
3. deploy            → Gera stack + docker stack deploy via SSH swarm manager
```

## Secrets necessários (org-level)

| Secret | Descrição |
|---|---|
| `SWARM_MANAGER_HOST_NP` | IP swarm manager DEV (173.249.59.42) |
| `SWARM_MANAGER_HOST_PROD` | IP swarm manager PROD (95.111.238.146) |
| `SWARM_SSH_PRIVATE_KEY` | SSH key privada pro deploy |
| `SWARM_USER` | SSH user |
| `CLOUDFLARE_API_TOKEN` | DNS mgmt (opcional) |

## Secrets por repo (VARENV_*)

Cada repo tem seus `VARENV_ENV_CLIENT` (ex: `VARENV_DEV_CEA`, `VARENV_PROD_AREZZO`).

## Runner

Requer runner self-hosted na VPS `runners-contabo` (label: `blockforce-swarm`).
