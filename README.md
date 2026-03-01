# Tractus-X Dataspace in Docker Compose

A complete [Eclipse Tractus-X](https://eclipse-tractusx.github.io/) dataspace running locally with `docker compose up`. Includes EDC connectors, decentralized identity (DID/DCP), verifiable credentials, and an automated end-to-end data exchange test.

**One command. Full dataspace. ~60 seconds.**

## Why?

The official [Minimum Viable Dataspace (MXD)](https://github.com/eclipse-tractusx/tutorial-resources/tree/main/mxd) requires a Kubernetes cluster, Terraform, and significant setup effort. This project packages the same components into a single Docker Compose file that runs on any machine with Docker installed.

| | MXD (official) | This project |
|---|---|---|
| Runtime | Kubernetes + Terraform | Docker Compose |
| Setup time | 30+ minutes | ~60 seconds |
| Prerequisites | kubectl, helm, terraform, k8s cluster | Docker |
| Components | EDC, MIW, Keycloak, PostgreSQL | EDC, Identity Hub, BDRS, PostgreSQL, Vault |
| Identity | Managed Identity Wallet (MIW) | Identity Hub (DCP/DID) |
| Automation | Manual seeding | Fully automated seed + E2E test |

## Architecture

```
                           Docker Compose Network
 ┌──────────────────────────────────────────────────────────────────────┐
 │                                                                      │
 │  ┌──────────────┐  DID resolution   ┌──────────────┐                │
 │  │ identity-hub │◄──────────────────►│ Identity Hub │                │
 │  │   (nginx)    │   /{BPN}/did.json  │  (DCP/STS)   │                │
 │  └──────────────┘                    └──────┬───────┘                │
 │                                             │                        │
 │         ┌───────────────────────────────────┤                        │
 │         │ STS tokens                        │ STS tokens             │
 │         ▼                                   ▼                        │
 │  ┌──────────────┐  DSP protocol   ┌──────────────┐                  │
 │  │   Consumer   │◄───────────────►│   Provider   │                  │
 │  │ (CP + DP)    │  catalog/nego/  │ (CP + DP)    │                  │
 │  └──────┬───────┘  transfer       └──────┬───────┘                  │
 │         │                                │                           │
 │         │         ┌──────────┐           │                           │
 │         └────────►│   BDRS   │◄──────────┘                          │
 │           BPN→DID │  Server  │ BPN→DID                              │
 │                   └──────────┘                                       │
 │                                                                      │
 │  ┌──────────┐  ┌─────────────────────────────────────────────────┐  │
 │  │ Postgres │  │ Vault x4 (identityhub, bdrs, provider, consumer)│  │
 │  └──────────┘  └─────────────────────────────────────────────────┘  │
 └──────────────────────────────────────────────────────────────────────┘
```

## Quick Start

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (with Compose V2)
- ~4 GB free RAM

### Run

```bash
git clone https://github.com/felipebustillo/tractus-x-docker.git
cd tractus-x-docker
docker compose up -d
```

Watch the seeding and E2E test:

```bash
docker compose logs -f seed e2e-test
```

All 12 seed steps and 5 E2E test steps should pass. The full flow takes about 60 seconds.

### Stop

```bash
docker compose down     # Stop containers (data preserved)
docker compose down -v  # Full reset (destroy volumes)
```

## Services

| Service | Image | Purpose | Exposed Port |
|---|---|---|---|
| `postgres` | postgres:16 | Shared database (5 databases) | - |
| `identityhub-vault` | hashicorp/vault:1.15 | IH secrets (keys, API keys) | - |
| `bdrs-vault` | hashicorp/vault:1.15 | BDRS secrets | - |
| `provider-vault` | hashicorp/vault:1.15 | Provider EDC secrets | - |
| `consumer-vault` | hashicorp/vault:1.15 | Consumer EDC secrets | - |
| `identity-hub` | nginx:alpine | DID resolution proxy (`/{BPN}/did.json`) | 29084 |
| `identityhub` | tractusx/identityhub | DCP wallet, STS, credential storage | 29082 |
| `bdrs-server` | tractusx/bdrs-server:0.5.7 | BPN-to-DID directory | - |
| `provider-controlplane` | tractusx/edc-controlplane-...:0.11.0 | Provider management + DSP | 29281 |
| `provider-dataplane` | tractusx/edc-dataplane-...:0.11.0 | Provider data transfer | - |
| `consumer-controlplane` | tractusx/edc-controlplane-...:0.11.0 | Consumer management + DSP | 29181 |
| `consumer-dataplane` | tractusx/edc-dataplane-...:0.11.0 | Consumer data transfer | - |
| `seed` | (built locally) | Automated seeding (one-shot) | - |
| `e2e-test` | (built locally) | E2E data exchange test (one-shot) | - |

## Participants

| Role | BPN | DID |
|---|---|---|
| Provider | `BPNL00000003AYRE` | `did:web:identity-hub:BPNL00000003AYRE` |
| Consumer | `BPNL00000003AZQP` | `did:web:identity-hub:BPNL00000003AZQP` |
| Issuer | `BPNL00000003CRHK` | `did:web:identity-hub:BPNL00000003CRHK` |

The Issuer is the trusted credential authority. Both EDC connectors list it in their `trustedIssuers` config.

## Configuration

All configuration is in `.env`. Every value is a demo default safe to commit.

| Variable | Default | Description |
|---|---|---|
| `BPN_PROVIDER` | `BPNL00000003AYRE` | Provider Business Partner Number |
| `BPN_CONSUMER` | `BPNL00000003AZQP` | Consumer Business Partner Number |
| `BPN_ISSUER` | `BPNL00000003CRHK` | Issuer Business Partner Number |
| `DID_HOST` | `identity-hub` | Docker service name for DID resolution |
| `IDENTITYHUB_TAG` | `0.1.0-20260209-SNAPSHOT` | Identity Hub image tag |
| `POSTGRES_USER` | `user` | PostgreSQL username |
| `POSTGRES_PASSWORD` | `password` | PostgreSQL password |
| `VAULT_DEV_ROOT_TOKEN_ID` | `root` | Vault dev mode root token |
| `EDC_API_KEY` | `password` | EDC Management API key |
| `JAVA_TOOL_OPTIONS` | `-Xmx256m` | JVM memory limit per service |

## Exposed Ports

For direct API access from the host:

| Port | Service | API |
|---|---|---|
| `29082` | Identity Hub | Identity API (`/api/identity/...`) |
| `29084` | DID Proxy (nginx) | DID documents (`/{BPN}/did.json`) |
| `29181` | Consumer CP | Management API (`/management/...`) |
| `29281` | Provider CP | Management API (`/management/...`) |

Example: query the provider catalog from your host:

```bash
curl -X POST http://localhost:29181/management/v3/catalog/request \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: password" \
    -d '{
        "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
        "counterPartyAddress": "http://provider-controlplane:8084/api/v1/dsp",
        "counterPartyId": "did:web:identity-hub:BPNL00000003AYRE",
        "protocol": "dataspace-protocol-http"
    }'
```

Resolve a DID document:

```bash
curl http://localhost:29084/BPNL00000003AYRE/did.json
```

## Common Operations

### Reset EDC data (keep participants)

```bash
docker compose --profile tools run --rm cleanup
```

### Full reset (including Identity Hub participants)

```bash
docker compose --profile tools run --rm cleanup --full
```

### Complete reset (destroy everything)

```bash
docker compose down -v
docker compose up -d
```

### View logs

```bash
docker compose logs -f seed              # Seeding progress
docker compose logs -f e2e-test          # E2E test results
docker compose logs provider-controlplane # Provider CP logs
```

### Re-run only the E2E test

```bash
docker compose rm -f e2e-test && docker compose up e2e-test
```

## How It Works

### Seeding (12 steps)

The `seed` service runs automatically after all applications are healthy:

1. Wait for all services to be healthy
2. Fetch Identity Hub super-user API key from vault
3. Create 3 participant contexts (Issuer, Provider, Consumer) with DID documents and Ed25519 keys
4. Activate participants via SQL (workaround for IH v0.1.x activation bug)
5. Validate Ed25519 key lengths (must be 32 bytes)
6. Register all BPNs in the BDRS directory
7. Sync STS client secrets from Identity Hub vault to EDC vaults
8. Generate and store signed JWT Verifiable Credentials (MembershipCredential + DataExchangeGovernanceCredential)
9. Seed consumer data plane token-signer key
10. Create a test asset on the Provider (backed by jsonplaceholder.typicode.com)
11. Create access policy (membership-based) and contract policy
12. Verify DID resolution for all participants

### E2E Test (5 steps)

The `e2e-test` service runs after seeding completes:

1. **Catalog request** -- Consumer queries Provider's catalog via DSP protocol
2. **Contract negotiation** -- Consumer negotiates using the catalog offer (polls until FINALIZED)
3. **Transfer process** -- Consumer initiates HttpData-PULL transfer (polls until STARTED)
4. **EDR retrieval** -- Consumer fetches the Endpoint Data Reference (data plane URL + access token)
5. **Data access** -- Consumer fetches actual data from the Provider's data plane

### Key Technical Details

- **STS flow**: EDC connectors authenticate via Identity Hub's Secure Token Service. The `TX_EDC_IAM_STS_DIM_URL` must NOT be set -- this forces the single-step `RemoteSecureTokenService` which correctly includes the `audience` claim.
- **DID resolution**: Uses `did:web` over HTTP (not HTTPS) within the Docker network. An nginx proxy rewrites `/{BPN}/did.json` requests to the Identity Hub's DID endpoint.
- **Credential service URL**: Contains a base64-encoded BPN (not DID). Identity Hub looks up participants by `participant_context_id` which is the BPN.
- **Vault secrets**: Dev-mode vaults are in-memory. Data is lost on `docker compose down -v`. The `vault-init` service seeds initial secrets; the `seed` script syncs STS secrets generated by Identity Hub.

## Troubleshooting

### Identity Hub fails to start

Check PostgreSQL is healthy and Flyway migrations ran:

```bash
docker compose logs identityhub | grep -i "flyway\|error\|exception"
```

### Seed fails at "Fetching Identity Hub API key"

The super-user API key is only generated on first IH startup with an empty database. If you have a stale DB volume with an empty vault:

```bash
docker compose down -v   # Destroy volumes
docker compose up -d     # Fresh start
```

### E2E test fails at catalog request

Check that credentials were stored successfully:

```bash
docker compose logs seed | grep -A2 "Step 7"
```

Verify DID documents resolve correctly:

```bash
curl http://localhost:29084/BPNL00000003AYRE/did.json | jq .
```

### Negotiation fails with TERMINATED

Check Provider control plane logs for policy evaluation errors:

```bash
docker compose logs provider-controlplane | grep -i "policy\|evaluation\|terminated"
```

### Transfer stuck in REQUESTED state

Usually means the data plane hasn't registered with the control plane. The `EDC_HOSTNAME` env var must match the Docker service name:

```bash
docker compose logs provider-dataplane | grep -i "register\|selector"
```

### Out of memory

Reduce Java heap per service:

```bash
# In .env
JAVA_TOOL_OPTIONS=-Xmx128m
```

### Services unhealthy after restart

Dev-mode Vault is in-memory. After `docker compose down` (without `-v`), the database still has data but vaults are empty. Always use `docker compose down -v` for a clean restart.

## Component Versions

| Component | Version |
|---|---|
| EDC Connector | 0.11.0 |
| Identity Hub | 0.1.0-SNAPSHOT |
| BDRS Server | 0.5.7 |
| PostgreSQL | 16 |
| HashiCorp Vault | 1.15 |

## License

Apache License 2.0. See [LICENSE](LICENSE).

This project uses components from the [Eclipse Tractus-X](https://eclipse-tractusx.github.io/) project.
