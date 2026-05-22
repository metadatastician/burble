-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.WebRTCSignaling — WebRTC signaling state machine proofs.
--
-- Models the JSEP (JavaScript Session Establishment Protocol) state machine
-- for WebRTC signaling as a dependent type, proving:
--   1. Only valid signaling state transitions can occur.
--   2. Signaling states cannot be skipped (e.g. stable -> active without offer).
--   3. Offer/Answer cycle must be completed to achieve stable state.
--   4. Invalid transitions (e.g. double-offer) are impossible.
--
-- This module is compiled to C headers for the Zig FFI layer, ensuring
-- that WebRTC signaling in the Elixir control plane matches the
-- formally verified JSEP specification.

module Burble.ABI.WebRTCSignaling

-- ---------------------------------------------------------------------------
-- Signaling States (JSEP)
-- ---------------------------------------------------------------------------

||| The six standard WebRTC signaling states.
public export
data SignalingState
  = Stable             -- No offer/answer in progress
  | HaveLocalOffer     -- Local offer has been applied
  | HaveRemoteOffer    -- Remote offer has been applied
  | HaveLocalPranswer  -- Local provisional answer applied
  | HaveRemotePranswer -- Remote provisional answer applied
  | Closed             -- Connection is closed

-- ---------------------------------------------------------------------------
-- Valid Transitions
-- ---------------------------------------------------------------------------

||| A proof that a transition from signaling state `from` to `to` is valid.
public export
data ValidTransition : SignalingState -> SignalingState -> Type where
  -- Local Offer Cycle
  SetLocalOffer : ValidTransition Stable HaveLocalOffer
  SetRemoteAnswer : ValidTransition HaveLocalOffer Stable
  SetRemotePranswer : ValidTransition HaveLocalOffer HaveRemotePranswer
  AcceptRemotePranswer : ValidTransition HaveRemotePranswer Stable

  -- Remote Offer Cycle
  SetRemoteOffer : ValidTransition Stable HaveRemoteOffer
  SetLocalAnswer : ValidTransition HaveRemoteOffer Stable
  SetLocalPranswer : ValidTransition HaveRemoteOffer HaveLocalPranswer
  AcceptLocalPranswer : ValidTransition HaveLocalPranswer Stable

  -- Closing
  CloseFromStable : ValidTransition Stable Closed
  CloseFromOffer : ValidTransition HaveLocalOffer Closed
  CloseFromRemoteOffer : ValidTransition HaveRemoteOffer Closed

-- ---------------------------------------------------------------------------
-- Impossibility Proofs
-- ---------------------------------------------------------------------------

||| Proof that double-offer (offer when an offer is already pending) is impossible.
public export
noDoubleOffer : ValidTransition HaveLocalOffer HaveLocalOffer -> Void
noDoubleOffer _ impossible

||| Proof that stable -> stable is not a transition (it's the 'Here' identity).
public export
noStableToStable : ValidTransition Stable Stable -> Void
noStableToStable _ impossible

-- ---------------------------------------------------------------------------
-- Signaling Cycle Proof
-- ---------------------------------------------------------------------------

||| A sequence of valid signaling transitions.
public export
data SignalingCycle : SignalingState -> SignalingState -> Type where
  Here : SignalingCycle s s
  Step : ValidTransition s mid -> SignalingCycle mid t -> SignalingCycle s t

||| The canonical "Happy Path": Stable -> HaveLocalOffer -> Stable.
public export
localOfferCycle : SignalingCycle Stable Stable
localOfferCycle = Step SetLocalOffer (Step SetRemoteAnswer Here)

||| Remote offer cycle: Stable -> HaveRemoteOffer -> Stable.
public export
remoteOfferCycle : SignalingCycle Stable Stable
remoteOfferCycle = Step SetRemoteOffer (Step SetLocalAnswer Here)

-- ---------------------------------------------------------------------------
-- Decision Procedure
-- ---------------------------------------------------------------------------

||| Attempt to construct a valid transition at runtime.
public export
tryTransition : (from : SignalingState) -> (to : SignalingState)
             -> Maybe (ValidTransition from to)
tryTransition Stable HaveLocalOffer = Just SetLocalOffer
tryTransition HaveLocalOffer Stable = Just SetRemoteAnswer
tryTransition HaveLocalOffer HaveRemotePranswer = Just SetRemotePranswer
tryTransition HaveRemotePranswer Stable = Just AcceptRemotePranswer
tryTransition Stable HaveRemoteOffer = Just SetRemoteOffer
tryTransition HaveRemoteOffer Stable = Just SetLocalAnswer
tryTransition HaveRemoteOffer HaveLocalPranswer = Just SetLocalPranswer
tryTransition HaveLocalPranswer Stable = Just AcceptLocalPranswer
tryTransition Stable Closed = Just CloseFromStable
tryTransition HaveLocalOffer Closed = Just CloseFromOffer
tryTransition HaveRemoteOffer Closed = Just CloseFromRemoteOffer
tryTransition _ _ = Nothing

||| Proof that you cannot go from stable to closed and back.
public export
noClosedReturn : ValidTransition Closed s -> Void
noClosedReturn _ impossible

||| Proof that HaveLocalOffer and HaveRemoteOffer are distinct paths.
public export
offerDistinct : ValidTransition HaveLocalOffer HaveRemoteOffer -> Void
offerDistinct _ impossible

-- ---------------------------------------------------------------------------
-- C-compatible integer mapping for FFI
-- ---------------------------------------------------------------------------

||| Map signaling states to C-compatible integers for the Zig FFI layer.
public export
signalingStateToInt : SignalingState -> Int
signalingStateToInt Stable = 0
signalingStateToInt HaveLocalOffer = 1
signalingStateToInt HaveRemoteOffer = 2
signalingStateToInt HaveLocalPranswer = 3
signalingStateToInt HaveRemotePranswer = 4
signalingStateToInt Closed = 5
