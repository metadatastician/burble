// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Burble Coprocessor NIF — Erlang NIF entry point.
//
// Exports SIMD-accelerated audio processing functions as Erlang NIFs.
// Each NIF function matches a callback in Burble.Coprocessor.ZigBackend.
//
// Architecture:
//   nif.zig           — NIF boilerplate, argument marshalling, term conversion
//   audio.zig         — Opus codec, noise gate, echo cancellation
//   dsp.zig           — FFT, IFFT, convolution, mixing matrix
//   neural.zig        — ML-based noise suppression inference
//
// All kernel implementations use Zig's SIMD vectors (@Vector) for
// parallel sample processing. Memory is managed via Zig allocators
// with explicit lifetime control (no GC interference with BEAM).

const std = @import("std");
const audio = @import("audio");
const dsp = @import("dsp");
const neural = @import("neural");
const compression = @import("compression");
const firewall = @import("firewall");
const ptp = @import("ptp");

const c = @cImport({
    @cInclude("erl_nif.h");
});

// Type aliases for readability.
const ErlNifEnv = c.ErlNifEnv;
const ERL_NIF_TERM = c.ERL_NIF_TERM;
const ErlNifBinary = c.ErlNifBinary;

// ---------------------------------------------------------------------------
// Helpers: Erlang term construction
// ---------------------------------------------------------------------------

fn make_atom(env: ?*ErlNifEnv, name: [*:0]const u8) ERL_NIF_TERM {
    return c.enif_make_atom(env, name);
}

fn make_ok(env: ?*ErlNifEnv, term: ERL_NIF_TERM) ERL_NIF_TERM {
    return c.enif_make_tuple2(env, make_atom(env, "ok"), term);
}

fn make_error(env: ?*ErlNifEnv, reason: [*:0]const u8) ERL_NIF_TERM {
    return c.enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, reason));
}

fn make_float_list(env: ?*ErlNifEnv, values: []const f32) ERL_NIF_TERM {
    if (values.len == 0) return c.enif_make_list(env, 0);

    // Build list in reverse for efficiency.
    var list = c.enif_make_list(env, 0);
    var i: usize = values.len;
    while (i > 0) {
        i -= 1;
        const term = c.enif_make_double(env, @as(f64, @floatCast(values[i])));
        list = c.enif_make_list_cell(env, term, list);
    }
    return list;
}

/// Extract a list of f32 from an Erlang list term into a pre-allocated buffer.
/// Returns the number of elements extracted, or null on failure.
fn get_float_list(env: ?*ErlNifEnv, term: ERL_NIF_TERM, buf: []f32) ?usize {
    var list = term;
    var i: usize = 0;

    while (i < buf.len) {
        var head: ERL_NIF_TERM = undefined;
        var tail: ERL_NIF_TERM = undefined;

        if (c.enif_get_list_cell(env, list, &head, &tail) == 0) break;

        var dval: f64 = undefined;
        if (c.enif_get_double(env, head, &dval) == 0) {
            // Try integer.
            var ival: c_long = undefined;
            if (c.enif_get_long(env, head, &ival) == 0) return null;
            dval = @floatFromInt(ival);
        }

        buf[i] = @floatCast(dval);
        list = tail;
        i += 1;
    }

    return i;
}

// ---------------------------------------------------------------------------
// NIF: nif_available/0
// ---------------------------------------------------------------------------

fn nif_available(env: ?*ErlNifEnv, _: c_int, _: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    return make_atom(env, "true");
}

// ---------------------------------------------------------------------------
// NIF: nif_audio_encode/4 — (pcm_list, sample_rate, channels, bitrate)
// ---------------------------------------------------------------------------

fn nif_audio_encode(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    // Get list length.
    var list_len: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &list_len) == 0)
        return make_error(env, "bad_pcm_list");

    const num_samples: usize = @intCast(list_len);
    if (num_samples == 0) return make_error(env, "empty_pcm");

    // Allocate sample buffer.
    var pcm_buf: [4800]f32 = undefined; // max 100ms at 48kHz
    if (num_samples > pcm_buf.len) return make_error(env, "frame_too_large");

    const n = get_float_list(env, argv[0], pcm_buf[0..num_samples]) orelse
        return make_error(env, "bad_pcm_values");

    // Get channels param.
    var channels: c_int = undefined;
    if (c.enif_get_int(env, argv[2], &channels) == 0)
        return make_error(env, "bad_channels");

    // Encode PCM to 16-bit LE binary.
    var out_buf: [9600]u8 = undefined; // 2 bytes per sample
    const bytes_written = audio.pcm_encode(pcm_buf[0..n], &out_buf);

    // Build header: <<channels::8, len::32-little, data::binary>>
    var result_bin: ErlNifBinary = undefined;
    const total_size = 5 + bytes_written;
    if (c.enif_alloc_binary(total_size, &result_bin) == 0)
        return make_error(env, "alloc_failed");

    const data_ptr = result_bin.data;
    data_ptr[0] = @intCast(channels);
    const len32: u32 = @intCast(bytes_written);
    @memcpy(data_ptr[1..5], &std.mem.toBytes(std.mem.nativeToLittle(u32, len32)));
    @memcpy(data_ptr[5 .. 5 + bytes_written], out_buf[0..bytes_written]);

    return make_ok(env, c.enif_make_binary(env, &result_bin));
}

// ---------------------------------------------------------------------------
// NIF: nif_audio_decode/3 — (opus_binary, sample_rate, channels)
// ---------------------------------------------------------------------------

fn nif_audio_decode(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var bin: ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, argv[0], &bin) == 0)
        return make_error(env, "bad_binary");

    if (bin.size < 5) return make_error(env, "invalid_frame");

    const data = bin.data;
    const data_len = std.mem.readInt(u32, data[1..5], .little);

    if (5 + data_len > bin.size) return make_error(env, "invalid_frame");

    var pcm_buf: [4800]f32 = undefined;
    const num_samples = audio.pcm_decode(data[5 .. 5 + data_len], &pcm_buf);

    return make_ok(env, make_float_list(env, pcm_buf[0..num_samples]));
}

// ---------------------------------------------------------------------------
// NIF: nif_audio_noise_gate/2 — (pcm_list, threshold_db)
// ---------------------------------------------------------------------------

fn nif_audio_noise_gate(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var list_len: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &list_len) == 0) return make_error(env, "bad_pcm");

    const n: usize = @intCast(list_len);
    if (n > 4800) return make_error(env, "frame_too_large");

    var pcm: [4800]f32 = undefined;
    _ = get_float_list(env, argv[0], pcm[0..n]) orelse return make_error(env, "bad_pcm_values");

    var threshold_db: f64 = undefined;
    if (c.enif_get_double(env, argv[1], &threshold_db) == 0) return make_error(env, "bad_threshold");

    // Convert dB to linear amplitude.
    const threshold = @as(f32, @floatCast(std.math.pow(f64, 10.0, threshold_db / 20.0)));

    audio.noise_gate(pcm[0..n], threshold);

    return make_ok(env, make_float_list(env, pcm[0..n]));
}

// ---------------------------------------------------------------------------
// NIF: nif_audio_echo_cancel/3 — (capture_list, reference_list, filter_length)
// ---------------------------------------------------------------------------

fn nif_audio_echo_cancel(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var cap_len: c_uint = undefined;
    var ref_len: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &cap_len) == 0) return make_error(env, "bad_capture");
    if (c.enif_get_list_length(env, argv[1], &ref_len) == 0) return make_error(env, "bad_reference");

    const nc: usize = @intCast(cap_len);
    const nr: usize = @intCast(ref_len);
    if (nc > 4800 or nr > 4800) return make_error(env, "frame_too_large");

    var capture: [4800]f32 = undefined;
    var reference: [4800]f32 = undefined;

    _ = get_float_list(env, argv[0], capture[0..nc]) orelse return make_error(env, "bad_capture_values");
    _ = get_float_list(env, argv[1], reference[0..nr]) orelse return make_error(env, "bad_reference_values");

    var filter_len_int: c_int = undefined;
    if (c.enif_get_int(env, argv[2], &filter_len_int) == 0) return make_error(env, "bad_filter_length");
    const filter_len: usize = @intCast(filter_len_int);
    if (filter_len > 1024) return make_error(env, "filter_too_large");

    var weights: [1024]f32 = [_]f32{0.0} ** 1024;

    audio.echo_cancel(capture[0..nc], reference[0..nr], weights[0..filter_len], 0.5);

    return make_ok(env, make_float_list(env, capture[0..nc]));
}

// ---------------------------------------------------------------------------
// NIF: nif_dsp_fft/2 — (signal_list, size)
// ---------------------------------------------------------------------------

fn nif_dsp_fft(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var size_int: c_int = undefined;
    if (c.enif_get_int(env, argv[1], &size_int) == 0) return make_error(env, "bad_size");
    const n: usize = @intCast(size_int);
    if (n > 2048) return make_error(env, "fft_too_large");

    // Input is a list of floats (real values). We need interleaved complex.
    var list_len: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &list_len) == 0) return make_error(env, "bad_signal");
    const nl: usize = @intCast(list_len);
    if (nl != n) return make_error(env, "size_mismatch");

    // Read real values, create interleaved complex (imaginary = 0).
    var reals: [2048]f32 = undefined;
    _ = get_float_list(env, argv[0], reals[0..n]) orelse return make_error(env, "bad_signal_values");

    var complex_data: [4096]f32 = undefined; // 2*n interleaved
    for (0..n) |i| {
        complex_data[i * 2] = reals[i];
        complex_data[i * 2 + 1] = 0.0;
    }

    dsp.fft(complex_data[0 .. n * 2], n);

    // Return as list of {real, imag} tuples.
    var result = c.enif_make_list(env, 0);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        const re = c.enif_make_double(env, @as(f64, @floatCast(complex_data[i * 2])));
        const im = c.enif_make_double(env, @as(f64, @floatCast(complex_data[i * 2 + 1])));
        const tuple = c.enif_make_tuple2(env, re, im);
        result = c.enif_make_list_cell(env, tuple, result);
    }

    return make_ok(env, result);
}

// ---------------------------------------------------------------------------
// NIF: nif_dsp_ifft/2 — (spectrum_tuple_list, size)
// ---------------------------------------------------------------------------

fn nif_dsp_ifft(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var size_int: c_int = undefined;
    if (c.enif_get_int(env, argv[1], &size_int) == 0) return make_error(env, "bad_size");
    const n: usize = @intCast(size_int);
    if (n > 2048) return make_error(env, "fft_too_large");

    // Read list of {real, imag} tuples.
    var complex_data: [4096]f32 = undefined;
    var list = argv[0];
    for (0..n) |i| {
        var head: ERL_NIF_TERM = undefined;
        var tail: ERL_NIF_TERM = undefined;
        if (c.enif_get_list_cell(env, list, &head, &tail) == 0) return make_error(env, "bad_spectrum");

        var arity: c_int = undefined;
        var tuple_elems: [*c]const ERL_NIF_TERM = undefined;
        if (c.enif_get_tuple(env, head, &arity, &tuple_elems) == 0 or arity != 2)
            return make_error(env, "bad_tuple");

        var re: f64 = undefined;
        var im: f64 = undefined;
        if (c.enif_get_double(env, tuple_elems[0], &re) == 0) return make_error(env, "bad_real");
        if (c.enif_get_double(env, tuple_elems[1], &im) == 0) return make_error(env, "bad_imag");

        complex_data[i * 2] = @floatCast(re);
        complex_data[i * 2 + 1] = @floatCast(im);
        list = tail;
    }

    dsp.ifft(complex_data[0 .. n * 2], n);

    // Return real parts as a flat list.
    var reals: [2048]f32 = undefined;
    for (0..n) |i| {
        reals[i] = complex_data[i * 2];
    }

    return make_ok(env, make_float_list(env, reals[0..n]));
}

// ---------------------------------------------------------------------------
// NIF: nif_dsp_convolve/2 — (a_list, b_list)
// ---------------------------------------------------------------------------

fn nif_dsp_convolve(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var a_len_c: c_uint = undefined;
    var b_len_c: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &a_len_c) == 0) return make_error(env, "bad_list_a");
    if (c.enif_get_list_length(env, argv[1], &b_len_c) == 0) return make_error(env, "bad_list_b");

    const a_len: usize = @intCast(a_len_c);
    const b_len: usize = @intCast(b_len_c);
    if (a_len > 4096 or b_len > 4096) return make_error(env, "input_too_large");

    var a_buf: [4096]f32 = undefined;
    var b_buf: [4096]f32 = undefined;
    _ = get_float_list(env, argv[0], a_buf[0..a_len]) orelse return make_error(env, "bad_a_values");
    _ = get_float_list(env, argv[1], b_buf[0..b_len]) orelse return make_error(env, "bad_b_values");

    const out_len = a_len + b_len - 1;
    var out_buf: [8191]f32 = undefined;
    _ = dsp.convolve(a_buf[0..a_len], b_buf[0..b_len], out_buf[0..out_len]);

    return make_ok(env, make_float_list(env, out_buf[0..out_len]));
}

// ---------------------------------------------------------------------------
// NIF: nif_dsp_mix/2 — (streams_list_of_lists, matrix_list_of_lists)
// ---------------------------------------------------------------------------
// This is complex to marshal — for now, delegate to Elixir.
// The SIMD benefit for mixing is mainly at >8 streams which is uncommon.

fn nif_dsp_mix(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    // Parse streams (list of lists of floats).
    var num_streams_c: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &num_streams_c) == 0)
        return make_error(env, "bad_streams");
    const num_streams: usize = @intCast(num_streams_c);
    if (num_streams > 32 or num_streams == 0) return make_error(env, "too_many_streams");

    // Read each stream into a buffer.
    var stream_bufs: [32][4800]f32 = undefined;
    var stream_lens: [32]usize = undefined;
    var stream_list = argv[0];
    for (0..num_streams) |s| {
        var head: ERL_NIF_TERM = undefined;
        var tail: ERL_NIF_TERM = undefined;
        if (c.enif_get_list_cell(env, stream_list, &head, &tail) == 0)
            return make_error(env, "bad_stream_list");

        var slen: c_uint = undefined;
        if (c.enif_get_list_length(env, head, &slen) == 0)
            return make_error(env, "bad_stream_inner");
        const sl: usize = @intCast(slen);
        if (sl > 4800) return make_error(env, "stream_too_long");

        stream_lens[s] = get_float_list(env, head, stream_bufs[s][0..sl]) orelse
            return make_error(env, "bad_stream_values");
        stream_list = tail;
    }

    // Parse matrix (list of lists of floats): matrix[output][input].
    var num_outputs_c: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[1], &num_outputs_c) == 0)
        return make_error(env, "bad_matrix");
    const num_outputs: usize = @intCast(num_outputs_c);
    if (num_outputs > 32 or num_outputs == 0) return make_error(env, "too_many_outputs");

    var gain_matrix: [32][32]f32 = undefined;
    var matrix_list = argv[1];
    for (0..num_outputs) |o| {
        var head: ERL_NIF_TERM = undefined;
        var tail: ERL_NIF_TERM = undefined;
        if (c.enif_get_list_cell(env, matrix_list, &head, &tail) == 0)
            return make_error(env, "bad_matrix_row");

        var rlen: c_uint = undefined;
        if (c.enif_get_list_length(env, head, &rlen) == 0)
            return make_error(env, "bad_matrix_row_inner");
        if (@as(usize, @intCast(rlen)) != num_streams)
            return make_error(env, "matrix_dimension_mismatch");

        _ = get_float_list(env, head, gain_matrix[o][0..num_streams]) orelse
            return make_error(env, "bad_matrix_values");
        matrix_list = tail;
    }

    // Determine frame length from first stream.
    const frame_len = stream_lens[0];

    // Mix: output[o][s] = sum_i(stream[i][s] * gain[o][i]).
    var output_bufs: [32][4800]f32 = undefined;
    for (0..num_outputs) |o| {
        // Zero output.
        for (0..frame_len) |s| {
            output_bufs[o][s] = 0.0;
        }
        // Accumulate weighted inputs.
        for (0..num_streams) |i| {
            const gain = gain_matrix[o][i];
            if (gain == 0.0) continue;
            const sl = @min(stream_lens[i], frame_len);
            for (0..sl) |s| {
                output_bufs[o][s] += stream_bufs[i][s] * gain;
            }
        }
    }

    // Build result: list of lists.
    var result = c.enif_make_list(env, 0);
    var o: usize = num_outputs;
    while (o > 0) {
        o -= 1;
        const out_list = make_float_list(env, output_bufs[o][0..frame_len]);
        result = c.enif_make_list_cell(env, out_list, result);
    }

    return make_ok(env, result);
}

// ---------------------------------------------------------------------------
// NIF: nif_neural_init_model/1 — (sample_rate)
// ---------------------------------------------------------------------------

fn nif_neural_init_model(env: ?*ErlNifEnv, _: c_int, _: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    // Serialize the initial denoiser state to a portable binary format.
    // No unsafe pointer casts — uses explicit byte-level serialization.
    const state = neural.DenoiserState.init();

    var bin: ErlNifBinary = undefined;
    if (c.enif_alloc_binary(neural.DenoiserState.SERIALIZED_SIZE, &bin) == 0)
        return make_error(env, "alloc_failed");

    var out_buf: [neural.DenoiserState.SERIALIZED_SIZE]u8 = undefined;
    state.serialize(&out_buf);
    @memcpy(bin.data[0..neural.DenoiserState.SERIALIZED_SIZE], &out_buf);

    return make_ok(env, c.enif_make_binary(env, &bin));
}

// ---------------------------------------------------------------------------
// NIF: nif_neural_denoise/3 — (pcm_list, sample_rate, model_state_binary)
// ---------------------------------------------------------------------------

fn nif_neural_denoise(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    // Get PCM samples.
    var list_len: c_uint = undefined;
    if (c.enif_get_list_length(env, argv[0], &list_len) == 0) return make_error(env, "bad_pcm");

    const n: usize = @intCast(list_len);
    if (n != 960) return make_error(env, "frame_must_be_960_samples");

    var pcm: [960]f32 = undefined;
    _ = get_float_list(env, argv[0], &pcm) orelse return make_error(env, "bad_pcm_values");

    // Get model state from binary — safe deserialization, no pointer casts.
    var state_bin: ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, argv[2], &state_bin) == 0) return make_error(env, "bad_state");
    if (state_bin.size != neural.DenoiserState.SERIALIZED_SIZE) return make_error(env, "invalid_state_size");

    // Deserialize state from portable binary format.
    var state_bytes: [neural.DenoiserState.SERIALIZED_SIZE]u8 = undefined;
    @memcpy(&state_bytes, state_bin.data[0..neural.DenoiserState.SERIALIZED_SIZE]);
    var state = neural.DenoiserState.deserialize(&state_bytes);

    var output: [960]f32 = undefined;
    neural.denoise_frame(&pcm, &output, &state);

    // Serialize updated state back to binary.
    var new_state_bin: ErlNifBinary = undefined;
    if (c.enif_alloc_binary(neural.DenoiserState.SERIALIZED_SIZE, &new_state_bin) == 0)
        return make_error(env, "alloc_failed");

    var new_state_bytes: [neural.DenoiserState.SERIALIZED_SIZE]u8 = undefined;
    state.serialize(&new_state_bytes);
    @memcpy(new_state_bin.data[0..neural.DenoiserState.SERIALIZED_SIZE], &new_state_bytes);

    const pcm_term = make_float_list(env, &output);
    const state_term = c.enif_make_binary(env, &new_state_bin);
    const result = c.enif_make_tuple2(env, pcm_term, state_term);

    return make_ok(env, result);
}

// ---------------------------------------------------------------------------
// NIF: nif_compress_lz4/1 — (binary)
// ---------------------------------------------------------------------------

fn nif_compress_lz4(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var bin: ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, argv[0], &bin) == 0)
        return make_error(env, "bad_binary");

    if (bin.size == 0) return make_error(env, "empty_input");

    // Allocate output buffer (worst case: input + overhead).
    const max_out = compression.lz4_compress_bound(bin.size);
    var out_bin: ErlNifBinary = undefined;
    if (c.enif_alloc_binary(max_out, &out_bin) == 0)
        return make_error(env, "alloc_failed");

    const compressed_len = compression.lz4_compress(
        bin.data[0..bin.size],
        out_bin.data[0..max_out],
    );

    if (compressed_len == 0) {
        c.enif_release_binary(&out_bin);
        return make_error(env, "compress_failed");
    }

    // Shrink to actual size.
    if (c.enif_realloc_binary(&out_bin, compressed_len) == 0) {
        c.enif_release_binary(&out_bin);
        return make_error(env, "realloc_failed");
    }

    return make_ok(env, c.enif_make_binary(env, &out_bin));
}

// ---------------------------------------------------------------------------
// NIF: nif_decompress_lz4/2 — (compressed_binary, original_size)
// ---------------------------------------------------------------------------

fn nif_decompress_lz4(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var bin: ErlNifBinary = undefined;
    if (c.enif_inspect_binary(env, argv[0], &bin) == 0)
        return make_error(env, "bad_binary");

    var orig_size_int: c_int = undefined;
    if (c.enif_get_int(env, argv[1], &orig_size_int) == 0)
        return make_error(env, "bad_size");

    const original_size: usize = @intCast(orig_size_int);
    if (original_size == 0 or original_size > 10 * 1024 * 1024) // 10MB limit
        return make_error(env, "invalid_size");

    var out_bin: ErlNifBinary = undefined;
    if (c.enif_alloc_binary(original_size, &out_bin) == 0)
        return make_error(env, "alloc_failed");

    const decompressed_len = compression.lz4_decompress(
        bin.data[0..bin.size],
        out_bin.data[0..original_size],
        original_size,
    );

    if (decompressed_len == 0) {
        c.enif_release_binary(&out_bin);
        return make_error(env, "decompress_failed");
    }

    if (decompressed_len != original_size) {
        if (c.enif_realloc_binary(&out_bin, decompressed_len) == 0) {
            c.enif_release_binary(&out_bin);
            return make_error(env, "realloc_failed");
        }
    }

    return make_ok(env, c.enif_make_binary(env, &out_bin));
}

// ---------------------------------------------------------------------------
// NIF: nif_sdp_firewall_init/0
// ---------------------------------------------------------------------------

fn nif_sdp_firewall_init(env: ?*ErlNifEnv, _: c_int, _: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    firewall.init_sdp_table() catch return make_error(env, "init_failed");
    return make_atom(env, "ok");
}

// ---------------------------------------------------------------------------
// NIF: nif_sdp_firewall_authorize/2 — (ip_tuple, port)
// ---------------------------------------------------------------------------

fn nif_sdp_firewall_authorize(env: ?*ErlNifEnv, _: c_int, argv: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    var arity: c_int = undefined;
    var ip_elems: [*c]const ERL_NIF_TERM = undefined;
    if (c.enif_get_tuple(env, argv[0], &arity, &ip_elems) == 0 or arity != 4)
        return make_error(env, "bad_ip_tuple");

    var ip: [4]u8 = undefined;
    for (0..4) |i| {
        var val: c_int = undefined;
        if (c.enif_get_int(env, ip_elems[i], &val) == 0) return make_error(env, "bad_ip_value");
        ip[i] = @intCast(val);
    }

    var port: c_int = undefined;
    if (c.enif_get_int(env, argv[1], &port) == 0) return make_error(env, "bad_port");

    firewall.authorize_peer(ip, @intCast(port)) catch return make_error(env, "auth_failed");
    return make_atom(env, "ok");
}

// ---------------------------------------------------------------------------
// NIF: nif_ptp_read_clock/0
// ---------------------------------------------------------------------------

fn nif_ptp_read_clock(env: ?*ErlNifEnv, _: c_int, _: [*c]const ERL_NIF_TERM) callconv(.c) ERL_NIF_TERM {
    const ns = ptp.read_ptp_clock("/dev/ptp0") catch |err| {
        return switch (err) {
            error.NoPtpDevice => make_error(env, "no_ptp_device"),
            error.IoctlFailed => make_error(env, "ioctl_failed"),
            error.UnsupportedOS => make_error(env, "unsupported_os"),
        };
    };
    return make_ok(env, c.enif_make_int64(env, ns));
}

// ---------------------------------------------------------------------------
// NIF function table
// ---------------------------------------------------------------------------

var nif_funcs = [_]c.ErlNifFunc{
    .{ .name = "nif_available", .arity = 0, .fptr = nif_available, .flags = 0 },
    .{ .name = "nif_audio_encode", .arity = 4, .fptr = nif_audio_encode, .flags = 0 },
    .{ .name = "nif_audio_decode", .arity = 3, .fptr = nif_audio_decode, .flags = 0 },
    .{ .name = "nif_audio_noise_gate", .arity = 2, .fptr = nif_audio_noise_gate, .flags = 0 },
    .{ .name = "nif_audio_echo_cancel", .arity = 3, .fptr = nif_audio_echo_cancel, .flags = 0 },
    .{ .name = "nif_dsp_fft", .arity = 2, .fptr = nif_dsp_fft, .flags = 0 },
    .{ .name = "nif_dsp_ifft", .arity = 2, .fptr = nif_dsp_ifft, .flags = 0 },
    .{ .name = "nif_dsp_convolve", .arity = 2, .fptr = nif_dsp_convolve, .flags = 0 },
    .{ .name = "nif_dsp_mix", .arity = 2, .fptr = nif_dsp_mix, .flags = 0 },
    .{ .name = "nif_neural_init_model", .arity = 1, .fptr = nif_neural_init_model, .flags = 0 },
    .{ .name = "nif_neural_denoise", .arity = 3, .fptr = nif_neural_denoise, .flags = 0 },
    .{ .name = "nif_compress_lz4", .arity = 1, .fptr = nif_compress_lz4, .flags = 0 },
    .{ .name = "nif_decompress_lz4", .arity = 2, .fptr = nif_decompress_lz4, .flags = 0 },
    .{ .name = "nif_sdp_firewall_init", .arity = 0, .fptr = nif_sdp_firewall_init, .flags = 0 },
    .{ .name = "nif_sdp_firewall_authorize", .arity = 2, .fptr = nif_sdp_firewall_authorize, .flags = 0 },
    .{ .name = "nif_ptp_read_clock", .arity = 0, .fptr = nif_ptp_read_clock, .flags = 0 },
};

// ---------------------------------------------------------------------------
// NIF initialisation (ERL_NIF_INIT equivalent)
// ---------------------------------------------------------------------------

export fn nif_init() *const c.ErlNifEntry {
    const entry = struct {
        var e: c.ErlNifEntry = .{
            .major = c.ERL_NIF_MAJOR_VERSION,
            .minor = c.ERL_NIF_MINOR_VERSION,
            .name = "Elixir.Burble.Coprocessor.ZigBackend",
            .num_of_funcs = nif_funcs.len,
            .funcs = &nif_funcs,
            .load = null,
            .reload = null,
            .upgrade = null,
            .unload = null,
            .vm_variant = "beam.vanilla",
            .options = 1, // ERL_NIF_ENTRY_OPTIONS
            .sizeof_ErlNifResourceTypeInit = @sizeOf(c.ErlNifResourceTypeInit),
            .min_erts = "erts-13.0",
        };
    };
    return &entry.e;
}
