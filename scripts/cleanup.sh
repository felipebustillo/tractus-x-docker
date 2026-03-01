#!/bin/bash
###############################################################################
# Cleanup Local Dataspace
#
# Two modes:
#   Default (data only): Truncates EDC tables, keeps IH participants
#   --full:              Also truncates IH and BDRS tables
#
# Usage:
#   docker compose run --rm cleanup              # Data only
#   docker compose run --rm cleanup --full       # Full reset
#
# For a complete reset (destroy volumes):
#   docker compose down -v
###############################################################################

set -euo pipefail

POSTGRES_USER="${POSTGRES_USER:-user}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-password}"
FULL_RESET=false

if [ "${1:-}" = "--full" ]; then
    FULL_RESET=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

truncate_tables() {
    local db="$1"
    shift
    local tables=("$@")

    for table in "${tables[@]}"; do
        PGPASSWORD="${POSTGRES_PASSWORD}" psql -h postgres -U "${POSTGRES_USER}" -d "$db" \
            -c "TRUNCATE TABLE ${table} CASCADE;" 2>/dev/null && \
            echo -e "  ${GREEN}OK${NC} $db.$table" || \
            echo -e "  ${YELLOW}SKIP${NC} $db.$table (may not exist)"
    done
}

echo "=== Cleanup Mode: $([ "$FULL_RESET" = true ] && echo "FULL" || echo "DATA ONLY") ==="
echo ""

# EDC Provider tables
echo "--- EDC Provider ---"
EDC_TABLES=(
    edc_asset edc_asset_dataaddress edc_asset_property
    edc_contract_agreement edc_contract_definitions
    edc_contract_negotiation edc_data_request
    edc_lease edc_policydefinitions
    edc_transfer_process edc_data_plane_instance
    edc_edr_entry edc_data_plane
    edc_data_flow edc_access_token_data
    edc_callback_addresses edc_policy_monitor
)
truncate_tables "edc_provider" "${EDC_TABLES[@]}"

echo ""
echo "--- EDC Consumer ---"
truncate_tables "edc_consumer" "${EDC_TABLES[@]}"

if [ "$FULL_RESET" = true ]; then
    echo ""
    echo "--- Identity Hub ---"
    IH_TABLES=(
        credentials credential_request
        sts_client keypair_resource
        did_resource participant_context
    )
    truncate_tables "ih" "${IH_TABLES[@]}"

    echo ""
    echo "--- BDRS ---"
    truncate_tables "bdrs" "did_entry"
fi

echo ""
echo -e "${GREEN}=== Cleanup complete ===${NC}"
