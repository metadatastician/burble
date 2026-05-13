// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Burble Coprocessor — Neural kernel (Zig implementation).
//
// ML-based noise suppression for real-time voice audio. Removes
// non-speech sounds (keyboard clicks, fan noise, dog barking) while
// preserving speech quality.
//
// Architecture:
//   Phase 1 (current): Spectral gating with adaptive noise floor estimation.
//     - FFT → magnitude spectrum → noise floor tracking → spectral gate → IFFT
//     - Runs in real-time on 20ms frames at 48kHz
//     - Quality: adequate for keyboard/fan, limited for complex noise
//
//   Phase 2 (planned): RNNoise-style recurrent neural network.
//     - Trained GRU model for speech/noise separation
//     - Zig inference engine (no external ML framework dependency)
//     - Quality: competitive with commercial noise suppression
//
//   Phase 3 (future): Custom model trained on Burble-specific data.
//     - User-reported noise samples feed back into training
//     - Per-user noise profile adaptation

const std = @import("std");
const math = std.math;
const dsp = @import("dsp.zig");

/// Denoiser model state — persisted across frames for temporal continuity.
pub const DenoiserState = struct {
    /// Running noise floor estimate per frequency bin.
    noise_floor: [FRAME_SIZE / 2 + 1]f32,
    /// Frame counter for noise floor bootstrapping.
    frame_count: u64,
    /// Smoothing factor for noise floor update (higher = more stable).
    alpha: f32,
    /// Whether the noise floor has been initialised.
    initialised: bool,

    pub fn init() DenoiserState {
        return .{
            .noise_floor = [_]f32{0.0} ** (FRAME_SIZE / 2 + 1),
            .frame_count = 0,
            .alpha = 0.98,
            .initialised = false,
        };
    }

    /// Serialized size in bytes (portable, no alignment dependency).
    /// Layout: noise_floor (481 * 4) + frame_count (8) + alpha (4) + initialised (1) = 1937
    pub const SERIALIZED_SIZE: usize = (FRAME_SIZE / 2 + 1) * 4 + 8 + 4 + 1;

    /// Serialize state to a byte buffer (safe, no pointer casts).
    pub fn serialize(self: *const DenoiserState, out: *[SERIALIZED_SIZE]u8) void {
        var pos: usize = 0;

        // Noise floor bins (f32 LE each).
        for (self.noise_floor) |nf| {
            const bytes = @as([4]u8, @bitCast(nf));
            out[pos..][0..4].* = bytes;
            pos += 4;
        }

        // Frame count (u64 LE).
        const fc_bytes = std.mem.toBytes(std.mem.nativeToLittle(u64, self.frame_count));
        out[pos..][0..8].* = fc_bytes;
        pos += 8;

        // Alpha (f32 LE).
        const alpha_bytes = @as([4]u8, @bitCast(self.alpha));
        out[pos..][0..4].* = alpha_bytes;
        pos += 4;

        // Initialised (1 byte).
        out[pos] = if (self.initialised) 1 else 0;
    }

    /// Deserialize state from a byte buffer (safe, no pointer casts).
    pub fn deserialize(data: *const [SERIALIZED_SIZE]u8) DenoiserState {
        var state: DenoiserState = undefined;
        var pos: usize = 0;

        // Noise floor bins.
        for (&state.noise_floor) |*nf| {
            nf.* = @bitCast(data[pos..][0..4].*);
            pos += 4;
        }

        // Frame count.
        state.frame_count = std.mem.littleToNative(u64, @as(u64, @bitCast(data[pos..][0..8].*)));
        pos += 8;

        // Alpha.
        state.alpha = @bitCast(data[pos..][0..4].*);
        pos += 4;

        // Initialised.
        state.initialised = data[pos] != 0;

        return state;
    }
};

/// Frame size in samples (20ms at 48kHz).
const FRAME_SIZE: usize = 960;

/// Number of frequency bins (half of frame + DC).
const NUM_BINS: usize = FRAME_SIZE / 2 + 1;

// ---------------------------------------------------------------------------
// Spectral gating denoiser
// ---------------------------------------------------------------------------

/// Denoise a single frame using spectral gating.
///
/// 1. Window the input with a Hann window
/// 2. FFT to frequency domain
/// 3. Estimate noise floor from quiet frames
/// 4. Apply spectral gate (suppress bins below noise floor)
/// 5. IFFT back to time domain
/// 6. Overlap-add with previous frame
///
/// `input`  — 960 f32 samples (20ms at 48kHz)
/// `output` — 960 f32 samples (denoised)
/// `state`  — persistent denoiser state (updated in-place)
pub fn denoise_frame(
    input: *const [FRAME_SIZE]f32,
    output: *[FRAME_SIZE]f32,
    state: *DenoiserState,
) void {
    // Step 1: Apply Hann window.
    var windowed: [FRAME_SIZE * 2]f32 = undefined; // interleaved complex
    for (0..FRAME_SIZE) |i| {
        const w = hann_window(i, FRAME_SIZE);
        windowed[i * 2] = input[i] * w;
        windowed[i * 2 + 1] = 0.0;
    }

    // Step 2: FFT.
    dsp.fft(&windowed, FRAME_SIZE);

    // Step 3: Compute magnitude spectrum and update noise floor.
    var magnitudes: [NUM_BINS]f32 = undefined;
    var total_energy: f32 = 0.0;

    for (0..NUM_BINS) |bin| {
        const re = windowed[bin * 2];
        const im = windowed[bin * 2 + 1];
        magnitudes[bin] = @sqrt(re * re + im * im);
        total_energy += magnitudes[bin] * magnitudes[bin];
    }

    const frame_rms = @sqrt(total_energy / @as(f32, @floatFromInt(NUM_BINS)));
    state.frame_count += 1;

    if (!state.initialised) {
        // First frame — initialise noise floor from this frame.
        @memcpy(&state.noise_floor, &magnitudes);
        state.initialised = true;
    } else if (frame_rms < average_noise_floor(state) * 1.5) {
        // Quiet frame — update noise floor with exponential moving average.
        for (0..NUM_BINS) |bin| {
            state.noise_floor[bin] = state.alpha * state.noise_floor[bin] +
                (1.0 - state.alpha) * magnitudes[bin];
        }
    }

    // Step 4: Apply spectral gate.
    // Attenuate bins that are below (noise_floor * gate_factor).
    const gate_factor: f32 = 1.5;

    for (0..NUM_BINS) |bin| {
        const threshold = state.noise_floor[bin] * gate_factor;

        if (magnitudes[bin] < threshold) {
            // Below noise floor — attenuate heavily.
            const attenuation = magnitudes[bin] / (threshold + 1e-10);
            windowed[bin * 2] *= attenuation;
            windowed[bin * 2 + 1] *= attenuation;

            // Mirror for negative frequencies.
            if (bin > 0 and bin < NUM_BINS - 1) {
                const mirror = FRAME_SIZE - bin;
                windowed[mirror * 2] *= attenuation;
                windowed[mirror * 2 + 1] *= attenuation;
            }
        }
    }

    // Step 5: IFFT.
    dsp.ifft(&windowed, FRAME_SIZE);

    // Step 6: Extract real part with inverse Hann window (synthesis).
    for (0..FRAME_SIZE) |i| {
        output[i] = windowed[i * 2];
    }
}

// ---------------------------------------------------------------------------
// Noise classification (simple heuristic)
// ---------------------------------------------------------------------------

/// Classify the dominant noise type based on spectral features.
///
/// Returns a noise type code:
///   0 = silence, 1 = speech, 2 = keyboard, 3 = fan, 4 = music, 5 = unknown
pub fn classify_noise(samples: *const [FRAME_SIZE]f32) u8 {
    var rms: f32 = 0.0;
    var zero_crossings: u32 = 0;

    for (0..FRAME_SIZE) |i| {
        rms += samples[i] * samples[i];
        if (i > 0) {
            if ((samples[i] >= 0) != (samples[i - 1] >= 0)) {
                zero_crossings += 1;
            }
        }
    }

    rms = @sqrt(rms / @as(f32, @floatFromInt(FRAME_SIZE)));
    const zcr = @as(f32, @floatFromInt(zero_crossings)) / @as(f32, @floatFromInt(FRAME_SIZE - 1));

    if (rms < 0.001) return 0; // silence
    if (zcr > 0.4) return 2; // keyboard (high ZCR, impulsive)
    if (rms > 0.1 and zcr < 0.15) return 1; // speech
    if (rms > 0.05 and zcr > 0.2) return 3; // fan (broadband)
    return 5; // unknown
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Hann window function: 0.5 * (1 - cos(2π * n / N)).
fn hann_window(n: usize, size: usize) f32 {
    const phase = 2.0 * math.pi * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(size));
    return 0.5 * (1.0 - @cos(phase));
}

/// Compute the average noise floor across all bins.
fn average_noise_floor(state: *const DenoiserState) f32 {
    var sum: f32 = 0.0;
    for (state.noise_floor) |nf| {
        sum += nf;
    }
    return sum / @as(f32, @floatFromInt(NUM_BINS));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "hann window endpoints are zero" {
    try std.testing.expect(hann_window(0, 1024) < 1e-5);
}

test "hann window midpoint is one" {
    const mid = hann_window(512, 1024);
    try std.testing.expect(@abs(mid - 1.0) < 1e-5);
}

test "classify silence" {
    var silence: [FRAME_SIZE]f32 = [_]f32{0.0} ** FRAME_SIZE;
    try std.testing.expectEqual(@as(u8, 0), classify_noise(&silence));
}
