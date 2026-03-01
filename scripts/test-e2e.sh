#!/bin/bash
###############################################################################
# E2E Data Exchange Test
#
# Runs the full EDC data exchange lifecycle inside the Docker network:
#   1. Catalog request (Consumer -> Provider)
#   2. Contract negotiation (poll until FINALIZED)
#   3. Transfer process (HttpData-PULL, poll until STARTED)
#   4. EDR retrieval (endpoint + access token)
#   5. Data access (fetch actual data from Provider data plane)
#
# Exit code 0 = success, non-zero = failure.
###############################################################################

set -euo pipefail

# Configuration
DID_HOST="${DID_HOST:-identity-hub}"
BPN_PROVIDER="${BPN_PROVIDER:-BPNL00000003AYRE}"
BPN_CONSUMER="${BPN_CONSUMER:-BPNL00000003AZQP}"
EDC_API_KEY="${EDC_API_KEY:-password}"

CONSUMER_MGMT="http://consumer-controlplane:8081/management"
PROVIDER_DSP="http://provider-controlplane:8084/api/v1/dsp"
PROVIDER_DID="did:web:${DID_HOST}:${BPN_PROVIDER}"
POLL_INTERVAL=3
POLL_TIMEOUT=120

# Temp directory for intermediate JSON files
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() { printf "\n${BLUE}=== Step %s: %s ===${NC}\n" "$1" "$2"; }
info() { printf "${YELLOW}  -> %s${NC}\n" "$1"; }
ok()   { printf "${GREEN}  OK %s${NC}\n" "$1"; }
fail() { printf "${RED}  FAIL %s${NC}\n" "$1"; exit 1; }

###############################################################################
# Step 1: Catalog Request
###############################################################################
step 1 "Catalog Request"

info "Requesting Provider catalog..."
curl -s -X POST "$CONSUMER_MGMT/v3/catalog/request" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $EDC_API_KEY" \
    -d "$(jq -n \
        --arg dsp "$PROVIDER_DSP" \
        --arg did "$PROVIDER_DID" '{
        "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
        "counterPartyAddress": $dsp,
        "counterPartyId": $did,
        "protocol": "dataspace-protocol-http"
    }')" > "$TMPDIR/catalog.json"

# Check for errors
if jq -e '.["@type"]' "$TMPDIR/catalog.json" 2>/dev/null | grep -qi "error"; then
    printf "  Catalog response:\n"
    jq . "$TMPDIR/catalog.json" 2>/dev/null || cat "$TMPDIR/catalog.json"
    fail "Catalog request failed"
fi

# Extract first dataset
jq '
    if .["dcat:dataset"] | type == "array" then .["dcat:dataset"][0]
    else .["dcat:dataset"]
    end' "$TMPDIR/catalog.json" > "$TMPDIR/dataset.json"

DATASET_CHECK=$(jq -r 'type' "$TMPDIR/dataset.json" 2>/dev/null) || DATASET_CHECK="null"
if [ "$DATASET_CHECK" = "null" ] || [ "$(jq -r '.' "$TMPDIR/dataset.json")" = "null" ]; then
    printf "  Catalog response:\n"
    jq . "$TMPDIR/catalog.json" 2>/dev/null || cat "$TMPDIR/catalog.json"
    fail "No datasets found in catalog"
fi

ASSET_ID=$(jq -r '.["@id"]' "$TMPDIR/dataset.json")
ok "Found asset: $ASSET_ID"

# Extract first policy (offer)
jq '
    if .["odrl:hasPolicy"] | type == "array" then .["odrl:hasPolicy"][0]
    else .["odrl:hasPolicy"]
    end' "$TMPDIR/dataset.json" > "$TMPDIR/offer.json"

OFFER_ID=$(jq -r '.["@id"]' "$TMPDIR/offer.json")
ok "Found offer: $OFFER_ID"

###############################################################################
# Step 2: Contract Negotiation
###############################################################################
step 2 "Contract Negotiation"

# Build negotiation policy: add target + assigner to the offer
jq \
    --arg target "$ASSET_ID" \
    --arg assigner "$BPN_PROVIDER" '
    . + {
        "odrl:target": {"@id": $target},
        "odrl:assigner": {"@id": $assigner}
    }' "$TMPDIR/offer.json" > "$TMPDIR/negotiation_policy.json"

# Build full contract request (2025/9 policy context for JSON-LD resolution)
jq -n \
    --slurpfile policy "$TMPDIR/negotiation_policy.json" \
    --arg dsp "$PROVIDER_DSP" \
    --arg did "$PROVIDER_DID" '{
    "@context": [
        "https://w3id.org/catenax/2025/9/policy/odrl.jsonld",
        "https://w3id.org/catenax/2025/9/policy/context.jsonld",
        {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"}
    ],
    "@type": "ContractRequest",
    "counterPartyAddress": $dsp,
    "counterPartyId": $did,
    "protocol": "dataspace-protocol-http",
    "policy": $policy[0]
}' > "$TMPDIR/negotiation_request.json"

info "Initiating negotiation for offer $OFFER_ID..."
curl -s -X POST "$CONSUMER_MGMT/v3/contractnegotiations" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $EDC_API_KEY" \
    -d @"$TMPDIR/negotiation_request.json" > "$TMPDIR/negotiation_response.json"

# Check for validation errors
if jq -e 'type == "array"' "$TMPDIR/negotiation_response.json" >/dev/null 2>&1; then
    printf "  Validation errors:\n"
    jq . "$TMPDIR/negotiation_response.json"
    fail "Failed to initiate negotiation"
fi

NEGOTIATION_ID=$(jq -r '.["@id"] // .id' "$TMPDIR/negotiation_response.json")
if [ "$NEGOTIATION_ID" = "null" ] || [ -z "$NEGOTIATION_ID" ]; then
    printf "  Response:\n"
    jq . "$TMPDIR/negotiation_response.json"
    fail "Failed to initiate negotiation"
fi
ok "Negotiation initiated: $NEGOTIATION_ID"

# Poll until FINALIZED
info "Polling negotiation status..."
ELAPSED=0
while [ $ELAPSED -lt $POLL_TIMEOUT ]; do
    curl -s "$CONSUMER_MGMT/v3/contractnegotiations/$NEGOTIATION_ID" \
        -H "X-Api-Key: $EDC_API_KEY" > "$TMPDIR/negotiation_status.json"

    STATE=$(jq -r '.state // .["edc:state"]' "$TMPDIR/negotiation_status.json")
    info "State: $STATE (${ELAPSED}s)"

    case "$STATE" in
        FINALIZED)
            CONTRACT_AGREEMENT_ID=$(jq -r '.contractAgreementId // .["edc:contractAgreementId"]' "$TMPDIR/negotiation_status.json")
            ok "Negotiation finalized! Agreement: $CONTRACT_AGREEMENT_ID"
            break
            ;;
        TERMINATED|ERROR)
            printf "  Full response:\n"
            jq . "$TMPDIR/negotiation_status.json"
            fail "Negotiation failed with state: $STATE"
            ;;
    esac

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ $ELAPSED -ge $POLL_TIMEOUT ]; then
    fail "Negotiation timed out after ${POLL_TIMEOUT}s (last state: $STATE)"
fi

###############################################################################
# Step 3: Transfer Process (HttpData-PULL)
###############################################################################
step 3 "Transfer Process (HttpData-PULL)"

info "Initiating transfer for agreement $CONTRACT_AGREEMENT_ID..."
jq -n \
    --arg dsp "$PROVIDER_DSP" \
    --arg did "$PROVIDER_DID" \
    --arg contract "$CONTRACT_AGREEMENT_ID" '{
    "@context": {"@vocab": "https://w3id.org/edc/v0.0.1/ns/"},
    "@type": "TransferRequest",
    "counterPartyAddress": $dsp,
    "counterPartyId": $did,
    "protocol": "dataspace-protocol-http",
    "contractId": $contract,
    "transferType": "HttpData-PULL"
}' > "$TMPDIR/transfer_request.json"

curl -s -X POST "$CONSUMER_MGMT/v3/transferprocesses" \
    -H "Content-Type: application/json" \
    -H "X-Api-Key: $EDC_API_KEY" \
    -d @"$TMPDIR/transfer_request.json" > "$TMPDIR/transfer_response.json"

# Check for validation errors
if jq -e 'type == "array"' "$TMPDIR/transfer_response.json" >/dev/null 2>&1; then
    printf "  Validation errors:\n"
    jq . "$TMPDIR/transfer_response.json"
    fail "Failed to initiate transfer"
fi

TRANSFER_ID=$(jq -r '.["@id"] // .id' "$TMPDIR/transfer_response.json")
if [ "$TRANSFER_ID" = "null" ] || [ -z "$TRANSFER_ID" ]; then
    printf "  Response:\n"
    jq . "$TMPDIR/transfer_response.json"
    fail "Failed to initiate transfer"
fi
ok "Transfer initiated: $TRANSFER_ID"

# Poll until STARTED
info "Polling transfer status..."
ELAPSED=0
while [ $ELAPSED -lt $POLL_TIMEOUT ]; do
    curl -s "$CONSUMER_MGMT/v3/transferprocesses/$TRANSFER_ID" \
        -H "X-Api-Key: $EDC_API_KEY" > "$TMPDIR/transfer_status.json"

    STATE=$(jq -r '.state // .["edc:state"]' "$TMPDIR/transfer_status.json")
    info "State: $STATE (${ELAPSED}s)"

    case "$STATE" in
        STARTED)
            ok "Transfer started!"
            break
            ;;
        TERMINATED|ERROR)
            printf "  Full response:\n"
            jq . "$TMPDIR/transfer_status.json"
            fail "Transfer failed with state: $STATE"
            ;;
        COMPLETED)
            ok "Transfer completed!"
            break
            ;;
    esac

    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [ $ELAPSED -ge $POLL_TIMEOUT ]; then
    fail "Transfer timed out after ${POLL_TIMEOUT}s (last state: $STATE)"
fi

###############################################################################
# Step 4: EDR Retrieval
###############################################################################
step 4 "EDR Retrieval (Endpoint Data Reference)"

sleep 2

info "Fetching EDR for transfer $TRANSFER_ID..."
curl -s "$CONSUMER_MGMT/v3/edrs/$TRANSFER_ID/dataaddress" \
    -H "X-Api-Key: $EDC_API_KEY" > "$TMPDIR/edr.json"

ENDPOINT=$(jq -r '.endpoint // .["edc:endpoint"] // .baseUrl // .["edc:baseUrl"]' "$TMPDIR/edr.json")
AUTHORIZATION=$(jq -r '.authorization // .["edc:authorization"] // .authKey // .["edc:authKey"]' "$TMPDIR/edr.json")

if [ "$ENDPOINT" = "null" ] || [ -z "$ENDPOINT" ]; then
    printf "  EDR response:\n"
    jq . "$TMPDIR/edr.json"
    fail "Could not extract endpoint from EDR"
fi

if [ "$AUTHORIZATION" = "null" ] || [ -z "$AUTHORIZATION" ]; then
    printf "  EDR response:\n"
    jq . "$TMPDIR/edr.json"
    fail "Could not extract authorization token from EDR"
fi

ok "Data plane endpoint: $ENDPOINT"
ok "Authorization token: ${AUTHORIZATION:0:60}..."

###############################################################################
# Step 5: Data Access
###############################################################################
step 5 "Data Access"

# The endpoint may point to the Docker service name directly
info "Fetching data from: $ENDPOINT"
curl -s "$ENDPOINT" \
    -H "Authorization: $AUTHORIZATION" > "$TMPDIR/data.json"

# Validate JSON
if jq . "$TMPDIR/data.json" > /dev/null 2>&1; then
    ok "Valid JSON data received"
    jq . "$TMPDIR/data.json"
else
    printf "  Raw data: "
    cat "$TMPDIR/data.json"
    printf "\n"
    fail "Response is not valid JSON"
fi

printf "\n${GREEN}=== Full Flow Complete ===${NC}\n"
printf "  Asset:     %s\n" "$ASSET_ID"
printf "  Offer:     %s\n" "$OFFER_ID"
printf "  Agreement: %s\n" "$CONTRACT_AGREEMENT_ID"
printf "  Transfer:  %s\n" "$TRANSFER_ID"
printf "  Endpoint:  %s\n" "$ENDPOINT"
