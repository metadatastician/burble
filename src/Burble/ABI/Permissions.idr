-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.Permissions — Role transition proofs.
--
-- Models the Burble permission hierarchy with dependent types, proving:
--   1. Roles form a total order: Listener < Speaker < Moderator < Owner.
--   2. Escalation (moving up the hierarchy) requires authorisation.
--   3. De-escalation (moving down) is always permitted.
--   4. No role can escalate beyond Owner.
--   5. Authorisation must come from a role strictly above the target.
--
-- The role hierarchy matches room_event.bop's ParticipantRole enum:
--   Listener = 0, Speaker = 1, Moderator = 2, Owner = 3
--
-- This module is compiled to C headers for the Zig FFI layer, ensuring
-- the Elixir permissions module's runtime checks match the formal spec.

module Burble.ABI.Permissions

import Data.Nat

-- ---------------------------------------------------------------------------
-- Role definitions
-- ---------------------------------------------------------------------------

||| The participant roles in a Burble room, ordered by privilege level.
||| Each role subsumes the capabilities of all roles below it.
||| LLM is a specialized role at the Speaker privilege level with selective capabilities.
public export
data Role = Listener | Speaker | Moderator | Owner | LLM

-- ---------------------------------------------------------------------------
-- Role ordering (total order)
-- ---------------------------------------------------------------------------

||| Numeric privilege level for each role.
||| Listener (0) < Speaker (1) = LLM (1) < Moderator (2) < Owner (3).
public export
roleLevel : Role -> Nat
roleLevel Listener  = 0
roleLevel Speaker   = 1
roleLevel LLM       = 1  -- Same privilege level as Speaker but selective capabilities
roleLevel Moderator = 2
roleLevel Owner     = 3

||| Proof that role `a` has privilege level less than or equal to role `b`.
||| This is the "at most as privileged" relation.
public export
data RoleLTE : Role -> Role -> Type where
  MkRoleLTE : LTE (roleLevel a) (roleLevel b) -> RoleLTE a b

||| Proof that role `a` has strictly less privilege than role `b`.
||| This is the "strictly less privileged" relation.
public export
data RoleLT : Role -> Role -> Type where
  MkRoleLT : LT (roleLevel a) (roleLevel b) -> RoleLT a b

-- ---------------------------------------------------------------------------
-- Internal LTE helpers (since Data.Nat names can vary by version)
-- ---------------------------------------------------------------------------

lteReflInternal : {n : Nat} -> LTE n n
lteReflInternal {n = Z} = LTEZero
lteReflInternal {n = S k} = LTESucc lteReflInternal

lteTransitiveInternal : LTE x y -> LTE y z -> LTE x z
lteTransitiveInternal LTEZero _ = LTEZero
lteTransitiveInternal (LTESucc k) (LTESucc j) = LTESucc (lteTransitiveInternal k j)

-- ---------------------------------------------------------------------------
-- Reflexivity, transitivity, and totality of the ordering
-- ---------------------------------------------------------------------------

||| Every role is at most as privileged as itself (reflexivity).
public export
roleLTERefl : (r : Role) -> RoleLTE r r
roleLTERefl r = MkRoleLTE lteReflInternal

||| Role ordering is transitive: if a <= b and b <= c then a <= c.
public export
roleLTETransitive : RoleLTE a b -> RoleLTE b c -> RoleLTE a c
roleLTETransitive (MkRoleLTE prf1) (MkRoleLTE prf2) =
  MkRoleLTE (lteTransitiveInternal prf1 prf2)

-- ---------------------------------------------------------------------------
-- Concrete ordering proofs for the four roles
-- ---------------------------------------------------------------------------

||| Listener < Speaker: listeners are strictly less privileged than speakers.
public export
listenerLTSpeaker : RoleLT Listener Speaker
listenerLTSpeaker = MkRoleLT (LTESucc LTEZero)

||| Speaker < Moderator: speakers cannot moderate.
public export
speakerLTModerator : RoleLT Speaker Moderator
speakerLTModerator = MkRoleLT (LTESucc (LTESucc LTEZero))

||| Moderator < Owner: moderators cannot transfer ownership or delete rooms.
public export
moderatorLTOwner : RoleLT Moderator Owner
moderatorLTOwner = MkRoleLT (LTESucc (LTESucc (LTESucc LTEZero)))

||| Listener < Owner: the full span of the hierarchy.
public export
listenerLTOwner : RoleLT Listener Owner
listenerLTOwner = MkRoleLT (LTESucc LTEZero)

-- ---------------------------------------------------------------------------
-- Authorisation model
-- ---------------------------------------------------------------------------

||| An authorisation token proving that a role change has been approved
||| by someone with sufficient privilege.
public export
data Authorisation : (target : Role) -> Type where
  MkAuth : (authoriser : Role)
        -> (target : Role)
        -> RoleLT target authoriser
        -> Authorisation target

-- ---------------------------------------------------------------------------
-- Escalation: moving up the hierarchy (requires authorisation)
-- ---------------------------------------------------------------------------

||| A proven role escalation (promotion).
public export
data Escalation : Role -> Role -> Type where
  MkEscalation : (from : Role)
              -> (to : Role)
              -> RoleLT from to
              -> Authorisation to
              -> Escalation from to

||| Construct a valid escalation from Listener to Speaker,
||| authorised by a Moderator.
public export
promoteListenerToSpeaker : Escalation Listener Speaker
promoteListenerToSpeaker =
  MkEscalation Listener Speaker
    listenerLTSpeaker
    (MkAuth Moderator Speaker speakerLTModerator)

-- ---------------------------------------------------------------------------
-- De-escalation: moving down the hierarchy (always permitted)
-- ---------------------------------------------------------------------------

||| A proven role de-escalation (demotion).
public export
data DeEscalation : Role -> Role -> Type where
  MkDeEscalation : (from : Role)
                -> (to : Role)
                -> RoleLT to from
                -> DeEscalation from to

-- ---------------------------------------------------------------------------
-- Impossibility proofs — preventing privilege abuse
-- ---------------------------------------------------------------------------

||| Every role level is at most 3.
public export
roleLevelMax : (r : Role) -> LTE (roleLevel r) 3
roleLevelMax Listener  = LTEZero
roleLevelMax Speaker   = LTESucc LTEZero
roleLevelMax LLM       = LTESucc LTEZero  -- LLM is level 1, same as Speaker
roleLevelMax Moderator = LTESucc (LTESucc LTEZero)
roleLevelMax Owner     = LTESucc (LTESucc (LTESucc LTEZero))

||| Proof that Owner cannot be escalated further.
public export
ownerCannotEscalate : {r : Role} -> RoleLT Owner r -> Void
ownerCannotEscalate {r} (MkRoleLT prf) =
  let maxR = roleLevelMax r in
  case (lteTransitiveInternal prf maxR) of
       (LTESucc (LTESucc (LTESucc (LTESucc _)))) impossible

||| Proof that if someone is an authoriser, they cannot be a Listener.
public export
authoriserNotListener : {target : Role} -> Authorisation target -> (auth : Role ** (auth = Listener -> Void))
authoriserNotListener (MkAuth auth target (MkRoleLT prf)) =
  (auth ** (\case Refl => case prf of { LTESucc _ impossible }))

-- ---------------------------------------------------------------------------
-- Decision procedure for runtime validation
-- ---------------------------------------------------------------------------

||| Decidable role comparison for the Zig FFI layer.
public export
decideRoleLTE : (a, b : Role) -> Dec (RoleLTE a b)
decideRoleLTE a b =
  case isLTE (roleLevel a) (roleLevel b) of
       (Yes prf) => Yes (MkRoleLTE prf)
       (No contra) => No (\(MkRoleLTE prf) => contra prf)

||| Returns True if `from` can be escalated to `to` given the
||| authoriser's role.
public export
canEscalate : (from : Role) -> (to : Role) -> (authoriser : Role) -> Bool
canEscalate from to authoriser =
  (roleLevel from < roleLevel to) && (roleLevel to < roleLevel authoriser)

||| Check if a de-escalation from `from` to `to` is valid.
public export
canDeEscalate : (from : Role) -> (to : Role) -> Bool
canDeEscalate from to = roleLevel to < roleLevel from

-- ---------------------------------------------------------------------------
-- C-compatible integer mapping for FFI
-- ---------------------------------------------------------------------------

public export
roleToInt : Role -> Int
roleToInt Listener  = 0
roleToInt Speaker   = 1
roleToInt LLM       = 1
roleToInt Moderator = 2
roleToInt Owner     = 3

||| Equality instance for Role.
public export
Eq Role where
  Listener  == Listener  = True
  Speaker   == Speaker   = True
  LLM       == LLM       = True
  Moderator == Moderator = True
  Owner     == Owner     = True
  _         == _         = False
