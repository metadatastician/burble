<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly.

**Email:** j.d.a.jewell@open.ac.uk

**Please include:**
- Description of the vulnerability
- Steps to reproduce
- Potential impact

**Response timeline:**
- Acknowledgement within 48 hours
- Initial assessment within 7 days
- Fix or mitigation within 90 days

**Safe harbour:** We will not pursue legal action against security researchers who follow responsible disclosure.

## Security Architecture

### Authentication
- Guardian JWT (HS256, upgrade to RS256 planned for distributed topology)
- Access tokens (1h) + refresh tokens (30d) with stateless rotation
- Bcrypt password hashing via bcrypt_elixir
- Password strength + common password validation via proven (Idris2 verified)
- Rate limiting via Hammer (ETS-backed)

### Authorization
- Role-based permissions (admin, moderator, member, guest)
- Channel-level allow/deny overrides
- Permission checks enforced in RoomChannel on every action

### Integrity
- Vext hash chains on all text messages (tamper-proof feed verification)
- Avow consent attestations on room join/leave
- SHA-256 hashing throughout (BLAKE2B removed for OTP portability)

### Privacy
- TURN-only default (no IP leakage via WebRTC candidates)
- E2EE capable (AES-256-GCM frame encryption in coprocessor pipeline)
- Four privacy modes: standard, turn_only, e2ee, maximum

### Coprocessor Safety
- All Zig NIFs passed panic-attack assail (0 weak points, 0 unsafe pointer casts)
- Safe serialization for cross-NIF state (no raw @ptrCast)
- 10MB decompression limit on LZ4 NIF
- ElixirBackend fallback for all operations

## Known Limitations
- Avow/Vext signatures use HMAC (placeholder — Ed25519 planned)
- Guardian uses symmetric key (HS256, not RS256)
- Magic link email sending not implemented (token generated, not sent)
- WebRTC SFU not yet wired (Membrane integration pending)
