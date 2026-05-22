// SPDX-License-Identifier: MPL-2.0
//
// Burble Coprocessor — Audio kernel (Zig SIMD implementation).
//
// SIMD-accelerated audio processing operations:
//   - PCM frame pack/unpack (16-bit LE ↔ float, with SIMD clamping)
//     NOTE: This is *framing*, not Opus compression. Real Opus transcoding
//     requires linking libopus and is deferred — see STATE.a2ml [migration].
//     Burble is an E2EE-opaque SFU: clients Opus-encode in the browser's
//     WebRTC stack; the server forwards ciphertext without decoding. These
//     pack/unpack helpers are used only for recording, archive, and
//     self-test loopback paths. The Elixir Backend exposes an explicit
//     `opus_transcode/4` callback that returns {:error, :not_implemented}
//     so callers intending real Opus fail loudly.
//   - Noise gate (vectorised threshold comparison)
//   - Echo cancellation (NLMS adaptive filter, SIMD dot product)
//
// All functions operate on f32 sample buffers. The BEAM passes PCM data
// as Erlang binaries; the NIF layer handles marshalling.

const std = @import("std");
const math = std.math;

/// SIMD vector width — process 8 samples at a time on AVX2.
/// Falls back to 4 (SSE) or scalar on other architectures.
const VEC_WIDTH = std.simd.suggestVectorLength(f32) orelse 4;
const Vec = @Vector(VEC_WIDTH, f32);

// ---------------------------------------------------------------------------
// PCM encode: f32 normalised → i16 LE packed binary
// ---------------------------------------------------------------------------

/// Encode normalised f32 PCM samples to 16-bit signed LE integers.
/// Clamps input to [-1.0, 1.0] range using SIMD min/max.
///
/// Returns the number of bytes written to `out`.
pub fn pcm_encode(samples: []const f32, out: []u8) usize {
    const scale: Vec = @splat(32767.0);
    const one: Vec = @splat(1.0);
    const neg_one: Vec = @splat(-1.0);

    var i: usize = 0;
    var out_idx: usize = 0;

    // SIMD path: process VEC_WIDTH samples per iteration.
    while (i + VEC_WIDTH <= samples.len) : (i += VEC_WIDTH) {
        const chunk: Vec = samples[i..][0..VEC_WIDTH].*;

        // Clamp to [-1.0, 1.0].
        const clamped = @min(@max(chunk, neg_one), one);

        // Scale to i16 range.
        const scaled = clamped * scale;

        // Convert to i16 and write as LE bytes.
        inline for (0..VEC_WIDTH) |j| {
            const sample: i16 = @intFromFloat(scaled[j]);
            const bytes = std.mem.toBytes(std.mem.nativeToLittle(i16, sample));
            out[out_idx] = bytes[0];
            out[out_idx + 1] = bytes[1];
            out_idx += 2;
        }
    }

    // Scalar tail.
    while (i < samples.len) : (i += 1) {
        const clamped = @min(@max(samples[i], -1.0), 1.0);
        const sample: i16 = @intFromFloat(clamped * 32767.0);
        const bytes = std.mem.toBytes(std.mem.nativeToLittle(i16, sample));
        out[out_idx] = bytes[0];
        out[out_idx + 1] = bytes[1];
        out_idx += 2;
    }

    return out_idx;
}

// ---------------------------------------------------------------------------
// PCM decode: i16 LE packed binary → f32 normalised
// ---------------------------------------------------------------------------

/// Decode 16-bit signed LE integers to normalised f32 samples.
pub fn pcm_decode(data: []const u8, out: []f32) usize {
    const inv_scale = 1.0 / 32767.0;
    const num_samples = data.len / 2;
    var i: usize = 0;

    while (i < num_samples) : (i += 1) {
        const raw = std.mem.readInt(i16, data[i * 2 ..][0..2], .little);
        out[i] = @as(f32, @floatFromInt(raw)) * inv_scale;
    }

    return num_samples;
}

// ---------------------------------------------------------------------------
// Noise gate: zero samples below threshold
// ---------------------------------------------------------------------------

/// Apply noise gate. Samples with absolute value below `threshold` are zeroed.
/// `threshold` is linear amplitude (not dB).
pub fn noise_gate(samples: []f32, threshold: f32) void {
    const thresh_vec: Vec = @splat(threshold);
    const zero: Vec = @splat(0.0);

    var i: usize = 0;

    while (i + VEC_WIDTH <= samples.len) : (i += VEC_WIDTH) {
        const chunk: Vec = samples[i..][0..VEC_WIDTH].*;
        const abs_chunk = @abs(chunk);
        const mask = abs_chunk >= thresh_vec;
        samples[i..][0..VEC_WIDTH].* = @select(f32, mask, chunk, zero);
    }

    // Scalar tail.
    while (i < samples.len) : (i += 1) {
        if (@abs(samples[i]) < threshold) {
            samples[i] = 0.0;
        }
    }
}

// ---------------------------------------------------------------------------
// NLMS echo cancellation
// ---------------------------------------------------------------------------

/// NLMS (Normalised Least Mean Squares) adaptive echo cancellation.
///
/// `capture`    — microphone input (modified in-place to contain output)
/// `reference`  — speaker playback (used as echo reference)
/// `weights`    — adaptive filter weights (updated in-place)
/// `mu`         — step size (0.0–1.0, typically 0.5)
pub fn echo_cancel(
    capture: []f32,
    reference: []const f32,
    weights: []f32,
    mu: f32,
) void {
    const epsilon: f32 = 1.0e-8;
    const filter_len = weights.len;

    for (0..capture.len) |n| {
        // Dot product: weights · reference_window.
        var echo_estimate: f32 = 0.0;
        var power: f32 = 0.0;

        for (0..filter_len) |k| {
            if (n >= k) {
                const ref_idx = n - k;
                if (ref_idx < reference.len) {
                    echo_estimate += weights[k] * reference[ref_idx];
                    power += reference[ref_idx] * reference[ref_idx];
                }
            }
        }

        // Error = capture - echo estimate.
        const err = capture[n] - echo_estimate;
        capture[n] = err;

        // Update weights.
        const step = mu / (power + epsilon);
        for (0..filter_len) |k| {
            if (n >= k) {
                const ref_idx = n - k;
                if (ref_idx < reference.len) {
                    weights[k] += step * err * reference[ref_idx];
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "pcm encode/decode round-trip" {
    const samples = [_]f32{ 0.0, 0.5, -0.5, 1.0, -1.0 };
    var encoded: [10]u8 = undefined;
    const bytes_written = pcm_encode(&samples, &encoded);
    try std.testing.expectEqual(@as(usize, 10), bytes_written);

    var decoded: [5]f32 = undefined;
    const num_decoded = pcm_decode(&encoded, &decoded);
    try std.testing.expectEqual(@as(usize, 5), num_decoded);

    // Should round-trip within quantisation error.
    for (samples, decoded) |orig, dec| {
        try std.testing.expect(@abs(orig - dec) < 0.001);
    }
}

test "noise gate zeroes quiet samples" {
    var samples = [_]f32{ 0.001, 0.5, -0.002, 0.8, 0.0001 };
    noise_gate(&samples, 0.01);
    try std.testing.expectEqual(@as(f32, 0.0), samples[0]);
    try std.testing.expectEqual(@as(f32, 0.5), samples[1]);
    try std.testing.expectEqual(@as(f32, 0.0), samples[2]);
    try std.testing.expectEqual(@as(f32, 0.8), samples[3]);
    try std.testing.expectEqual(@as(f32, 0.0), samples[4]);
}
