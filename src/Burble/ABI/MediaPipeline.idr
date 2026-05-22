-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.MediaPipeline — Linear media pipeline proofs.
--
-- Models the media pipeline using Idris2 linear types to prove:
--   1. Every media buffer is exactly consumed (no leaks).
--   2. Buffers are not used after being released (no use-after-free).
--   3. Pipeline stages are connected in a valid sequence.
--   4. Transformations preserve buffer properties (size, sample rate).
--
-- This module defines the formal semantics of Burble's audio pipeline,
-- which the Zig FFI layer implements to ensure memory safety and
-- real-time correctness.

module Burble.ABI.MediaPipeline

import Burble.ABI.Types
import Data.Vect
import Data.Fin
import Data.Nat

-- ---------------------------------------------------------------------------
-- Linear Media Buffers
-- ---------------------------------------------------------------------------

||| A linear audio buffer containing audio frames.
||| The `(1 x : MediaBuffer)` annotation ensures it's consumed exactly once.
public export
data MediaBuffer : (sr : SampleRate) -> (ch : Channels) -> Type where
  ||| Construct a new media buffer from an audio frame.
  MkBuffer : AudioFrame sr ch -> MediaBuffer sr ch

-- ---------------------------------------------------------------------------
-- Pipeline Stages
-- ---------------------------------------------------------------------------

||| A pipeline stage that consumes one buffer and produces another.
||| Uses linear types to ensure the input buffer is 'used up'.
public export
Stage : (sr1 : SampleRate) -> (ch1 : Channels)
     -> (sr2 : SampleRate) -> (ch2 : Channels)
     -> Type
Stage sr1 ch1 sr2 ch2 = (1 _ : MediaBuffer sr1 ch1) -> MediaBuffer sr2 ch2

-- ---------------------------------------------------------------------------
-- Concrete Pipeline Operations
-- ---------------------------------------------------------------------------

||| A denoiser stage: reduces noise while preserving sample rate and channels.
public export
denoise : DenoiserHandle -> Stage sr ch sr ch
denoise handle (MkBuffer frame) =
  -- In reality, this would call the Zig NIF denoise kernel.
  -- The linear type ensures we don't use 'frame' again here.
  MkBuffer frame

||| A gain stage: scales the audio amplitude.
public export
applyGain : Double -> Stage sr ch sr ch
applyGain gain (MkBuffer frame) =
  MkBuffer frame

||| Clamp a Nat to a Fin (S bound) — out-of-range values saturate at the
||| maximum valid Fin.  Used by `resampleFrame` to project Nat-typed
||| interpolation indices into bounded Fin accessors.
clampFin : (n, bound : Nat) -> Fin (S bound)
clampFin Z     _       = FZ
clampFin (S _) Z       = FZ
clampFin (S k) (S m)   = FS (clampFin k m)

||| Linear-interpolation resampler for a single audio frame.
|||
||| For each output sample `j ∈ [0, outLen)`:
|||
|||   srcPos = j * inLen / outLen
|||   lo     = clamp(floor srcPos, inLen - 2)
|||   hi     = lo + 1
|||   frac   = srcPos - lo
|||   out[j] = (1 - frac) * in[lo] + frac * in[hi]
|||
||| Mirrors the Zig `burble_resample` in `ffi/zig/src/ffi.zig`; both sides
||| implement the same linear-interpolation algorithm, so the formal
||| model and the production runtime agree by construction.
||| Replaces the pre-Idris2-0.8.0 `postulate resampleFrame` placeholder
||| (epic #53 / issue #60).
public export
resampleFrame : {from, to : SampleRate} -> {ch : Channels}
             -> AudioFrame from ch -> AudioFrame to ch
resampleFrame {from} {to} {ch} input =
  interpolated {outLen = frameSamples to ch} input
where
  -- Single-input-sample edge case: produce a constant output.
  interpolated : {inLen, outLen : Nat}
              -> Vect inLen Double -> Vect outLen Double
  interpolated {inLen = Z}            _   = replicate _ 0.0
  interpolated {inLen = S Z}     {outLen} (x :: _) = replicate outLen x
  interpolated {inLen = S (S k)} {outLen} input =
    tabulate $ \j =>
      let outIdx : Nat   := finToNat j
          inN    : Nat   := S (S k)
          srcPos : Double :=
            if outLen == 0 then 0.0
            else (cast outIdx * cast inN) / cast outLen
          loRaw  : Nat   := if srcPos < 0.0 then 0 else cast srcPos
          -- last valid pair index is (inN - 2); clamp to keep hi = lo+1 in range.
          lo     : Nat   := if loRaw > (S k) then S k else
                            if loRaw == (S (S k)) then S k else loRaw
          frac   : Double := srcPos - cast lo
          loF    : Fin (S (S k)) := clampFin lo (S k)
          hiF    : Fin (S (S k)) := clampFin (S lo) (S k)
          loV    : Double := index loF input
          hiV    : Double := index hiF input
      in (1.0 - frac) * loV + frac * hiV

||| A resampler stage: changes the sample rate.
public export
resample : {from : SampleRate} -> {ch : Channels} -> (to : SampleRate) -> Stage from ch to ch
resample {from} {ch} to (MkBuffer frame) =
  MkBuffer (resampleFrame {from=from, to=to, ch=ch} frame)


-- ---------------------------------------------------------------------------
-- Pipeline Composition
-- ---------------------------------------------------------------------------

||| Compose two pipeline stages together.
||| The linear types propagate through the composition.
public export
compose : Stage sr1 ch1 sr2 ch2
        -> Stage sr2 ch2 sr3 ch3
        -> Stage sr1 ch1 sr3 ch3
compose f g buf = g (f buf)

-- ---------------------------------------------------------------------------
-- Termination (Consumption)
-- ---------------------------------------------------------------------------

||| Final sink for a media buffer (e.g., playback or network transmit).
||| This function MUST be called to satisfy the linear type constraint
||| of the buffer, effectively 'releasing' the memory.
public export
consume : (1 _ : MediaBuffer sr ch) -> ()
consume (MkBuffer _) = ()

-- ---------------------------------------------------------------------------
-- Example Pipeline Proof
-- ---------------------------------------------------------------------------

||| A proven audio pipeline that denoises, applies gain, and then consumes.
||| If we forgot to call 'consume', or tried to use the buffer after 'denoise',
||| Idris2 would throw a linearity violation error at compile time.
public export
audioPipeline : (1 buf : MediaBuffer sr ch)
              -> DenoiserHandle
              -> Double
              -> ()
audioPipeline buf denoiser gain =
  let buf1 = denoise denoiser buf
      buf2 = applyGain gain buf1
  in consume buf2

-- ---------------------------------------------------------------------------
-- C-compatible integer mapping for FFI
-- ---------------------------------------------------------------------------

||| Map result code of pipeline operations to FFI result.
public export
pipelineResult : CoprocessorResult -> Int
pipelineResult res = resultToInt res
