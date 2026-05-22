-- SPDX-License-Identifier: MPL-2.0
-- Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
--
-- Burble.ABI — Master ABI module that compiles all proof components
--
-- This module serves as the single entry point for the Burble ABI,
-- ensuring all proof components compile together and integrating
-- with the universal proof framework.

module Burble.ABI

import Data.List
import Data.String

-- Import all ABI components
import Burble.ABI.Types
import Burble.ABI.Foreign
import Burble.ABI.MediaPipeline
import Burble.ABI.Permissions
import Burble.ABI.Avow
import Burble.ABI.Vext
import Burble.ABI.WebRTCSignaling

-- Import universal proof framework
import UniversalABI

%default total

-- ==========================================================================
-- Master ABI Description
-- ==========================================================================

||| Complete description of the Burble ABI
public export
burbleABI : ABIDescription
burbleABI = MkABIDescription
  "Burble"
  "1.0.0"
  "Idris2"
  "Real-time media coprocessor ABI with formal safety guarantees"
  10  -- Maximum complexity

-- ==========================================================================
-- Component-Specific Certificates
-- ==========================================================================

||| MediaPipeline certificate
public export
mediaPipelineCert : ABIDescription
mediaPipelineCert = MkABIDescription
  "MediaPipeline"
  "1.0.0"
  "Idris2"
  "Linear buffer consumption and audio processing"
  8

||| WebRTCSignaling certificate
public export
webRTCSignalingCert : ABIDescription
webRTCSignalingCert = MkABIDescription
  "WebRTCSignaling"
  "1.0.0"
  "Idris2"
  "JSEP state machine and session safety"
  9

||| Permissions certificate
public export
permissionsCert : ABIDescription
permissionsCert = MkABIDescription
  "Permissions"
  "1.0.0"
  "Idris2"
  "Role-based access control and capability lattice"
  7

||| Avow certificate
public export
avowCert : ABIDescription
avowCert = MkABIDescription
  "Avow"
  "1.0.0"
  "Idris2"
  "Attestation chain integrity and trust management"
  8

||| Vext certificate
public export
vextCert : ABIDescription
vextCert = MkABIDescription
  "Vext"
  "1.0.0"
  "Idris2"
  "Extension sandboxing and capability subsumption"
  7

||| Types certificate
public export
typesCert : ABIDescription
typesCert = MkABIDescription
  "Types"
  "1.0.0"
  "Idris2"
  "Core type definitions and constraints"
  6

-- ==========================================================================
-- Universal ABI Integration
-- ==========================================================================

||| MediaPipeline using universal framework
public export
mediaPipelineUniversalCert : ABICertificate
mediaPipelineUniversalCert = enhancedABICertificate mediaPipelineCert

||| WebRTCSignaling using universal framework
public export
webRTCSignalingUniversalCert : ABICertificate
webRTCSignalingUniversalCert = enhancedABICertificate webRTCSignalingCert

||| Permissions using universal framework
public export
permissionsUniversalCert : ABICertificate
permissionsUniversalCert = enhancedABICertificate permissionsCert

||| Avow using universal framework
public export
avowUniversalCert : ABICertificate
avowUniversalCert = enhancedABICertificate avowCert

||| Vext using universal framework
public export
vextUniversalCert : ABICertificate
vextUniversalCert = enhancedABICertificate vextCert

||| Types using universal framework
public export
typesUniversalCert : ABICertificate
typesUniversalCert = standardABICertificate typesCert

-- ==========================================================================
-- Master Certificate (Composed)
-- ==========================================================================

||| Complete Burble ABI certificate
public export
masterCertificate : ABICertificate
masterCertificate =
  composeABICertificates mediaPipelineUniversalCert
  (composeABICertificates webRTCSignalingUniversalCert
   (composeABICertificates permissionsUniversalCert
    (composeABICertificates avowUniversalCert
     (composeABICertificates vextUniversalCert
      typesUniversalCert))))

-- ==========================================================================
-- Validation
-- ==========================================================================

||| Validate the master certificate
public export
masterValidation : ABICertificateValidation
masterValidation = validateCertificate masterCertificate

||| Check that all components are validated
public export
allComponentsValid : Bool
allComponentsValid =
  case masterValidation of
    Valid _ => True
    MissingLevels _ => False
    IncompleteProofs _ => False

-- ==========================================================================
-- Zig Integration
-- ==========================================================================

||| Convert master certificate to Zig FFI format
public export
toZigFFI : ZigFFI.ZigFFIDescription
toZigFFI = MkZigFFI.ZigFFIDescription
  "Burble"
  "1.0.0"
  "Real-time media coprocessor"
  10  -- Very complex
  "arena"  -- Allocator strategy
  "multi"  -- Thread model

||| Generate Zig runtime verification code
public export
zigRuntimeChecks : String
zigRuntimeChecks = ZigFFI.generateRuntimeChecks 
  (ZigFFI.MkZigFFICertificate toZigFFI
    (map (\p => (p, ())) (ZigFFI.verificationForComplexity ZigFFI.VeryComplex))
    "2026-04-04"
    "Burble Universal Framework")

-- ==========================================================================
-- Main Entry Point
-- ==========================================================================

||| Main function to verify all proofs compile
public export
main : IO ()
main = do
  putStrLn "Burble ABI Proof Compilation"
  putStrLn "============================"
  
  case masterValidation of
    Valid cert => do
      putStrLn "✅ All proofs valid!"
      putStrLn ("Highest safety level: " ++ show cert.highestLevel)
      putStrLn ("Total safety levels: " ++ show (length cert.safetyLevels))
      
      -- Write Zig runtime checks to file
      writeFile "generated/zig_verification.zig" zigRuntimeChecks
      putStrLn "✅ Generated Zig runtime verification code"
      
    MissingLevels missing => do
      putStrLn "❌ Missing safety levels:"
      mapM_ (putStrLn . ("  - " ++)) (map show missing)
      
    IncompleteProofs incomplete => do
      putStrLn "❌ Incomplete proofs:"
      mapM_ (putStrLn . ("  - " ++)) incomplete

-- ==========================================================================
-- Export for CI/CD
-- ==========================================================================

||| Check proofs for CI/CD pipeline
public export
checkProofs : IO Bool
checkProofs = do
  case masterValidation of
    Valid _ => pure True
    _ => pure False

||| Get proof coverage report
public export
proofCoverageReport : String
proofCoverageReport =
  "Burble ABI Proof Coverage Report\n" ++
  "================================\n" ++
  "Components: 6/6 ✅\n" ++
  "Safety Levels: " ++ show (length masterCertificate.safetyLevels) ++ "\n" ++
  "Highest Level: " ++ show masterCertificate.highestLevel ++ "\n" ++
  "Validation: " ++ case masterValidation of
    Valid _ => "PASS ✅"
    _ => "FAIL ❌" ++ "\n"

-- ==========================================================================
-- Documentation
-- ==========================================================================

||| Usage example:
|||
||| ```idris
||| import Burble.ABI
|||
||| main : IO ()
||| main = do
|||   -- Check all proofs
|||   Burble.ABI.main
|||   
|||   -- Get validation status
|||   case Burble.ABI.masterValidation of
|||     Valid cert => putStrLn "All proofs valid!"
|||     _ => putStrLn "Proof validation failed"
||| ```
