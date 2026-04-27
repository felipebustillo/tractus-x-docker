# Tractus-X Docker — Local Dataspace

Docker Compose setup for running a full Eclipse Tractus-X dataspace locally.
This is the Docker equivalent of the Helm deployment in `hanka/tractus-x`.

## Quick Start

```bash
cp .env.example .env     # already done if .env exists
docker compose up        # starts everything + seed + E2E test
docker compose down -v   # full reset (destroy volumes)
```

## Architecture

Single shared PostgreSQL with per-service databases, 4 HashiCorp Vault instances (dev mode), and an nginx DID proxy.

| Service | Image | Purpose |
|---------|-------|---------|
| identityhub | `tractusx/identityhub` | Multi-tenant DCP wallet (DID, credentials, STS) |
| bdrs-server | `tractusx/bdrs-server` | BPN-to-DID resolution directory |
| provider-controlplane | `tractusx/edc-controlplane-postgresql-hashicorp-vault` | Provider EDC control plane |
| provider-dataplane | `tractusx/edc-dataplane-hashicorp-vault` | Provider EDC data plane |
| consumer-controlplane | Same as provider | Consumer EDC control plane |
| consumer-dataplane | Same as provider | Consumer EDC data plane |
| issuerservice | `tractusx/issuerservice` | Credential issuance (profile: `full`) |

## Version Pinning

Keep versions aligned with the Helm deployment in `~/repos/hanka/tractus-x`.

| Component | Docker tag (`.env` / compose) | Helm equivalent (`charts/values-*.yaml`) |
|-----------|-------------------------------|------------------------------------------|
| EDC connectors | `0.11.0` (hardcoded in compose) | `charts/values-edc-provider.yaml` → `image.tag` |
| Identity Hub | `IDENTITYHUB_TAG` in `.env` | `charts/values-identityhub.yaml` |
| BDRS Server | `0.5.7` (hardcoded in compose) | `charts/bdrs-server/` |
| Issuer Service | `latest` (hardcoded) | `charts/values-issuerservice.yaml` |
| Vault | `1.15` | N/A (K3s uses Helm chart) |
| PostgreSQL | `16` | N/A (K3s uses subchart) |

**When updating versions:** Change both this repo AND `hanka/tractus-x` to stay in sync.
Pin `issuerservice` to a specific tag — `latest` is fragile.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/seed.sh` | Creates IH participants, registers DIDs in BDRS, seeds Vault secrets, registers data planes |
| `scripts/test-e2e.sh` | Runs catalog query + contract negotiation + data transfer |
| `scripts/cleanup.sh` | Resets all databases (profile: `tools`) |
| `scripts/create-credentials.py` | Creates MembershipCredential + DataExchangeGovernanceCredential |
| `scripts/store-credentials.py` | Stores credentials in Identity Hub |

## Exposed Ports

| Port | Service | API |
|------|---------|-----|
| 29082 | Identity Hub | Identity API |
| 29084 | nginx DID proxy | DID document resolution |
| 29281 | Provider | Management API |
| 29181 | Consumer | Management API |
