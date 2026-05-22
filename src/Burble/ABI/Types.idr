-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.Types — Coprocessor ABI type definitions.
--
-- Defines the type-safe interface between Elixir (BEAM) and Zig (FFI).
-- Dependent types guarantee that:
--   1. Buffer sizes are always valid (non-zero, power-of-2 for FFT)
--   2. Sample rates are in the supported set (8000, 16000, 48000)
--   3. Channel counts are exactly 1 or 2
--   4. Key sizes match the algorithm requirements (32 bytes for AES-256)
--   5. Error handling is total — no unhandled failure modes
--
-- These types are compiled to C headers (generated/abi/) which the Zig
-- FFI layer includes for type-safe function signatures.

module Burble.ABI.Types

import Data.Fin
import Data.Vect

-- ---------------------------------------------------------------------------
-- Result codes
-- ---------------------------------------------------------------------------

||| Result code returned by all coprocessor FFI functions.
||| Maps to C enum for ABI stability.
public export
data CoprocessorResult
  = Ok               -- 0: Success
  | Error             -- 1: Generic error
  | InvalidParam      -- 2: Invalid parameter
  | BufferTooSmall    -- 3: Output buffer too small
  | NotInitialised    -- 4: Kernel not initialised
  | CodecError        -- 5: Audio codec failure
  | CryptoError       -- 6: Cryptographic operation failure
  | OutOfMemory       -- 7: Allocation failure

||| Convert result to C-compatible integer.
public export
resultToInt : CoprocessorResult -> Int
resultToInt Ok             = 0
resultToInt Error          = 1
resultToInt InvalidParam   = 2
resultToInt BufferTooSmall = 3
resultToInt NotInitialised = 4
resultToInt CodecError     = 5
resultToInt CryptoError    = 6
resultToInt OutOfMemory    = 7

-- ---------------------------------------------------------------------------
-- Audio types with dependent constraints
-- ---------------------------------------------------------------------------

||| Supported sample rates. Only these values are valid.
public export
data SampleRate = Hz8000 | Hz16000 | Hz48000

||| Convert sample rate to integer.
public export
sampleRateToInt : SampleRate -> Int
sampleRateToInt Hz8000  = 8000
sampleRateToInt Hz16000 = 16000
sampleRateToInt Hz48000 = 48000

||| Channel count — exactly 1 (mono) or 2 (stereo).
public export
data Channels = Mono | Stereo

||| Convert channels to integer.
public export
channelsToInt : Channels -> Int
channelsToInt Mono   = 1
channelsToInt Stereo = 2

||| Audio frame size calculation.
public export
frameSamples : SampleRate -> Channels -> Nat
frameSamples Hz48000 Mono   = 960
frameSamples Hz48000 Stereo = 1920
frameSamples Hz16000 Mono   = 320
frameSamples Hz16000 Stereo = 640
frameSamples Hz8000  Mono   = 160
frameSamples Hz8000  Stereo = 320

||| Audio frame with compile-time size guarantee.
public export
AudioFrame : SampleRate -> Channels -> Type
AudioFrame sr ch = Vect (frameSamples sr ch) Double

-- ---------------------------------------------------------------------------
-- Crypto types with size constraints
-- ---------------------------------------------------------------------------

||| AES-256-GCM key — exactly 32 bytes.
public export
AESKey : Type
AESKey = Vect 32 Bits8

||| AES-GCM IV (nonce) — exactly 12 bytes.
public export
AESIV : Type
AESIV = Vect 12 Bits8

||| AES-GCM authentication tag — exactly 16 bytes.
public export
AESTag : Type
AESTag = Vect 16 Bits8

||| SHA-256 hash — exactly 32 bytes.
public export
SHA256Hash : Type
SHA256Hash = Vect 32 Bits8

-- ---------------------------------------------------------------------------
-- DSP types
-- ---------------------------------------------------------------------------

||| Proof that a natural number is a power of 2.
||| Required for FFT size arguments.
public export
data IsPowerOf2 : Nat -> Type where
  P1    : IsPowerOf2 1
  PDouble : IsPowerOf2 n -> IsPowerOf2 (n + n)

public export
data FFTSize : Type where
  MkFFTSize : (n : Nat) -> IsPowerOf2 n -> FFTSize

-- ---------------------------------------------------------------------------
-- Opaque handles
-- ---------------------------------------------------------------------------

||| Opaque handle to a coprocessor kernel instance.
||| The Zig side allocates and manages the actual state.
public export
data KernelHandle : Type where
  MkHandle : (tag : String) -> (id : Bits64) -> KernelHandle

||| Opaque handle to a denoiser model instance.
public export
DenoiserHandle : Type
DenoiserHandle = KernelHandle

||| Opaque handle to a jitter buffer instance.
public export
JitterBufferHandle : Type
JitterBufferHandle = KernelHandle
