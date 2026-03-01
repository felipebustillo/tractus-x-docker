#!/bin/bash
###############################################################################
# Seed Local Dataspace
#
# Creates IH participants, activates them, registers BPNs in BDRS,
# creates and stores credentials, seeds consumer data plane key,
# and creates test asset + policies on the Provider.
#
# Runs inside Docker Compose network — no port-forwards needed.
###############################################################################

set -euo pipefail

# Configuration (from Docker Compose environment)
DID_HOST="${DID_HOST:-identity-hub}"
BPN_PROVIDER="${BPN_PROVIDER:-BPNL00000003AYRE}"
BPN_CONSUMER="${BPN_CONSUMER:-BPNL00000003AZQP}"
BPN_ISSUER="${BPN_ISSUER:-BPNL00000003CRHK}"
POSTGRES_USER="${POSTGRES_USER:-user}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-password}"
BDRS_API_KEY="${BDRS_API_KEY:-password}"
EDC_API_KEY="${EDC_API_KEY:-password}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
PROVIDER_STS_SECRET="${PROVIDER_STS_SECRET:-provider-sts-secret}"
CONSUMER_STS_SECRET="${CONSUMER_STS_SECRET:-consumer-sts-secret}"

# Derived
DID_ISSUER="did:web:${DID_HOST}:${BPN_ISSUER}"
DID_PROVIDER="did:web:${DID_HOST}:${BPN_PROVIDER}"
DID_CONSUMER="did:web:${DID_HOST}:${BPN_CONSUMER}"

IH_IDENTITY_URL="http://identityhub:8082"
IH_DID_URL="http://identity-hub"
BDRS_MGMT_URL="http://bdrs-server:8081"
PROVIDER_MGMT_URL="http://provider-controlplane:8081"
CONSUMER_MGMT_URL="http://consumer-controlplane:8081"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step()  { echo -e "\n${BLUE}=== Step $1: $2 ===${NC}"; }
info()  { echo -e "${YELLOW}  -> $1${NC}"; }
ok()    { echo -e "${GREEN}  OK $1${NC}"; }
fail()  { echo -e "${RED}  FAIL $1${NC}"; exit 1; }

###############################################################################
# Step 0: Wait for services
###############################################################################
step 0 "Waiting for services"

wait_for_health() {
    local name="$1" url="$2" max_attempts="${3:-60}"
    local attempt=0
    echo -n "  Waiting for $name..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -sf "$url" > /dev/null 2>&1; then
            echo -e " ${GREEN}UP${NC}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    echo -e " ${RED}TIMEOUT${NC}"
    return 1
}

wait_for_health "Identity Hub" "http://identityhub:8081/api/check/health"
wait_for_health "BDRS Server" "http://bdrs-server:8080/api/check/health"
wait_for_health "Provider CP" "http://provider-controlplane:8080/api/check/health"
wait_for_health "Consumer CP" "http://consumer-controlplane:8080/api/check/health"
wait_for_health "Provider DP" "http://provider-dataplane:8080/api/check/health"
wait_for_health "Consumer DP" "http://consumer-dataplane:8080/api/check/health"

###############################################################################
# Step 1: Get IH super-user API key
###############################################################################
step 1 "Fetching Identity Hub API key from vault"

API_KEY=$(curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "http://identityhub-vault:8200/v1/secret/data/super-user-apikey" \
    | jq -r '.data.data.content') || true

if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    info "API key not found (IH may not have generated it yet), retrying in 10s..."
    sleep 10
    API_KEY=$(curl -sf \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "http://identityhub-vault:8200/v1/secret/data/super-user-apikey" \
        | jq -r '.data.data.content') || fail "Could not retrieve super-user API key"
fi

if [ -z "$API_KEY" ] || [ "$API_KEY" = "null" ]; then
    fail "Could not retrieve super-user API key from identityhub-vault"
fi
ok "API key retrieved"

###############################################################################
# Step 2: Create participants
###############################################################################
step 2 "Creating participant contexts"

create_participant() {
    local bpn="$1" did="$2" label="$3" roles="$4" extra_svc="$5"

    local bpn_b64
    bpn_b64=$(echo -n "$bpn" | base64 -w0)

    # Build service endpoints
    local svc_json
    svc_json=$(jq -n \
        --arg bpnB64 "$bpn_b64" \
        --arg svcId "${label}-credentialservice" \
        --argjson extra "$extra_svc" \
        '[{
            "type": "CredentialService",
            "serviceEndpoint": ("http://identityhub:8083/api/credentials/v1/participants/" + $bpnB64),
            "id": $svcId
        }] + $extra')

    local data
    data=$(jq -n \
        --arg did "$did" \
        --arg bpn "$bpn" \
        --argjson roles "$roles" \
        --argjson svc "$svc_json" \
        '{
            "roles": $roles,
            "serviceEndpoints": $svc,
            "active": true,
            "participantId": $bpn,
            "did": $did,
            "key": {
                "keyId": ($did + "#key-1"),
                "privateKeyAlias": ($bpn + "-key-1"),
                "keyGeneratorParams": {
                    "algorithm": "EdDSA"
                }
            }
        }')

    local tmpfile http_code body
    tmpfile=$(mktemp)
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
        -X POST "${IH_IDENTITY_URL}/api/identity/v1alpha/participants/" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${API_KEY}" \
        -d "$data" 2>/dev/null) || http_code="000"
    body=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        ok "${label} created ($bpn)"
    elif [ "$http_code" = "409" ]; then
        ok "${label} already exists ($bpn)"
    else
        echo -e "  ${RED}FAIL${NC} - HTTP $http_code: $body"
        return 1
    fi
}

info "Creating Issuer..."
create_participant "$BPN_ISSUER" "$DID_ISSUER" "issuer" '["admin"]' '[]'

info "Creating Provider..."
create_participant "$BPN_PROVIDER" "$DID_PROVIDER" "provider" '[]' \
    "[{\"type\":\"ProtocolEndpoint\",\"serviceEndpoint\":\"http://provider-controlplane:8084/api/v1/dsp\",\"id\":\"provider-dsp\"}]"

info "Creating Consumer..."
create_participant "$BPN_CONSUMER" "$DID_CONSUMER" "consumer" '[]' \
    "[{\"type\":\"ProtocolEndpoint\",\"serviceEndpoint\":\"http://consumer-controlplane:8084/api/v1/dsp\",\"id\":\"consumer-dsp\"}]"

###############################################################################
# Step 3: Activate participants via SQL
###############################################################################
step 3 "Activating participants via database"

ACTIVATED=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h postgres -U "${POSTGRES_USER}" -d ih -tAc \
    "UPDATE participant_context SET state = 2 WHERE state = 1 RETURNING participant_context_id;")

if [ -n "$ACTIVATED" ]; then
    echo "$ACTIVATED" | while read -r pid; do
        ok "Activated: $pid"
    done
else
    info "No participants needed activation (already active)"
fi

###############################################################################
# Step 4: Validate Ed25519 keys
###############################################################################
step 4 "Validating Ed25519 keypairs"

for BPN in "$BPN_ISSUER" "$BPN_PROVIDER" "$BPN_CONSUMER"; do
    PUB_KEY=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h postgres -U "${POSTGRES_USER}" -d ih -tAc \
        "SELECT serialized_public_key FROM keypair_resource WHERE participant_id = '${BPN}';" 2>/dev/null) || true

    if [ -z "$PUB_KEY" ]; then
        echo -e "  ${YELLOW}WARNING${NC}: No keypair found for $BPN"
        continue
    fi

    X_VALUE=$(echo "$PUB_KEY" | jq -r '.x // empty' 2>/dev/null) || true
    if [ -z "$X_VALUE" ]; then
        echo -e "  ${YELLOW}WARNING${NC}: $BPN - could not parse public key JWK"
        continue
    fi

    PADDED=$(echo -n "$X_VALUE" | tr '_-' '/+')
    MOD=$((${#PADDED} % 4))
    if [ "$MOD" -eq 2 ]; then PADDED="${PADDED}=="; elif [ "$MOD" -eq 3 ]; then PADDED="${PADDED}="; fi
    KEY_LEN=$(echo -n "$PADDED" | base64 -d 2>/dev/null | wc -c)

    if [ "$KEY_LEN" -eq 32 ]; then
        ok "$BPN key is valid (32 bytes)"
    else
        echo -e "  ${RED}ERROR${NC} - $BPN key is ${KEY_LEN} bytes (expected 32)"
    fi
done

###############################################################################
# Step 5: Register BPNs in BDRS
###############################################################################
step 5 "Registering BPNs in BDRS"

for entry in "${BPN_ISSUER}|${DID_ISSUER}" "${BPN_PROVIDER}|${DID_PROVIDER}" "${BPN_CONSUMER}|${DID_CONSUMER}"; do
    BPN="${entry%%|*}"
    DID="${entry#*|}"
    echo -n "  $BPN -> $DID ... "

    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X PUT "${BDRS_MGMT_URL}/api/management/bpn-directory" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${BDRS_API_KEY}" \
        -d "{\"bpn\":\"${BPN}\",\"did\":\"${DID}\"}" 2>/dev/null) || HTTP_CODE="000"

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        echo -e "${GREEN}OK${NC}"
    elif [ "$HTTP_CODE" = "409" ]; then
        echo -e "${YELLOW}SKIP (already registered)${NC}"
    else
        echo -e "${RED}FAIL (HTTP $HTTP_CODE)${NC}"
    fi
done

###############################################################################
# Step 6: Sync STS client secrets from IH vault to EDC vaults
###############################################################################
step 6 "Syncing STS client secrets from Identity Hub to EDC vaults"

# IH auto-generates STS client secrets when creating participants.
# EDC connectors need the SAME secret in their own vault as "sts-oauth-client-secret".
# Read from IH vault (alias: {BPN}-sts-client-secret) and write to EDC vault.
for entry in "${BPN_PROVIDER}|provider-vault" "${BPN_CONSUMER}|consumer-vault"; do
    BPN="${entry%%|*}"
    EDC_VAULT="${entry#*|}"
    echo -n "  STS secret ${BPN} -> ${EDC_VAULT} ... "

    # Read IH-generated STS secret from IH vault
    STS_SECRET=$(curl -sf \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        "http://identityhub-vault:8200/v1/secret/data/${BPN}-sts-client-secret" \
        | jq -r '.data.data.content') || STS_SECRET=""

    if [ -z "$STS_SECRET" ] || [ "$STS_SECRET" = "null" ]; then
        echo -e "${RED}FAIL (could not read from IH vault)${NC}"
        continue
    fi

    # Write it to the EDC's vault as sts-oauth-client-secret
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://${EDC_VAULT}:8200/v1/secret/data/sts-oauth-client-secret" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"content\":\"${STS_SECRET}\"}}" 2>/dev/null) || HTTP_CODE="000"

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAIL (HTTP $HTTP_CODE writing to ${EDC_VAULT})${NC}"
    fi
done

###############################################################################
# Step 7: Create and store credentials
###############################################################################
step 7 "Creating and storing Verifiable Credentials"

info "Extracting issuer private key from vault..."
ISSUER_JWK=$(curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "http://identityhub-vault:8200/v1/secret/data/${BPN_ISSUER}-key-1" \
    | jq -r '.data.data.content') || fail "Could not extract issuer key"

if [ -z "$ISSUER_JWK" ] || [ "$ISSUER_JWK" = "null" ]; then
    fail "Issuer key not found in vault"
fi
ok "Issuer key extracted"

info "Generating credentials..."
export ISSUER_JWK
export DID_HOST
export ISSUER_DID="$DID_ISSUER"

CREDENTIALS_FILE=$(mktemp)
python3 /scripts/create-credentials.py > "$CREDENTIALS_FILE"
ok "Credentials generated"

info "Storing credentials in Identity Hub..."
export IH_URL="http://identityhub:8082"
export IH_API_KEY="$API_KEY"
python3 /scripts/store-credentials.py "$CREDENTIALS_FILE"

rm -f "$CREDENTIALS_FILE"

###############################################################################
# Step 8: Seed consumer data plane token-signer key
###############################################################################
step 8 "Seeding consumer data plane token-signer key"

info "Extracting consumer Ed25519 key from IH vault..."
CONSUMER_KEY=$(curl -sf \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "http://identityhub-vault:8200/v1/secret/data/${BPN_CONSUMER}-key-1" \
    | jq -r '.data.data.content') || true

if [ -n "$CONSUMER_KEY" ] && [ "$CONSUMER_KEY" != "null" ]; then
    info "Storing consumer key in consumer-vault as token-signer-key..."
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://consumer-vault:8200/v1/secret/data/token-signer-key" \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"data\":{\"content\":$(echo "$CONSUMER_KEY" | jq -Rs .)}}" 2>/dev/null) || HTTP_CODE="000"

    if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
        ok "Consumer token-signer key stored"
    else
        echo -e "  ${YELLOW}WARNING${NC}: Could not store consumer key (HTTP $HTTP_CODE)"
    fi
else
    echo -e "  ${YELLOW}WARNING${NC}: Consumer key not found in IH vault"
fi

###############################################################################
# Step 9: Create test asset on Provider
###############################################################################
step 9 "Creating test asset on Provider"

info "Creating asset..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${PROVIDER_MGMT_URL}/management/v3/assets" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${EDC_API_KEY}" \
    -d '{
        "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
        "@id": "test-asset-1",
        "properties": {
            "name": "Test Asset",
            "description": "E2E test dataset"
        },
        "dataAddress": {
            "type": "HttpData",
            "baseUrl": "https://jsonplaceholder.typicode.com/todos/1"
        }
    }' 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    ok "Asset test-asset-1 created"
elif [ "$HTTP_CODE" = "409" ]; then
    ok "Asset test-asset-1 already exists"
else
    echo -e "  ${YELLOW}WARNING${NC}: Asset creation returned HTTP $HTTP_CODE"
fi

###############################################################################
# Step 10: Create policies
###############################################################################
step 10 "Creating policies"

info "Creating access policy (Membership)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${PROVIDER_MGMT_URL}/management/v3/policydefinitions" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${EDC_API_KEY}" \
    -d '{
        "@context": [
            "https://w3id.org/catenax/2025/9/policy/odrl.jsonld",
            "https://w3id.org/catenax/2025/9/policy/context.jsonld",
            {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
        ],
        "@type": "PolicyDefinition",
        "@id": "membership-policy",
        "policy": {
            "@type": "Set",
            "permission": [{
                "action": "access",
                "constraint": {
                    "leftOperand": "Membership",
                    "operator": "eq",
                    "rightOperand": "active"
                }
            }]
        }
    }' 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    ok "membership-policy created"
elif [ "$HTTP_CODE" = "409" ]; then
    ok "membership-policy already exists"
else
    echo -e "  ${YELLOW}WARNING${NC}: membership-policy creation returned HTTP $HTTP_CODE"
fi

info "Creating contract policy (FrameworkAgreement + UsagePurpose)..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${PROVIDER_MGMT_URL}/management/v3/policydefinitions" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${EDC_API_KEY}" \
    -d '{
        "@context": [
            "https://w3id.org/catenax/2025/9/policy/odrl.jsonld",
            "https://w3id.org/catenax/2025/9/policy/context.jsonld",
            {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
        ],
        "@type": "PolicyDefinition",
        "@id": "dataexchange-policy",
        "policy": {
            "@type": "Set",
            "permission": [{
                "action": "use",
                "constraint": {
                    "and": [
                        {
                            "leftOperand": "Membership",
                            "operator": "eq",
                            "rightOperand": "active"
                        },
                        {
                            "leftOperand": "FrameworkAgreement",
                            "operator": "eq",
                            "rightOperand": "DataExchangeGovernance:1.0"
                        },
                        {
                            "leftOperand": "UsagePurpose",
                            "operator": "isAnyOf",
                            "rightOperand": "cx.core.industrycore:1"
                        }
                    ]
                }
            }]
        }
    }' 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    ok "dataexchange-policy created"
elif [ "$HTTP_CODE" = "409" ]; then
    ok "dataexchange-policy already exists"
else
    echo -e "  ${YELLOW}WARNING${NC}: dataexchange-policy creation returned HTTP $HTTP_CODE"
fi

###############################################################################
# Step 11: Create contract definition
###############################################################################
step 11 "Creating contract definition"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${PROVIDER_MGMT_URL}/management/v3/contractdefinitions" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: ${EDC_API_KEY}" \
    -d '{
        "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
        "@id": "test-contract-def-1",
        "accessPolicyId": "membership-policy",
        "contractPolicyId": "dataexchange-policy",
        "assetsSelector": [{
            "operandLeft": "https://w3id.org/edc/v0.0.1/ns/id",
            "operator": "=",
            "operandRight": "test-asset-1"
        }]
    }' 2>/dev/null) || HTTP_CODE="000"

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    ok "test-contract-def-1 created"
elif [ "$HTTP_CODE" = "409" ]; then
    ok "test-contract-def-1 already exists"
else
    echo -e "  ${YELLOW}WARNING${NC}: Contract definition creation returned HTTP $HTTP_CODE"
fi

###############################################################################
# Step 12: Verify DID resolution
###############################################################################
step 12 "Verifying DID resolution"

for BPN in "$BPN_ISSUER" "$BPN_PROVIDER" "$BPN_CONSUMER"; do
    echo -n "  $BPN: "
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        "${IH_DID_URL}/${BPN}/did.json" 2>/dev/null) || HTTP_CODE="000"

    if [ "$HTTP_CODE" = "200" ]; then
        VM_COUNT=$(curl -s "${IH_DID_URL}/${BPN}/did.json" | jq '.verificationMethod | length' 2>/dev/null) || VM_COUNT="0"
        if [ "$VM_COUNT" -gt 0 ]; then
            echo -e "${GREEN}OK (${VM_COUNT} verification method(s))${NC}"
        else
            echo -e "${YELLOW}WARNING - 200 but verificationMethod is empty${NC}"
        fi
    elif [ "$HTTP_CODE" = "204" ]; then
        echo -e "${RED}FAIL - 204 No Content (not activated?)${NC}"
    else
        echo -e "${RED}FAIL (HTTP $HTTP_CODE)${NC}"
    fi
done

###############################################################################
# Done
###############################################################################

echo ""
echo -e "${GREEN}=============================================${NC}"
echo -e "${GREEN} Seeding complete!${NC}"
echo -e "${GREEN}=============================================${NC}"
echo ""
echo "  DID Host:     $DID_HOST"
echo "  Provider DID: $DID_PROVIDER"
echo "  Consumer DID: $DID_CONSUMER"
echo "  Issuer DID:   $DID_ISSUER"
echo ""
echo "  Test asset:   test-asset-1"
echo "  Contract def: test-contract-def-1"
echo ""
