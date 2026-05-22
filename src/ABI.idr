-- SPDX-License-Identifier: MPL-2.0
--
-- Burble ABI — Master entry point for formal proofs.
--
-- This module imports all verified ABI components to ensure they are
-- compiled into a single set of C headers for the Zig FFI layer.

module ABI

import Burble.ABI.Types
import Burble.ABI.Avow
import Burble.ABI.Permissions
import Burble.ABI.Vext
import Burble.ABI.MediaPipeline
import Burble.ABI.WebRTCSignaling
import Burble.ABI.Foreign

main : IO ()
main = do
  putStrLn "Burble ABI Proofs Compiled."
  ver <- Foreign.version
  putStrLn $ "Version: " ++ ver
  putStrLn $ "Result Ok: " ++ (show (resultToInt Ok))
  putStrLn $ "State Stable: " ++ (show (signalingStateToInt Stable))
  putStrLn $ "Role Owner: " ++ (show (roleToInt Owner))
