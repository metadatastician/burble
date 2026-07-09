// SPDX-License-Identifier: MPL-2.0
//
// Burble Coprocessor — Integration tests.
//
// Tests the full kernel pipeline: audio → crypto → io → dsp → neural.
// Individual kernel unit tests are in their respective source files.

const std = @import("std");
const audio = @import("audio");
const dsp = @import("dsp");
const neural = @import("neural");
const firewall = @import("firewall");

// Re-export module-level tests.
test {
    _ = audio;
    _ = dsp;
    _ = neural;
    _ = firewall;
}

// ---------------------------------------------------------------------------
// Integration tests
// ---------------------------------------------------------------------------

test "audio encode → decode round-trip preserves signal" {
    const original = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0, -0.25, -0.5, -0.75 };
    var encoded: [16]u8 = undefined;
    const bytes = audio.pcm_encode(&original, &encoded);
    std.debug.assert(bytes == 16);

    var decoded: [8]f32 = undefined;
    const n = audio.pcm_decode(encoded[0..bytes], &decoded);
    std.debug.assert(n == 8);

    for (original, decoded) |orig, dec| {
        try std.testing.expect(@abs(orig - dec) < 0.001);
    }
}

test "noise gate preserves loud samples" {
    var samples = [_]f32{ 0.5, 0.001, -0.5, 0.0001, 0.8 };
    audio.noise_gate(&samples, 0.01);

    try std.testing.expectEqual(@as(f32, 0.5), samples[0]);
    try std.testing.expectEqual(@as(f32, 0.0), samples[1]);
    try std.testing.expectEqual(@as(f32, -0.5), samples[2]);
    try std.testing.expectEqual(@as(f32, 0.0), samples[3]);
    try std.testing.expectEqual(@as(f32, 0.8), samples[4]);
}

test "fft preserves energy" {
    // Sine wave at bin 1.
    var data: [16]f32 = undefined;
    for (0..8) |i| {
        const angle = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) / 8.0;
        data[i * 2] = @sin(angle);
        data[i * 2 + 1] = 0.0;
    }

    // Compute energy before FFT.
    var energy_before: f32 = 0.0;
    for (0..8) |i| {
        energy_before += data[i * 2] * data[i * 2];
    }

    dsp.fft(&data, 8);

    // Energy in frequency domain (Parseval's theorem: scaled by N).
    var energy_after: f32 = 0.0;
    for (0..8) |i| {
        energy_after += data[i * 2] * data[i * 2] + data[i * 2 + 1] * data[i * 2 + 1];
    }
    energy_after /= 8.0;

    try std.testing.expect(@abs(energy_before - energy_after) < 0.01);
}

test "neural denoiser initialises" {
    const state = neural.DenoiserState.init();
    try std.testing.expectEqual(@as(u64, 0), state.frame_count);
    try std.testing.expectEqual(false, state.initialised);
}
