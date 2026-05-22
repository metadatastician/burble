-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
||| Foreign Function Interface Declarations
|||
||| This module declares all C-compatible functions that will be
||| implemented in the Zig FFI layer (ffi/zig/src/coprocessor/).
|||
||| The Burble FFI exposes SIMD-accelerated audio processing kernels:
|||   - Audio: Opus codec, noise gate, echo cancellation, AGC
|||   - DSP: FFT/IFFT, convolution, mixing matrix
|||   - Neural: spectral gating denoiser, noise classification
|||   - Compression: LZ4/zstd, FLAC-style, .barc recorder
|||   - Crypto: AES-256-GCM, SHA-256 chains, HKDF
|||
||| All functions are declared here with type signatures and safety proofs.
||| Implementations live in ffi/zig/

module Burble.ABI.Foreign

import Burble.ABI.Types
import Burble.ABI.Layout

%default total

--------------------------------------------------------------------------------
-- Library Lifecycle
--------------------------------------------------------------------------------

||| Initialize the library
||| Returns a handle to the library instance, or Nothing on failure
export
%foreign "C:burble_init, libburble"
prim__init : PrimIO Bits64

||| Safe wrapper for library initialization
export
init : IO (Maybe Handle)
init = do
  ptr <- primIO prim__init
  pure (createHandle ptr)

||| Clean up library resources
export
%foreign "C:burble_free, libburble"
prim__free : Bits64 -> PrimIO ()

||| Safe wrapper for cleanup
export
free : Handle -> IO ()
free h = primIO (prim__free (handlePtr h))

--------------------------------------------------------------------------------
-- Core Operations
--------------------------------------------------------------------------------

||| Example operation: process data
export
%foreign "C:burble_process, libburble"
prim__process : Bits64 -> Bits32 -> PrimIO Bits32

||| Safe wrapper with error handling
export
process : Handle -> Bits32 -> IO (Either Result Bits32)
process h input = do
  result <- primIO (prim__process (handlePtr h) input)
  pure $ case result of
    0 => Left Error
    n => Right n

--------------------------------------------------------------------------------
-- String Operations
--------------------------------------------------------------------------------

||| Convert C string to Idris String
export
%foreign "support:idris2_getString, libidris2_support"
prim__getString : Bits64 -> String

||| Free C string
export
%foreign "C:burble_free_string, libburble"
prim__freeString : Bits64 -> PrimIO ()

||| Get string result from library
export
%foreign "C:burble_get_string, libburble"
prim__getResult : Bits64 -> PrimIO Bits64

||| Safe string getter
export
getString : Handle -> IO (Maybe String)
getString h = do
  ptr <- primIO (prim__getResult (handlePtr h))
  if ptr == 0
    then pure Nothing
    else do
      let str = prim__getString ptr
      primIO (prim__freeString ptr)
      pure (Just str)

--------------------------------------------------------------------------------
-- Array/Buffer Operations
--------------------------------------------------------------------------------

||| Process array data
export
%foreign "C:burble_process_array, libburble"
prim__processArray : Bits64 -> Bits64 -> Bits32 -> PrimIO Bits32

||| Safe array processor
export
processArray : Handle -> (buffer : Bits64) -> (len : Bits32) -> IO (Either Result ())
processArray h buf len = do
  result <- primIO (prim__processArray (handlePtr h) buf len)
  pure $ case resultFromInt result of
    Just Ok => Right ()
    Just err => Left err
    Nothing => Left Error
  where
    resultFromInt : Bits32 -> Maybe Result
    resultFromInt 0 = Just Ok
    resultFromInt 1 = Just Error
    resultFromInt 2 = Just InvalidParam
    resultFromInt 3 = Just OutOfMemory
    resultFromInt 4 = Just NullPointer
    resultFromInt _ = Nothing

--------------------------------------------------------------------------------
-- Error Handling
--------------------------------------------------------------------------------

||| Get last error message
export
%foreign "C:burble_last_error, libburble"
prim__lastError : PrimIO Bits64

||| Retrieve last error as string
export
lastError : IO (Maybe String)
lastError = do
  ptr <- primIO prim__lastError
  if ptr == 0
    then pure Nothing
    else pure (Just (prim__getString ptr))

||| Get error description for result code
export
errorDescription : Result -> String
errorDescription Ok = "Success"
errorDescription Error = "Generic error"
errorDescription InvalidParam = "Invalid parameter"
errorDescription OutOfMemory = "Out of memory"
errorDescription NullPointer = "Null pointer"

--------------------------------------------------------------------------------
-- Version Information
--------------------------------------------------------------------------------

||| Get library version
export
%foreign "C:burble_version, libburble"
prim__version : PrimIO Bits64

||| Get version as string
export
version : IO String
version = do
  ptr <- primIO prim__version
  pure (prim__getString ptr)

||| Get library build info
export
%foreign "C:burble_build_info, libburble"
prim__buildInfo : PrimIO Bits64

||| Get build information
export
buildInfo : IO String
buildInfo = do
  ptr <- primIO prim__buildInfo
  pure (prim__getString ptr)

--------------------------------------------------------------------------------
-- Callback Support
--------------------------------------------------------------------------------

||| Audio processing event types from the Zig NIF ring buffer.
|||
||| The Zig NIF layer produces these events asynchronously during audio
||| processing. They are written to a lock-free ring buffer and consumed
||| by the Elixir GenServer via `pollEvents`.
public export
data NifEvent : Type where
  ||| Voice Activity Detection state change.
  ||| The payload is 1 (speaking) or 0 (silent).
  VadStateChange : (speaking : Bits32) -> NifEvent
  ||| Automatic Gain Control level adjustment.
  ||| The payload is the new gain level (0–65535).
  AgcLevelChange : (level : Bits32) -> NifEvent
  ||| Denoiser confidence update.
  ||| The payload is confidence (0–1000, representing 0.0–1.0 scaled).
  DenoiserConfidence : (confidence : Bits32) -> NifEvent
  ||| Unknown event code (forward compatibility).
  UnknownEvent : (code : Bits32) -> (payload : Bits32) -> NifEvent

||| Decode a raw (code, payload) pair from the Zig ring buffer into a
||| typed NifEvent. Event codes are defined in ffi/zig/src/coprocessor/.
|||
|||   Code 1 = VAD state change
|||   Code 2 = AGC level adjustment
|||   Code 3 = Denoiser confidence update
public export
decodeNifEvent : (code : Bits32) -> (payload : Bits32) -> NifEvent
decodeNifEvent 1 p = VadStateChange p
decodeNifEvent 2 p = AgcLevelChange p
decodeNifEvent 3 p = DenoiserConfidence p
decodeNifEvent c p = UnknownEvent c p

||| Callback function type (C ABI).
|||
||| Defined for documentation and forward compatibility. Do NOT use
||| directly — Idris2 cannot safely marshal C→Idris callbacks yet.
public export
Callback : Type
Callback = Bits64 -> Bits32 -> Bits32

||| Raw callback registration — UNSAFE, intentionally unexposed.
|||
||| The Zig NIF layer supports event callbacks, but Idris2's FFI only
||| handles calls FROM Idris2 TO C, not the reverse direction (tracked
||| in idris2#3182). Using this with AnyPtr would require believe_me
||| casts to marshal the function pointer, which is banned.
|||
||| Callers MUST use `pollEvents` instead, which achieves the same
||| result safely via a lock-free ring buffer polling model.
|||
||| When Idris2 adds proper typed callback registration, this primitive
||| can be wrapped safely without believe_me. Until then, it remains
||| private to this module.
%foreign "C:burble_register_callback, libburble"
prim__registerCallback : Bits64 -> AnyPtr -> PrimIO Bits32

||| Poll for pending NIF events (replaces callback registration).
|||
||| Returns a packed (event_code, payload) pair from the Zig ring buffer,
||| encoded as a single Bits64: upper 32 bits = event code, lower 32 = payload.
||| Returns 0 when the ring buffer is empty.
export
%foreign "C:burble_poll_events, libburble"
prim__pollEvents : Bits64 -> PrimIO Bits64

||| Safe event poller — returns pending audio events from the Zig NIF.
|||
||| Decodes the packed Bits64 into a typed NifEvent. Returns Nothing
||| when no events are pending (ring buffer empty).
export
pollEvents : Handle -> IO (Maybe NifEvent)
pollEvents h = do
  result <- primIO (prim__pollEvents (handlePtr h))
  pure $ if result == 0
    then Nothing
    else let code    = cast {to = Bits32} (prim__shr_Bits64 result 32)
             payload = cast {to = Bits32} (prim__and_Bits64 result 0xFFFFFFFF)
         in Just (decodeNifEvent code payload)

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

||| Check if library is initialized
export
%foreign "C:burble_is_initialized, libburble"
prim__isInitialized : Bits64 -> PrimIO Bits32

||| Check initialization status
export
isInitialized : Handle -> IO Bool
isInitialized h = do
  result <- primIO (prim__isInitialized (handlePtr h))
  pure (result /= 0)
