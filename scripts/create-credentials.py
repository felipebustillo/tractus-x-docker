#!/usr/bin/env python3
"""Create signed JWT Verifiable Credentials for Tractus-X participants.

Generates Ed25519-signed JWT VCs for each participant and credential type.
Output is a JSON array written to stdout, suitable for piping to
store-credentials.py.

Environment variables:
    ISSUER_JWK  - Issuer's Ed25519 private key in JWK format (required)
    DID_HOST    - DID web host (default: identity-hub)
    ISSUER_DID  - Override issuer DID (default: derived from DID_HOST + issuer BPN)
"""

import json
import os
import time
import uuid
import sys
import base64

import jwt
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# Issuer JWK private key (from IH vault secret/BPNL00000003CRHK-key-1)
ISSUER_JWK_JSON = os.environ.get("ISSUER_JWK")
if not ISSUER_JWK_JSON:
    print("ERROR: ISSUER_JWK env var required.", file=sys.stderr)
    sys.exit(1)
ISSUER_JWK = json.loads(ISSUER_JWK_JSON)

DID_HOST = os.environ.get("DID_HOST", "identity-hub")
ISSUER_DID = os.environ.get("ISSUER_DID", f"did:web:{DID_HOST}:BPNL00000003CRHK")

PARTICIPANTS = [
    {"bpn": "BPNL00000003AYRE", "label": "Provider"},
    {"bpn": "BPNL00000003AZQP", "label": "Consumer"},
]

CREDENTIAL_TYPES = [
    "MembershipCredential",
    "DataExchangeGovernanceCredential",
]


def base64url_decode(s):
    s = s.replace("-", "+").replace("_", "/")
    padding = 4 - len(s) % 4
    if padding != 4:
        s += "=" * padding
    return base64.b64decode(s)


def create_private_key(jwk):
    d = base64url_decode(jwk["d"])
    return Ed25519PrivateKey.from_private_bytes(d)


def create_vc_jwt(private_key, issuer_did, subject_did, subject_bpn, cred_type):
    now = int(time.time())
    jti = str(uuid.uuid4())

    credential_subject = {
        "id": subject_did,
        "holderIdentifier": subject_bpn,
    }

    if cred_type == "DataExchangeGovernanceCredential":
        credential_subject.update({
            "group": "UseCaseFramework",
            "useCase": "DataExchangeGovernance",
            "contractTemplate": "https://catena-x.net/en/catena-x-introduce-implement/governance-framework-for-data-space-operations",
            "contractVersion": "1.0",
        })
    elif cred_type == "MembershipCredential":
        credential_subject.update({
            "memberOf": "Catena-X",
        })

    vc_payload = {
        "@context": [
            "https://www.w3.org/2018/credentials/v1",
            "https://w3id.org/catenax/credentials/v1.0.0"
        ],
        "type": ["VerifiableCredential", cred_type],
        "issuer": issuer_did,
        "issuanceDate": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "expirationDate": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + 365 * 86400)),
        "credentialSubject": credential_subject
    }

    payload = {
        "iss": issuer_did,
        "sub": subject_did,
        "iat": now,
        "nbf": now,
        "exp": now + 365 * 86400,
        "jti": jti,
        "vc": vc_payload
    }

    headers = {
        "kid": ISSUER_JWK["kid"],
        "alg": "EdDSA"
    }

    token = jwt.encode(payload, private_key, algorithm="EdDSA", headers=headers)
    return token, vc_payload


def main():
    private_key = create_private_key(ISSUER_JWK)
    results = []

    for participant in PARTICIPANTS:
        bpn = participant["bpn"]
        subject_did = f"did:web:{DID_HOST}:{bpn}"

        for cred_type in CREDENTIAL_TYPES:
            token, vc = create_vc_jwt(private_key, ISSUER_DID, subject_did, bpn, cred_type)
            results.append({
                "bpn": bpn,
                "label": participant["label"],
                "type": cred_type,
                "jwt": token,
                "vc": vc
            })
            print(f"  Created: {bpn} / {cred_type}", file=sys.stderr)

    json.dump(results, sys.stdout, indent=2)


if __name__ == "__main__":
    main()
