#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Generate a self-signed TLS 1.3 cert/key pair for the Burble Bolt QUIC
# listener. Writes:
#
#   server/priv/cert/bolt.pem      — X.509 cert
#   server/priv/cert/bolt_key.pem  — Ed25519 private key
#
# Idempotent: skips generation if both files already exist (unless --force).
# Self-signed certs are fine for Bolt because the protocol's threat model
# treats authenticated-but-untrusted senders the same as anonymous senders
# (the recipient decides whether to surface the bolt). For inter-server
# authentication, replace with a trust-rooted cert.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERT_DIR="${REPO_ROOT}/server/priv/cert"
CERT_FILE="${CERT_DIR}/bolt.pem"
KEY_FILE="${CERT_DIR}/bolt_key.pem"
FORCE=0

for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=1 ;;
        --help|-h)
            echo "Usage: $0 [--force]"
            echo "  --force  Regenerate even if existing cert/key are present."
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

if ! command -v openssl >/dev/null 2>&1; then
    echo "[gen-bolt-cert] openssl is required but not installed" >&2
    exit 1
fi

mkdir -p "${CERT_DIR}"

if [ "${FORCE}" -ne 1 ] && [ -f "${CERT_FILE}" ] && [ -f "${KEY_FILE}" ]; then
    echo "[gen-bolt-cert] ${CERT_FILE} and ${KEY_FILE} already exist (use --force to regenerate)"
    exit 0
fi

# Ed25519 is supported by msquic/quicer's TLS stack and produces tiny keys.
# Fall back to P-256 if Ed25519 is unavailable in the local openssl build.
TMP_KEY="$(mktemp)"
trap 'rm -f "${TMP_KEY}"' EXIT

if openssl genpkey -algorithm Ed25519 -out "${TMP_KEY}" 2>/dev/null; then
    echo "[gen-bolt-cert] generated Ed25519 key"
elif openssl ecparam -name prime256v1 -genkey -noout -out "${TMP_KEY}" 2>/dev/null; then
    echo "[gen-bolt-cert] Ed25519 unavailable; generated P-256 key"
else
    echo "[gen-bolt-cert] failed to generate key (neither Ed25519 nor P-256 worked)" >&2
    exit 1
fi

openssl req -new -x509 -key "${TMP_KEY}" \
    -days 825 \
    -subj "/CN=burble-bolt.localhost" \
    -addext "subjectAltName=DNS:burble-bolt.localhost,DNS:localhost,IP:127.0.0.1,IP:::1" \
    -out "${CERT_FILE}" 2>/dev/null

mv "${TMP_KEY}" "${KEY_FILE}"
chmod 600 "${KEY_FILE}"
chmod 644 "${CERT_FILE}"

echo "[gen-bolt-cert] wrote:"
echo "  cert: ${CERT_FILE}"
echo "  key : ${KEY_FILE}"
