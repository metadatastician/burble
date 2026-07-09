-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.BleSpa — BLE presence knock: byte layout + state-machine proofs.
--
-- Design-assurance mirror (ADR-0008) of the wire format frozen in ADR-0015 and
-- implemented in Burble.Presence.BleSpa. Compiles via `just build-proofs`;
-- idris2 is not in CI, so this is design assurance, not a runtime gate. Proves
-- the knock frame exactly tiles its 24-byte payload and that the rendezvous
-- state machine cannot reach Paired without completing the knock → await
-- handshake.

module Burble.ABI.BleSpa

import Data.Vect

public export
KnockByte : Type
KnockByte = Bits8

||| The knock frame's cleartext fields. `magic` and `ver_type` are frozen
||| constants folded into the layout proof rather than carried as fields.
public export
record KnockFrame where
  constructor MkKnock
  ts    : Bits32
  nonce : Vect 6 KnockByte
  mac   : Vect 12 KnockByte

-- ---------------------------------------------------------------------------
-- Byte layout (ADR-0015 D2/D3): envelope(6) ++ nonce(6) ++ mac(12) = 24.
-- ---------------------------------------------------------------------------

public export
envelopeBytes : Nat
envelopeBytes = 6   -- magic(1) + ver_type(1) + ts(4)

public export
nonceBytes : Nat
nonceBytes = 6

public export
macBytes : Nat
macBytes = 12

public export
payloadBytes : Nat
payloadBytes = 24

||| The knock fields exactly tile the frozen 24-byte payload.
public export
knockLayoutTotal : envelopeBytes + nonceBytes + macBytes = payloadBytes
knockLayoutTotal = Refl

||| The MAC truncation is 96 bits (ADR-0015 D3).
public export
macIs96Bits : macBytes * 8 = 96
macIs96Bits = Refl

-- ---------------------------------------------------------------------------
-- Rendezvous state machine (ADR-0015 D6).
-- ---------------------------------------------------------------------------

public export
data KnockState
  = Idle       -- no knock in flight (also the Off/Silent-idle emitting state)
  | Knocking   -- broadcasting the ~2s knock
  | Awaiting   -- knock sent; scanning for a matching response token
  | Paired     -- response matched; hand off to the CoC (ADR-0003)

public export
data ValidTransition : KnockState -> KnockState -> Type where
  BeginKnock    : ValidTransition Idle Knocking
  KnockSent     : ValidTransition Knocking Awaiting
  ResponseMatch : ValidTransition Awaiting Paired
  -- timeouts collapse back to Idle (covert-by-default)
  KnockTimeout  : ValidTransition Knocking Idle
  AwaitTimeout  : ValidTransition Awaiting Idle
  -- teardown
  Disconnect    : ValidTransition Paired Idle

||| Pairing cannot happen straight from Idle — a knock must be sent first.
public export
noIdleToPaired : ValidTransition Idle Paired -> Void
noIdleToPaired _ impossible

||| Pairing cannot happen straight from Knocking — you must be Awaiting first.
public export
noKnockingToPaired : ValidTransition Knocking Paired -> Void
noKnockingToPaired _ impossible

||| Idle → Idle is not a transition (a silent peer simply emits nothing).
public export
noIdleToIdle : ValidTransition Idle Idle -> Void
noIdleToIdle _ impossible

public export
data Rendezvous : KnockState -> KnockState -> Type where
  Here : Rendezvous s s
  Step : ValidTransition s mid -> Rendezvous mid t -> Rendezvous s t

||| The canonical happy path: Idle → Knocking → Awaiting → Paired.
public export
knockCycle : Rendezvous Idle Paired
knockCycle = Step BeginKnock (Step KnockSent (Step ResponseMatch Here))

public export
tryTransition : (from : KnockState) -> (to : KnockState)
             -> Maybe (ValidTransition from to)
tryTransition Idle Knocking = Just BeginKnock
tryTransition Knocking Awaiting = Just KnockSent
tryTransition Awaiting Paired = Just ResponseMatch
tryTransition Knocking Idle = Just KnockTimeout
tryTransition Awaiting Idle = Just AwaitTimeout
tryTransition Paired Idle = Just Disconnect
tryTransition _ _ = Nothing

||| C-compatible integer mapping for the FFI boundary.
public export
stateToInt : KnockState -> Int
stateToInt Idle = 0
stateToInt Knocking = 1
stateToInt Awaiting = 2
stateToInt Paired = 3
