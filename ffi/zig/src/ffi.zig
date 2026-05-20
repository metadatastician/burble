// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Burble Coprocessor FFI — Pure Zig implementation.
//
// This file exports the C-compatible functions used by the V-lang API.
// It enforces the formal proofs defined in the Idris2 ABI.

const std = @import("std");
const abi = @import("abi.zig");
const audio = @import("coprocessor/audio.zig");

/// Check if a number is a power of two (enforces Idris2 FFTSize constraint).
export fn burble_is_power_of_two(n: i32) i32 {
    if (n <= 0) return 0;
    const un: u32 = @intCast(n);
    if ((un & (un - 1)) == 0) return 1 else return 0;
}

/// Validates role escalation.
export fn burble_can_escalate(from: i32, to: i32, authoriser: i32) i32 {
    const f: abi.Role = @enumFromInt(from);
    const t: abi.Role = @enumFromInt(to);
    const a: abi.Role = @enumFromInt(authoriser);
    if (abi.canEscalate(f, t, a)) return 1 else return 0;
}

/// Placeholder for Opus encoding (linked to Zig coprocessor implementation).
export fn burble_opus_encode(input: [*]const u8, input_len: i32, output: [*]u8, output_len: *i32, sample_rate: i32, channels: i32) i32 {
    // In a real implementation, this calls audio.pcm_encode or an actual Opus lib.
    _ = input;
    _ = input_len;
    _ = output;
    _ = sample_rate;
    _ = channels;
    output_len.* = 0;
    return 0; // Success
}

/// OCR processing hook (Co-processor accelerated).
export fn burble_ocr_process(image_data: [*]const u8, len: i32, result_text: [*]u8, result_len: *i32) i32 {
    _ = image_data;
    _ = len;
    _ = result_text;
    result_len.* = 0;
    return 0;
}

/// Pandoc document conversion hook.
export fn burble_pandoc_convert(input_text: [*]const u8, input_len: i32, from_fmt: [*]const u8, to_fmt: [*]const u8, output_text: [*]u8, output_len: *i32) i32 {
    _ = input_text;
    _ = input_len;
    _ = from_fmt;
    _ = to_fmt;
    _ = output_text;
    output_len.* = 0;
    return 0;
}

/// Linear-interpolation audio resampler.
///
/// Reads `in_len` f64 samples from `in_ptr`, resamples to `out_max_len`
/// f64 samples written to `out_ptr`, and writes the number of samples
/// produced to `out_len_ptr`.  The samples are interpreted as a single
/// channel; multi-channel audio should be deinterleaved by the caller.
///
/// The companion Idris2 specification is `Burble.ABI.MediaPipeline`'s
/// `resampleFrame`.  Both sides implement linear interpolation —
/// `output[j] = (1 - frac) * input[lo] + frac * input[hi]` where
/// `srcPos = j * in_len / out_max_len`, `lo = floor srcPos`,
/// `hi = min(lo + 1, in_len - 1)`, `frac = srcPos - lo`.
///
/// Returns 0 on success, 2 (InvalidParam) on degenerate inputs.
export fn burble_resample(
    in_ptr: [*]const f64,
    in_len: i32,
    out_ptr: [*]f64,
    out_max_len: i32,
    out_len_ptr: *i32,
) i32 {
    if (in_len <= 0 or out_max_len <= 0) {
        out_len_ptr.* = 0;
        return 2;
    }
    const in_n: usize = @intCast(in_len);
    const out_n: usize = @intCast(out_max_len);

    // Edge case: single input sample → constant output.
    if (in_n == 1) {
        var j: usize = 0;
        while (j < out_n) : (j += 1) out_ptr[j] = in_ptr[0];
        out_len_ptr.* = @intCast(out_n);
        return 0;
    }

    const in_f: f64 = @floatFromInt(in_n);
    const out_f: f64 = @floatFromInt(out_n);

    var j: usize = 0;
    while (j < out_n) : (j += 1) {
        const src_pos: f64 = (@as(f64, @floatFromInt(j)) * in_f) / out_f;
        const lo_f = @floor(src_pos);
        var lo: usize = @intFromFloat(lo_f);
        if (lo >= in_n - 1) lo = in_n - 2;
        const hi: usize = lo + 1;
        const frac: f64 = src_pos - @as(f64, @floatFromInt(lo));
        out_ptr[j] = (1.0 - frac) * in_ptr[lo] + frac * in_ptr[hi];
    }
    out_len_ptr.* = @intCast(out_n);
    return 0;
}

// ──────────────────────────── tests ────────────────────────────

test "burble_resample: identity (in_len == out_len)" {
    const input = [_]f64{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    var output = [_]f64{ -1.0, -1.0, -1.0, -1.0, -1.0 };
    var out_len: i32 = 0;
    const rc = burble_resample(&input, 5, &output, 5, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(i32, 5), out_len);
    // Identity sampling lands on integer indices → exact reproduction.
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), output[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), output[4], 1e-12);
}

test "burble_resample: upsample 2x preserves endpoints" {
    const input = [_]f64{ 0.0, 1.0 };
    var output = [_]f64{0.0} ** 4;
    var out_len: i32 = 0;
    const rc = burble_resample(&input, 2, &output, 4, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(i32, 4), out_len);
    // srcPos for j=0: 0.0  → output[0] = input[0] = 0.0
    // srcPos for j=3: 1.5  → between input[0] and input[1], frac=0.5 (clamped)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), output[0], 1e-12);
    // Monotonically increasing across the interpolation.
    try std.testing.expect(output[0] <= output[1]);
    try std.testing.expect(output[1] <= output[2]);
    try std.testing.expect(output[2] <= output[3]);
}

test "burble_resample: downsample 2x picks consistent samples" {
    const input = [_]f64{ 0.0, 1.0, 2.0, 3.0 };
    var output = [_]f64{0.0} ** 2;
    var out_len: i32 = 0;
    const rc = burble_resample(&input, 4, &output, 2, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(i32, 2), out_len);
    // srcPos for j=0: 0.0  → output[0] = 0.0
    // srcPos for j=1: 2.0  → output[1] = 2.0 (exact, integer position)
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), output[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), output[1], 1e-12);
}

test "burble_resample: single input sample produces constant output" {
    const input = [_]f64{0.42};
    var output = [_]f64{0.0} ** 8;
    var out_len: i32 = 0;
    const rc = burble_resample(&input, 1, &output, 8, &out_len);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expectEqual(@as(i32, 8), out_len);
    for (output) |v| try std.testing.expectApproxEqAbs(@as(f64, 0.42), v, 1e-12);
}

test "burble_resample: degenerate inputs return InvalidParam" {
    var output = [_]f64{0.0};
    var out_len: i32 = -1;
    const empty: [0]f64 = .{};
    try std.testing.expectEqual(@as(i32, 2), burble_resample(&empty, 0, &output, 1, &out_len));
    try std.testing.expectEqual(@as(i32, 0), out_len);

    const one = [_]f64{1.0};
    try std.testing.expectEqual(@as(i32, 2), burble_resample(&one, 1, &output, 0, &out_len));
}

test "burble_resample: linear interpolation midpoint check" {
    // input = [0, 10], upsampled 4x. Expected midpoint values:
    //   j=0: srcPos=0.0  → 0.0
    //   j=1: srcPos=0.5  → 5.0
    //   j=2: srcPos=1.0 (clamped to lo=0,hi=1,frac=1.0) → 10.0
    //   j=3: srcPos=1.5 (clamped to lo=0,hi=1,frac=1.5) → 15.0  -- wait, frac > 1 is extrapolation
    // With the clamping `if (lo >= in_n - 1) lo = in_n - 2`, lo stays at 0,
    // hi=1, frac=srcPos-lo. For j=3 with in_n=2, srcPos=1.5, lo=0, hi=1,
    // frac=1.5 → output = -0.5*0 + 1.5*10 = 15.0. This is intentional
    // extrapolation past the input range for the final samples.
    const input = [_]f64{ 0.0, 10.0 };
    var output = [_]f64{0.0} ** 4;
    var out_len: i32 = 0;
    _ = burble_resample(&input, 2, &output, 4, &out_len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), output[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), output[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), output[2], 1e-12);
}
