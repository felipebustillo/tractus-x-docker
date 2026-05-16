#!/usr/bin/env bash
###############################################################################
# generate-hanka-bundle.sh
#
# Generate the registration bundle an external operator needs to join
# Hanka's Catena-X dataspace as a participant with their own EDC connector
# (Option A: federated wallet, no private key shared with Hanka).
#
# Inputs:
#   --bpn <BPNL...>      The BPN Hanka assigned you at onboarding.
#   --dsp <URL>          Your EDC controlplane DSP endpoint, e.g.
#                        https://edc.your-company.com/api/v1/dsp
#   --dataspace-host     Identity Hub host of the dataspace operator. The
#                        default `identityhub.hanka.ai` is correct for the
#                        production Hanka stack; override for other
#                        operators.
#   --out <DIR>          Where to write the bundle. Defaults to
#                        ./hanka-bundle-<BPN>.
#
# Outputs (inside <DIR>):
#   - public.jwk         Public JWK with the correct `kid`. Paste this in
#                        the Hanka admin UI when registering the connector.
#   - private.jwk        Private JWK. Load into your EDC's vault under the
#                        alias equal to the kid (see post-script notes).
#   - registration.json  One-shot JSON copy with the fields the Hanka
#                        admin UI expects (bpn, dsp_endpoint, signer_public_jwk).
#   - README.txt         Step-by-step instructions for the rest of the flow.
#
# Requires: openssl >= 3.0, jq, python3. Works on any machine; does not
# need the docker-compose stack running.
###############################################################################

set -euo pipefail

BPN=""
DSP=""
DATASPACE_HOST="identityhub.hanka.ai"
OUT_DIR=""

usage() {
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-1}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bpn)            BPN="$2"; shift 2 ;;
        --dsp)            DSP="$2"; shift 2 ;;
        --dataspace-host) DATASPACE_HOST="$2"; shift 2 ;;
        --out)            OUT_DIR="$2"; shift 2 ;;
        -h|--help)        usage 0 ;;
        *) echo "Unknown flag: $1" >&2; usage 1 ;;
    esac
done

[[ -z "${BPN}" ]] && { echo "ERROR: --bpn required" >&2; usage 1; }
[[ -z "${DSP}" ]] && { echo "ERROR: --dsp required" >&2; usage 1; }
[[ "${BPN}" =~ ^BPNL[A-Z0-9]{4,28}$ ]] || {
    echo "ERROR: --bpn must look like BPNL00000000XXXX" >&2; exit 1;
}

OUT_DIR="${OUT_DIR:-./hanka-bundle-${BPN}}"
mkdir -p "${OUT_DIR}"

DID="did:web:${DATASPACE_HOST}:${BPN}"
KID="${DID}#data-plane"

echo "→ Generating Ed25519 keypair for ${BPN}"
TMP_PEM="$(mktemp)"
trap 'rm -f "${TMP_PEM}"' EXIT
openssl genpkey -algorithm ED25519 -out "${TMP_PEM}" 2>/dev/null

# Convert PEM to JWK (private + public) via Python's `cryptography` lib.
python3 - "${TMP_PEM}" "${KID}" "${OUT_DIR}" <<'PY'
import base64, json, sys, pathlib
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

pem_path, kid, out_dir = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])

with open(pem_path, "rb") as fh:
    priv = serialization.load_pem_private_key(fh.read(), password=None)
assert isinstance(priv, Ed25519PrivateKey)

priv_bytes = priv.private_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PrivateFormat.Raw,
    encryption_algorithm=serialization.NoEncryption(),
)
pub_bytes = priv.public_key().public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw,
)

def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

public_jwk = {
    "kty": "OKP",
    "crv": "Ed25519",
    "kid": kid,
    "x":   b64url(pub_bytes),
}
private_jwk = {**public_jwk, "d": b64url(priv_bytes)}

(out_dir / "public.jwk").write_text(json.dumps(public_jwk, indent=2) + "\n")
(out_dir / "private.jwk").write_text(json.dumps(private_jwk, indent=2) + "\n")
PY

# Lock down the private half so it's not accidentally world-readable.
chmod 600 "${OUT_DIR}/private.jwk"

# Build the registration JSON the operator pastes in the Hanka admin UI.
jq -n \
    --arg bpn "${BPN}" \
    --arg dsp "${DSP}" \
    --slurpfile jwk "${OUT_DIR}/public.jwk" \
    '{
        bpn: $bpn,
        dsp_endpoint: $dsp,
        signer_public_jwk: $jwk[0]
    }' > "${OUT_DIR}/registration.json"

cat > "${OUT_DIR}/README.txt" <<EOF
Hanka registration bundle for ${BPN}
=====================================

Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ").

Files:
  public.jwk         ← paste into Hanka admin UI (operator-only field)
  private.jwk        ← load into YOUR EDC vault, NEVER share
  registration.json  ← full operator-side payload (bpn + dsp + public.jwk)

Next steps:

1. Hand the registration.json (or just the public.jwk + dsp endpoint) to
   the Hanka operator. They paste it into:

       Hanka admin → Connectors → Register external connector

   The kid is "${KID}" and Hanka will publish it as an extra
   verificationMethod in your DID document at:

       https://${DATASPACE_HOST}/${BPN}/did.json

2. In your own EDC stack, store the private JWK in your vault under
   alias equal to the kid (the EDC will look it up there to sign DSP
   and data-plane tokens):

       vault kv put "secret/${KID}" content="\$(cat ${OUT_DIR}/private.jwk)"

   (For a HashiCorp Vault dev container; adapt to your runtime.)

3. Configure your EDC connector's signer alias to match:

       edc.iam.token.signer.privatekey.alias = ${KID}
       edc.iam.token.verifier.publickey.alias = ${KID}

4. Make sure your EDC's outbound DSP traffic reaches Hanka's connectors
   on the public *.hanka.ai endpoints and that your inbound DSP endpoint
   (${DSP}) is reachable from Hanka's k3s network — Hanka's connectors
   resolve your DID via the operator and then DSP-call you directly.

5. Smoke-test: after the operator confirms registration, run a catalog
   request from your controlplane against:

       https://edc-provider.hanka.ai/api/v1/dsp

   and from Hanka's side they'll catalog-call you at ${DSP}.

If you regenerate keys (rotation, key compromise), repeat steps 1-3 with
a fresh bundle. The operator can register multiple keys; old entries
should be unpublished from the admin UI after rotation completes.
EOF

cat <<EOF

✓ Bundle written to ${OUT_DIR}/
  • public.jwk         ← ship to Hanka operator
  • private.jwk        ← keep secret (chmod 600), load into your EDC vault
  • registration.json  ← copy-paste-ready operator payload
  • README.txt         ← next steps

The DID Hanka will publish for you:
  ${DID}

The kid bound to your data-plane signing key:
  ${KID}
EOF
