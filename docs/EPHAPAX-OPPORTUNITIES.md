<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Ephapax Linear Type Acceleration Opportunities for Burble

## Summary

Ephapax's dyadic type system (affine/linear modes) can enhance Burble's
audio pipeline in three areas where resource lifecycle correctness is
critical and currently relies on convention rather than proof.

## Opportunity 1: Linear-Typed Audio Frame Pipeline (HIGH IMPACT)

**Problem:** The `Burble.Coprocessor.Pipeline` processes audio frames
through a chain of kernel operations (denoise → gate → echo cancel →
encode → encrypt). If a frame is accidentally dropped or processed
twice, the audio stream corrupts silently.

**Current guarantee:** Convention (code review) — no formal proof.

**Ephapax solution:** Model each audio frame as a **linear resource**.
The type system guarantees:
- Every frame entering the pipeline exits exactly once
- No frame is silently dropped (compile error)
- No frame is duplicated (compile error)
- The pipeline chain is total (every step produces output)

```ephapax
// Linear type: frame must be consumed exactly once.
fn process_outbound@r(frame: AudioFrame@r!) -> EncryptedFrame@r =
    region r {
        let denoised  = neural_denoise(frame)  in  // consumes frame
        let gated     = noise_gate(denoised)    in  // consumes denoised
        let cancelled = echo_cancel(gated)      in  // consumes gated
        let encoded   = opus_encode(cancelled)  in  // consumes cancelled
        encrypt(encoded)                            // consumes encoded, returns result
    }
```

**Integration path:**
1. Write frame pipeline in ephapax linear mode
2. Compile to WASM
3. Load WASM via Wasmtime from Elixir NIF or Port
4. Fallback to current Elixir pipeline if WASM unavailable

**Stability gain:** Eliminates frame-drop bugs at compile time.
**Performance gain:** Region-based allocation = zero GC pauses during
audio processing. Bulk deallocation when pipeline frame exits region.

---

## Opportunity 2: E2EE Key Lifecycle (MEDIUM IMPACT)

**Problem:** AES-256-GCM frame keys must be:
- Used for exactly one encryption operation
- Zeroed from memory after use (prevent residue)
- Never copied or stored in logs

**Current guarantee:** Manual `secure_zero` calls and code review.

**Ephapax solution:** Model keys as **linear resources** with mandatory
consumption via a `zero_and_drop` function:

```ephapax
// Key is linear: must be consumed exactly once.
fn encrypt_frame(key: AESKey!, plaintext: &[u8]) -> (Ciphertext, ()) =
    let (ct, iv, tag) = aes_gcm_encrypt(key, plaintext) in  // consumes key
    (Ciphertext { ct, iv, tag }, ())
    // key is now gone — compiler proves it can't be reused
```

**Integration path:** Compile as WASM module, call from Zig NIF.

**Stability gain:** Impossible to reuse a key or forget to zero it.

---

## Opportunity 3: Region-Based Jitter Buffer (MEDIUM IMPACT)

**Problem:** The jitter buffer accumulates packets, reorders them, and
emits frames. Packets have variable lifetimes — some are emitted quickly,
others are held for reordering. Memory management is manual.

**Ephapax solution:** Use **regions** for packet lifetimes:

```ephapax
fn jitter_push@buffer(packet: Packet@buffer!, seq: u32) -> Maybe(Frame@buffer) =
    region buffer {
        let ordered = insert_sorted(packet, seq) in
        if ready_to_emit(ordered)
        then Just(emit_oldest(ordered))  // frame moves out of region
        else Nothing                      // packet stays in region
    }
```

**Integration path:** Compile to WASM, use as jitter buffer backend.

**Stability gain:** No leaked packets, no use-after-free on emitted frames.
**Performance gain:** Bulk deallocation when buffer region is recycled.

---

## Recommendation

**Phase 1 (now):** Document these opportunities. No code changes yet.
**Phase 2 (when ephapax has audio primitives):** Implement Opportunity 1
  as a proof-of-concept WASM pipeline module.
**Phase 3 (production):** Replace Pipeline's hot path with ephapax-compiled
  WASM, keeping Elixir as the control plane and fallback.

The affine→linear workflow is ideal for Burble:
- **Dev/test:** Use affine mode (implicit drops OK, faster iteration)
- **Production:** Switch to linear mode (compile-time proof of correctness)

## Not Recommended

- Rewriting the Zig FFI in ephapax (WASM target can't do SIMD yet)
- Replacing Elixir OTP supervision (ephapax has no actor model)
- Audio codec implementation (Opus is a C library, not a type system problem)
