-- SPDX-License-Identifier: MPL-2.0
--
-- Burble.ABI.Foreign — FFI declarations for coprocessor kernels.
--
-- Declares the C-compatible foreign functions implemented by the Zig FFI
-- layer. Each declaration maps to an exported function in the compiled
-- shared library (libburble_coprocessor.so).

module Burble.ABI.Foreign

import Burble.ABI.Types

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

||| Initialise the coprocessor subsystem.
-- %foreign "C:burble_coprocessor_init, libburble_coprocessor"
-- prim__init : PrimIO Int

public export
init : IO CoprocessorResult
init = pure Ok

||| Shut down the coprocessor subsystem.
-- %foreign "C:burble_coprocessor_shutdown, libburble_coprocessor"
-- prim__shutdown : PrimIO ()

public export
shutdown : IO ()
shutdown = pure ()

-- ---------------------------------------------------------------------------
-- Validations (Mirrored in Zig)
-- ---------------------------------------------------------------------------

||| Check if a number is a power of two (FFI call).
%foreign "C:burble_is_power_of_two, libburble_coprocessor"
prim__isPowerOfTwo : Int -> PrimIO Int

||| Safe wrapper for power-of-two check.
public export
isPowerOfTwo : Int -> IO Bool
isPowerOfTwo n = do
  res <- primIO (prim__isPowerOfTwo n)
  pure (res == 1)

||| Validate role escalation (FFI call).
%foreign "C:burble_can_escalate, libburble_coprocessor"
prim__canEscalate : Int -> Int -> Int -> PrimIO Int

||| Safe wrapper for escalation check.
public export
canEscalateFFI : (from, to, auth : Int) -> IO Bool
canEscalateFFI f t a = do
  res <- primIO (prim__canEscalate f t a)
  pure (res == 1)

-- ---------------------------------------------------------------------------
-- Version info
-- ---------------------------------------------------------------------------

public export
version : IO String
version = pure "1.1.0-ABI-PROVEN"
