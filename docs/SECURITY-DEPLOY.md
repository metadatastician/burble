<!-- SPDX-License-Identifier: MPL-2.0 -->
<!-- Copyright (c) 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->
<!-- Owner: Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk> -->

# Burble — Self-Hosting Security Deployment Checklist

> Status: **DRAFT** — initial publication, addresses [#106 concern 2].
> Companion to `docs/architecture/THREAT-MODEL.adoc`. Where the threat
> model enumerates threats, this document enumerates **the concrete
> steps a self-hoster must complete before going live**.

## Audience

Maintainers and self-hosters deploying Burble for the first time, or
rotating credentials on an existing deployment.

## Pre-flight: secrets to rotate

Burble ships with no usable production secrets — every secret below
must be generated locally on the deployment host and never committed.

| Secret                                | Where it lives                                   | How to generate                            | Rotation cadence |
|---------------------------------------|--------------------------------------------------|--------------------------------------------|------------------|
| Guardian JWT signing key              | `BURBLE_GUARDIAN_SECRET` env / `config/runtime.exs` | `mix guardian.gen.secret` (≥64 chars)   | 90 days          |
| Database encryption key (VeriSimDB)   | `BURBLE_DB_KEY` env / VeriSimDB config           | `openssl rand -base64 32`                  | 180 days         |
| Magic-link signing secret             | `BURBLE_MAGIC_LINK_SECRET` env                   | `openssl rand -base64 48`                  | 90 days          |
| Bolt / QUIC TLS certificate           | `BURBLE_BOLT_CERT` / `BURBLE_BOLT_KEY`           | ACME / `mkcert` for dev; ACME for prod     | per cert policy  |
| HTTPS endpoint TLS certificate        | reverse proxy / `BURBLE_HTTPS_CERT`              | ACME (Let's Encrypt) recommended           | per cert policy  |
| Phoenix endpoint secret_key_base      | `BURBLE_SECRET_KEY_BASE` env                     | `mix phx.gen.secret`                       | 90 days          |
| PAKE shared-secret (ADR-0003)         | per-deployment generated at first boot           | `burble setup pake-bootstrap`              | per-tenant       |

If any of these are missing at boot, Burble **must refuse to start in
production** (`MIX_ENV=prod`). Dev defaults are provided for
`MIX_ENV=dev` only.

## Encryption-in-transit

| Channel                          | Required TLS posture                                       | Status        |
|----------------------------------|------------------------------------------------------------|---------------|
| HTTPS `/api/v1`                  | TLS 1.3 only, HSTS `max-age=63072000; includeSubDomains; preload` | **Required** |
| Phoenix Channels (WSS)           | TLS 1.3 only, same origin as HTTPS                         | **Required**  |
| WebRTC media (SRTP)              | DTLS-SRTP; SFU does not see plaintext frames               | Built-in      |
| Bolt / QUIC                      | QUIC built-in TLS 1.3 (ADR-0004)                            | **Required**  |
| Federated control-plane bridges  | mTLS between bridge endpoints                              | Recommended   |

Self-hosters terminating TLS at a reverse proxy (nginx, Caddy,
Traefik) must:

1. Configure HSTS with `preload` only after testing — preload removes
   the ability to roll back.
2. Disable TLS 1.0/1.1/1.2 (TLS 1.3 only).
3. Disable HTTP/1.1 plaintext on `:80` — redirect to `:443`.
4. Forward `X-Forwarded-Proto: https` so Phoenix issues
   `Secure; HttpOnly; SameSite=Strict` cookies.

## Encryption-at-rest

| Asset                                          | At-rest crypto                          | Notes                                            |
|------------------------------------------------|-----------------------------------------|--------------------------------------------------|
| VeriSimDB message store                        | Application-level AES-256-GCM (planned) | Currently relies on disk-level encryption; per-row crypto tracked under "Earn the Core" |
| Audit log / Vext hash chain                    | Disk-level (FDE) + tamper-evident chain | Hash chain integrity is **proven**; confidentiality is FDE-dependent |
| Guardian refresh tokens                        | Hashed (Argon2id) before storage        | Built-in                                         |
| User passwords                                 | Argon2id                                | Built-in                                         |
| Magic-link tokens                              | HMAC-signed, single-use, time-bounded   | Built-in                                         |
| Voice frames (in flight)                       | DTLS-SRTP (E2EE optional)               | SFU never decrypts                               |
| Voice frames (recordings, if enabled)          | **Recording is OFF by default**         | If enabled, recording target storage MUST be FDE |
| Coprocessor temp buffers                       | RAM-only, zeroised on release           | Zig NIF discipline                               |
| Container image layers                         | N/A (signed only, see below)            | Cosign-style signing                             |

**Today's honest state:** message-store at-rest crypto is FDE-only.
Application-level per-row AES-GCM is on the "Earn the Core" roadmap.
This document will be updated when that ships; in the meantime
self-hosters should deploy on FDE-protected volumes.

## Default-off, opt-in features

These features MUST stay disabled unless the operator explicitly
enables them and accepts the consequences:

- Voice recording (storage cost + at-rest crypto obligation).
- Public room discovery.
- Federation with untrusted servers.
- LLM upstream calls to non-self-hosted models.
- Third-party telemetry of any kind.

## One-command-deploy checklist

Before running `./burble-launcher.sh` (or equivalent) in production:

- [ ] All secrets in the table above are generated on the deployment
      host and stored in a secret manager (not in `.env` files
      checked into git).
- [ ] TLS posture matches the in-transit table above.
- [ ] Storage volume is FDE-encrypted (LUKS, dm-crypt, cloud KMS).
- [ ] Reverse proxy enforces HSTS and TLS 1.3.
- [ ] Container image signature verified (cosign).
- [ ] Health endpoint `/api/v1/health` is reachable but not exposed
      with internal-only routes.
- [ ] Default admin password is changed on first boot.
- [ ] Audit log destination is set and Vext chain start is recorded.
- [ ] Backup plan covers the database key — losing it is irrecoverable.

## Threat-model cross-reference

This checklist operationalises the mitigations side of
`docs/architecture/THREAT-MODEL.adoc`. When the threat model adds an
asset or trust boundary, add the corresponding deployment-time
control here.

## See also

- `QUICKSTART-MAINTAINER.adoc` — release process
- `docs/architecture/THREAT-MODEL.adoc` — STRIDE analysis
- `docs/decisions/0003-pake-sas-tiered-auth.adoc` — auth tiers
- `docs/decisions/0004-bolt-quic-dual-bind.adoc` — QUIC posture
- `SECURITY.md` — vulnerability disclosure
