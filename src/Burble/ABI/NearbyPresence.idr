-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.NearbyPresence — presence zones + resolution proofs.
--
-- Design-assurance mirror (ADR-0008) of the presence-beacon visibility rules
-- in ADR-0010 (resolution precedence: block > allow > zone) and ADR-0015 D5/D6.
-- Compiles via `just build-proofs`; idris2 is not in CI. Proves that a blocked
-- contact is never resolvable and that the Off mode emits nothing, for every
-- zone and policy.

module Burble.ABI.NearbyPresence

||| Presence emission mode (ADR-0010). Off is the default: an unaware user is
||| public-safe.
public export
data PresenceMode = Off | Silent | Presence

||| Trust zones (ADR-0010).
public export
data Zone = Public | Private | TrustedByNature | TrustedByYou

||| Per-contact resolution policy (ADR-0010). Precedence: block > allow > zone.
public export
data ContactPolicy = Blocked | Allowed | Unspecified

||| What an observer can learn about the emitter.
public export
data Visibility = Hidden | Resolvable

||| Frozen presence-beacon rotation period (ADR-0015 D5), seconds.
public export
epochSeconds : Nat
epochSeconds = 900

||| Frozen beacon-id truncation (ADR-0015 D5), bytes.
public export
beaconIdBytes : Nat
beaconIdBytes = 18

||| Resolve the visibility of the emitter to a given contact.
|||
||| Order encodes the precedence: Off emits nothing at all; then block
||| dominates; then Silent has no standing beacon (rendezvous only); then a
||| contact-resolvable beacon exists only for allowed contacts in the
||| presence-bearing zones.
public export
resolve : ContactPolicy -> Zone -> PresenceMode -> Visibility
resolve _ _ Off = Hidden                       -- Off: emit nothing, ever
resolve Blocked _ _ = Hidden                    -- block dominates allow and zone
resolve _ _ Silent = Hidden                     -- Silent: knock rendezvous, no beacon
resolve Allowed Private Presence = Resolvable
resolve Allowed TrustedByNature Presence = Resolvable
resolve Allowed TrustedByYou Presence = Resolvable
resolve Allowed Public Presence = Hidden        -- Public zone carries no standing beacon
resolve Unspecified _ Presence = Hidden          -- unknown contacts never resolve you

||| A blocked contact is never resolvable — for any zone, any mode. This is the
||| ADR-0010 invariant that makes "block = cryptographic secret rotation" the
||| real safety property rather than a UI nicety.
public export
blockedNeverVisible : (z : Zone) -> (m : PresenceMode) -> resolve Blocked z m = Hidden
blockedNeverVisible _ Off = Refl
blockedNeverVisible _ Silent = Refl
blockedNeverVisible _ Presence = Refl

||| Off emits nothing, for any policy and any zone (public-safe default).
public export
offEmitsNothing : (p : ContactPolicy) -> (z : Zone) -> resolve p z Off = Hidden
offEmitsNothing _ _ = Refl
