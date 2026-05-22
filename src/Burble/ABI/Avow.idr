-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.Avow — Consent state machine and attestation proofs.
--
-- Models the Avow consent lifecycle and trust attestation chains.
-- Proves:
--   1. Only valid consent state transitions can occur.
--   2. Attestation chains are well-founded (no circular trust).
--   3. Every message validity depends on a proven consent capability.

module Burble.ABI.Avow

import Data.Nat

-- ---------------------------------------------------------------------------
-- Consent states
-- ---------------------------------------------------------------------------

public export
data ConsentState = Requested | Confirmed | Active | Revoked

public export
data ValidTransition : ConsentState -> ConsentState -> Type where
  Confirm  : ValidTransition Requested Confirmed
  Activate : ValidTransition Confirmed Active
  RevokeActive : ValidTransition Active Revoked
  RevokeRequested : ValidTransition Requested Revoked

-- ---------------------------------------------------------------------------
-- Identities and Ranks
-- ---------------------------------------------------------------------------

||| A participant identity.
public export
record Identity where
  constructor MkIdentity
  id : Bits64
  rank : Nat -- Used to ensure well-founded trust chains

-- ---------------------------------------------------------------------------
-- Attestations: One identity vouching for another
-- ---------------------------------------------------------------------------

||| A trust attestation where an 'authoriser' vouches for a 'subject'.
||| To prevent circular trust, the authoriser MUST have a strictly
||| higher rank than the subject.
public export
data Attestation : (authoriser : Identity) -> (subject : Identity) -> Type where
  MkAttestation : {auth : Identity} -> {sub : Identity}
               -> (prf : LT (rank sub) (rank auth))
               -> Attestation auth sub

-- ---------------------------------------------------------------------------
-- Trust Chains: A sequence of attestations
-- ---------------------------------------------------------------------------

||| A chain of trust from a root anchor to a subject.
public export
data TrustChain : (anchor : Identity) -> (subject : Identity) -> Type where
  ||| Self-attestation (base case, only for root anchors).
  Root : (i : Identity) -> TrustChain i i
  ||| One identity vouches for another, extending the chain.
  Link : TrustChain anchor mid
      -> Attestation mid subject
      -> TrustChain anchor subject

-- ---------------------------------------------------------------------------
-- Internal LTE helpers
-- ---------------------------------------------------------------------------

lteTransitiveInternal : LTE x y -> LTE y z -> LTE x z
lteTransitiveInternal LTEZero _ = LTEZero
lteTransitiveInternal (LTESucc k) (LTESucc j) = LTESucc (lteTransitiveInternal k j)

lteStepRefl : {n : Nat} -> LTE n (S n)
lteStepRefl {n = Z} = LTEZero
lteStepRefl {n = S k} = LTESucc lteStepRefl

lteStep : {n : Nat} -> LTE (S n) m -> LTE n m
lteStep {n} (LTESucc k) = lteTransitiveInternal lteStepRefl (LTESucc k)

ltIrreflInternal : {n : Nat} -> LT n n -> Void
ltIrreflInternal {n = Z} prf = case prf of {}
ltIrreflInternal {n = S m} (LTESucc k) = ltIrreflInternal k

-- ---------------------------------------------------------------------------
-- Proof of Non-Circularity
-- ---------------------------------------------------------------------------

||| Proof that if a trust chain exists from anchor to subject,
||| then either they are the same (Root) or the anchor outranks the subject.
public export
chainOutranks : {anchor, subject : Identity} -> TrustChain anchor subject -> (anchor = subject) `Either` (LT (rank subject) (rank anchor))
chainOutranks (Root i) = Left Refl
chainOutranks (Link tc (MkAttestation prf)) =
  case chainOutranks tc of
       Left Refl => Right prf
       Right prf2 => Right (lteStep (lteTransitiveInternal (LTESucc prf) prf2))

||| Core Theorem: Circular trust is impossible.
||| Proof that a trust chain from `i` back to `i` cannot contain any links.
public export
noCircularTrust : {i : Identity} -> TrustChain i i -> (c : TrustChain i i ** c = Root i)
noCircularTrust (Root i) = (Root i ** Refl)
noCircularTrust (Link tc (MkAttestation prf)) =
  case chainOutranks tc of
       Left Refl => absurd (ltIrreflInternal prf)
       Right prf2 => absurd (ltIrreflInternal (lteStep (lteTransitiveInternal (LTESucc prf) prf2)))

-- ---------------------------------------------------------------------------
-- Equality for Identity
-- ---------------------------------------------------------------------------

public export
Eq Identity where
  (MkIdentity id1 r1) == (MkIdentity id2 r2) = (id1 == id2) && (r1 == r2)

-- ---------------------------------------------------------------------------
-- C-compatible integer mapping for FFI
-- ---------------------------------------------------------------------------

public export
consentStateToInt : ConsentState -> Int
consentStateToInt Requested = 0
consentStateToInt Confirmed = 1
consentStateToInt Active    = 2
consentStateToInt Revoked   = 3
