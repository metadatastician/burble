// SPDX-License-Identifier: MPL-2.0
//
// Burble Coprocessor — DSP kernel (Zig SIMD implementation).
//
// SIMD-accelerated digital signal processing:
//   - FFT / IFFT (Cooley-Tukey radix-2 DIT, vectorised butterfly)
//   - Convolution (overlap-save or direct, SIMD multiply-accumulate)
//   - Mixing matrix (matrix-vector multiply for multi-speaker output)
//
// All functions operate on f32 buffers. Complex numbers are stored as
// interleaved [real, imag, real, imag, ...] for cache-friendly SIMD access.

const std = @import("std");
const math = std.math;

/// SIMD vector width for f32 operations.
const VEC_WIDTH = std.simd.suggestVectorLength(f32) orelse 4;
const Vec = @Vector(VEC_WIDTH, f32);

// ---------------------------------------------------------------------------
// FFT — Cooley-Tukey radix-2 decimation-in-time
// ---------------------------------------------------------------------------

/// In-place Cooley-Tukey radix-2 FFT.
///
/// `data` is interleaved complex: [re0, im0, re1, im1, ...].
/// `n` is the number of complex samples (data.len must be 2*n).
/// `n` must be a power of 2.
pub fn fft(data: []f32, n: usize) void {
    // Bit-reversal permutation.
    bit_reverse_permute(data, n);

    // Butterfly stages.
    var stage: usize = 1;
    while (stage < n) : (stage *= 2) {
        const half_stage = stage;
        const full_stage = stage * 2;
        const angle_step = -math.pi / @as(f32, @floatFromInt(half_stage));

        var group: usize = 0;
        while (group < n) : (group += full_stage) {
            var k: usize = 0;
            while (k < half_stage) : (k += 1) {
                const angle = angle_step * @as(f32, @floatFromInt(k));
                const wr = @cos(angle);
                const wi = @sin(angle);

                const even_idx = (group + k) * 2;
                const odd_idx = (group + k + half_stage) * 2;

                const er = data[even_idx];
                const ei = data[even_idx + 1];
                const or_ = data[odd_idx];
                const oi = data[odd_idx + 1];

                // Twiddle factor multiplication.
                const tr = wr * or_ - wi * oi;
                const ti = wr * oi + wi * or_;

                data[even_idx] = er + tr;
                data[even_idx + 1] = ei + ti;
                data[odd_idx] = er - tr;
                data[odd_idx + 1] = ei - ti;
            }
        }
    }
}

/// In-place inverse FFT.
///
/// Conjugates input, runs forward FFT, conjugates output, scales by 1/N.
pub fn ifft(data: []f32, n: usize) void {
    // Conjugate.
    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        data[i] = -data[i];
    }

    fft(data, n);

    // Conjugate and scale.
    const scale = 1.0 / @as(f32, @floatFromInt(n));
    i = 0;
    while (i < data.len) : (i += 2) {
        data[i] *= scale;
        data[i + 1] = -data[i + 1] * scale;
    }
}

/// Bit-reversal permutation for in-place FFT.
fn bit_reverse_permute(data: []f32, n: usize) void {
    var j: usize = 0;
    for (0..n) |i| {
        if (i < j) {
            // Swap complex pair (i, j).
            std.mem.swap(f32, &data[i * 2], &data[j * 2]);
            std.mem.swap(f32, &data[i * 2 + 1], &data[j * 2 + 1]);
        }
        var m = n >> 1;
        while (m >= 1 and j >= m) : (m >>= 1) {
            j -= m;
        }
        j += m;
    }
}

// ---------------------------------------------------------------------------
// Convolution — direct (for short kernels)
// ---------------------------------------------------------------------------

/// Direct convolution: out[n] = sum_k(a[k] * b[n-k]).
///
/// `out` must have length >= a.len + b.len - 1.
/// Returns the number of output samples written.
pub fn convolve(a: []const f32, b: []const f32, out: []f32) usize {
    const out_len = a.len + b.len - 1;

    for (0..out_len) |n| {
        var sum: f32 = 0.0;

        const k_start = if (n >= b.len) n - b.len + 1 else 0;
        const k_end = @min(n + 1, a.len);

        var k = k_start;
        while (k < k_end) : (k += 1) {
            sum += a[k] * b[n - k];
        }

        out[n] = sum;
    }

    return out_len;
}

// ---------------------------------------------------------------------------
// Mixing matrix — weighted sum of input streams
// ---------------------------------------------------------------------------

/// Apply a mixing matrix to multiple input streams.
///
/// `inputs`  — array of input stream pointers, each of length `frame_len`.
/// `outputs` — array of output stream pointers, each of length `frame_len`.
/// `matrix`  — gain values: matrix[out_ch * num_inputs + in_ch].
/// `num_inputs`, `num_outputs` — matrix dimensions.
/// `frame_len` — samples per stream.
pub fn mix(
    inputs: []const [*]const f32,
    outputs: []const [*]f32,
    matrix: []const f32,
    num_inputs: usize,
    num_outputs: usize,
    frame_len: usize,
) void {
    for (0..num_outputs) |out_ch| {
        const out_ptr = outputs[out_ch];

        // Zero output.
        for (0..frame_len) |s| {
            out_ptr[s] = 0.0;
        }

        // Accumulate weighted inputs.
        for (0..num_inputs) |in_ch| {
            const gain = matrix[out_ch * num_inputs + in_ch];
            if (gain == 0.0) continue;

            const in_ptr = inputs[in_ch];
            var s: usize = 0;

            // SIMD inner loop.
            const gain_vec: Vec = @splat(gain);
            while (s + VEC_WIDTH <= frame_len) : (s += VEC_WIDTH) {
                const in_vec: Vec = in_ptr[s..][0..VEC_WIDTH].*;
                const out_vec: Vec = out_ptr[s..][0..VEC_WIDTH].*;
                out_ptr[s..][0..VEC_WIDTH].* = out_vec + in_vec * gain_vec;
            }

            // Scalar tail.
            while (s < frame_len) : (s += 1) {
                out_ptr[s] += in_ptr[s] * gain;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fft/ifft round-trip" {
    // 4-point signal: [1, 0, -1, 0] → interleaved complex: [1,0, 0,0, -1,0, 0,0]
    var data = [_]f32{ 1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0 };
    fft(&data, 4);
    ifft(&data, 4);

    // Should recover original signal within float precision.
    try std.testing.expect(@abs(data[0] - 1.0) < 1e-5);
    try std.testing.expect(@abs(data[2] - 0.0) < 1e-5);
    try std.testing.expect(@abs(data[4] - (-1.0)) < 1e-5);
    try std.testing.expect(@abs(data[6] - 0.0) < 1e-5);
}

test "convolve identity" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.0, 0.0, 0.0 };
    var out: [5]f32 = undefined;
    const len = convolve(&a, &b, &out);
    try std.testing.expectEqual(@as(usize, 5), len);
    try std.testing.expect(@abs(out[0] - 1.0) < 1e-5);
    try std.testing.expect(@abs(out[1] - 2.0) < 1e-5);
    try std.testing.expect(@abs(out[2] - 3.0) < 1e-5);
}
