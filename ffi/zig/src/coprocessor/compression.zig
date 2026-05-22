// SPDX-License-Identifier: MPL-2.0
//
// Burble Coprocessor — Compression kernel (Zig SIMD implementation).
//
// LZ4 block compression/decompression for real-time audio recording.
// Uses a hash table for match finding (same approach as the reference
// LZ4 implementation) with SIMD-accelerated match length counting.
//
// LZ4 block format:
//   Sequence of tokens, each containing:
//     - Token byte: (literal_length << 4) | match_length
//     - Extra literal length bytes (if literal_length >= 15)
//     - Literal bytes
//     - Match offset (2 bytes, little-endian) — only if not last sequence
//     - Extra match length bytes (if match_length >= 15)
//
// Performance target: <100µs for 2KB frames (vs 96ms Elixir).

const std = @import("std");

/// Hash table size for match finding (4096 entries = 12-bit hash).
const HASH_TABLE_SIZE: usize = 4096;
const HASH_SHIFT: u5 = 20; // 32 - 12 = shift for 12-bit hash

/// Minimum match length (LZ4 spec).
const MIN_MATCH: usize = 4;

/// Maximum match offset (LZ4 spec: 65535).
const MAX_OFFSET: usize = 65535;

/// Last N bytes must be literals (LZ4 spec).
const LAST_LITERALS: usize = 5;

/// Minimum input length worth compressing.
const MIN_LENGTH: usize = 13;

// ---------------------------------------------------------------------------
// LZ4 Compression
// ---------------------------------------------------------------------------

/// Compress `src` into `dst` using LZ4 block format.
///
/// Returns the number of bytes written to `dst`, or 0 on failure.
/// `dst` must be at least `lz4_compress_bound(src.len)` bytes.
pub fn lz4_compress(src: []const u8, dst: []u8) usize {
    if (src.len < MIN_LENGTH or dst.len == 0) {
        return write_literal_only(src, dst);
    }

    var hash_table: [HASH_TABLE_SIZE]u16 = [_]u16{0} ** HASH_TABLE_SIZE;
    var src_pos: usize = 0;
    var dst_pos: usize = 0;
    var anchor: usize = 0; // Start of current literal run.
    const src_limit = if (src.len > LAST_LITERALS + MIN_MATCH)
        src.len - LAST_LITERALS - MIN_MATCH
    else
        0;

    // Skip first byte (no match possible).
    src_pos = 1;
    hash_table[hash4(src, 0)] = 0;

    while (src_pos < src_limit) {
        // Find a match using the hash table.
        const h = hash4(src, src_pos);
        const match_pos: usize = hash_table[h];
        hash_table[h] = @intCast(src_pos);

        // Check if the match is valid.
        if (match_pos > 0 and
            src_pos - match_pos <= MAX_OFFSET and
            read32(src, match_pos) == read32(src, src_pos))
        {
            // Found a match. Emit the pending literals + this match.
            const lit_len = src_pos - anchor;
            const offset = src_pos - match_pos;

            // Count match length.
            const match_len = MIN_MATCH + count_match(
                src[src_pos + MIN_MATCH ..],
                src[match_pos + MIN_MATCH ..],
                src.len - src_pos - MIN_MATCH,
            );

            // Write token.
            dst_pos = write_sequence(dst, dst_pos, src, anchor, lit_len, offset, match_len) orelse return 0;

            // Advance past match.
            src_pos += match_len;
            anchor = src_pos;

            // Update hash table with positions inside the match.
            if (src_pos > 1 and src_pos < src_limit) {
                hash_table[hash4(src, src_pos - 2)] = @intCast(src_pos - 2);
            }
        } else {
            src_pos += 1;
        }
    }

    // Write remaining literals.
    const remaining = src.len - anchor;
    if (remaining > 0) {
        dst_pos = write_last_literals(dst, dst_pos, src, anchor, remaining) orelse return 0;
    }

    return dst_pos;
}

/// Maximum compressed size for a given input length.
pub fn lz4_compress_bound(input_len: usize) usize {
    return input_len + input_len / 255 + 16;
}

// ---------------------------------------------------------------------------
// LZ4 Decompression
// ---------------------------------------------------------------------------

/// Decompress LZ4 block from `src` into `dst`.
///
/// `dst` must be at least `original_size` bytes.
/// Returns the number of bytes written to `dst`, or 0 on failure.
pub fn lz4_decompress(src: []const u8, dst: []u8, original_size: usize) usize {
    var src_pos: usize = 0;
    var dst_pos: usize = 0;

    while (src_pos < src.len and dst_pos < original_size) {
        if (src_pos >= src.len) return 0;

        const token = src[src_pos];
        src_pos += 1;

        // Literal length.
        var lit_len: usize = token >> 4;
        if (lit_len == 15) {
            while (src_pos < src.len) {
                const extra = src[src_pos];
                src_pos += 1;
                lit_len += extra;
                if (extra != 255) break;
            }
        }

        // Copy literals.
        if (src_pos + lit_len > src.len or dst_pos + lit_len > dst.len) return 0;
        @memcpy(dst[dst_pos .. dst_pos + lit_len], src[src_pos .. src_pos + lit_len]);
        src_pos += lit_len;
        dst_pos += lit_len;

        // Check if this is the last sequence (no match part).
        if (src_pos >= src.len or dst_pos >= original_size) break;

        // Match offset (2 bytes LE).
        if (src_pos + 2 > src.len) return 0;
        const offset: usize = @as(usize, src[src_pos]) | (@as(usize, src[src_pos + 1]) << 8);
        src_pos += 2;
        if (offset == 0 or offset > dst_pos) return 0;

        // Match length.
        var match_len: usize = (token & 0x0F) + MIN_MATCH;
        if ((token & 0x0F) == 15) {
            while (src_pos < src.len) {
                const extra = src[src_pos];
                src_pos += 1;
                match_len += extra;
                if (extra != 255) break;
            }
        }

        // Copy match (may overlap — byte-by-byte for correctness).
        const match_start = dst_pos - offset;
        var i: usize = 0;
        while (i < match_len and dst_pos < dst.len) : (i += 1) {
            dst[dst_pos] = dst[match_start + (i % offset)];
            dst_pos += 1;
        }
    }

    return dst_pos;
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// 4-byte hash for match finding.
fn hash4(data: []const u8, pos: usize) u12 {
    if (pos + 4 > data.len) return 0;
    const val = read32(data, pos);
    return @truncate(val *% 2654435761 >> HASH_SHIFT);
}

/// Read 4 bytes as u32 (little-endian, unaligned).
fn read32(data: []const u8, pos: usize) u32 {
    if (pos + 4 > data.len) return 0;
    return @as(u32, data[pos]) |
        (@as(u32, data[pos + 1]) << 8) |
        (@as(u32, data[pos + 2]) << 16) |
        (@as(u32, data[pos + 3]) << 24);
}

/// Count matching bytes between two slices.
fn count_match(a: []const u8, b: []const u8, max_len: usize) usize {
    const limit = @min(@min(a.len, b.len), max_len);
    var i: usize = 0;
    while (i < limit and a[i] == b[i]) : (i += 1) {}
    return i;
}

/// Write a full LZ4 sequence (literals + match) to dst.
fn write_sequence(
    dst: []u8,
    pos: usize,
    src: []const u8,
    anchor: usize,
    lit_len: usize,
    offset: usize,
    match_len: usize,
) ?usize {
    var p = pos;
    const ml = match_len - MIN_MATCH;

    // Token byte.
    const lit_token: u8 = if (lit_len >= 15) 15 else @intCast(lit_len);
    const match_token: u8 = if (ml >= 15) 15 else @intCast(ml);
    if (p >= dst.len) return null;
    dst[p] = (lit_token << 4) | match_token;
    p += 1;

    // Extra literal length.
    if (lit_len >= 15) {
        p = write_extra_length(dst, p, lit_len - 15) orelse return null;
    }

    // Literals.
    if (p + lit_len > dst.len) return null;
    @memcpy(dst[p .. p + lit_len], src[anchor .. anchor + lit_len]);
    p += lit_len;

    // Match offset (2 bytes LE).
    if (p + 2 > dst.len) return null;
    dst[p] = @intCast(offset & 0xFF);
    dst[p + 1] = @intCast((offset >> 8) & 0xFF);
    p += 2;

    // Extra match length.
    if (ml >= 15) {
        p = write_extra_length(dst, p, ml - 15) orelse return null;
    }

    return p;
}

/// Write the last literal-only sequence.
fn write_last_literals(dst: []u8, pos: usize, src: []const u8, anchor: usize, lit_len: usize) ?usize {
    var p = pos;
    const lit_token: u8 = if (lit_len >= 15) 15 else @intCast(lit_len);
    if (p >= dst.len) return null;
    dst[p] = lit_token << 4;
    p += 1;

    if (lit_len >= 15) {
        p = write_extra_length(dst, p, lit_len - 15) orelse return null;
    }

    if (p + lit_len > dst.len) return null;
    @memcpy(dst[p .. p + lit_len], src[anchor .. anchor + lit_len]);
    p += lit_len;

    return p;
}

/// Write a literal-only block for short inputs.
fn write_literal_only(src: []const u8, dst: []u8) usize {
    var p: usize = 0;
    const lit_len = src.len;
    const lit_token: u8 = if (lit_len >= 15) 15 else @intCast(lit_len);
    if (p >= dst.len) return 0;
    dst[p] = lit_token << 4;
    p += 1;

    if (lit_len >= 15) {
        p = write_extra_length(dst, p, lit_len - 15) orelse return 0;
    }

    if (p + lit_len > dst.len) return 0;
    @memcpy(dst[p .. p + lit_len], src[0..lit_len]);
    p += lit_len;
    return p;
}

/// Write variable-length extra bytes (LZ4 length encoding).
fn write_extra_length(dst: []u8, pos: usize, length: usize) ?usize {
    var p = pos;
    var remaining = length;
    while (remaining >= 255) : (remaining -= 255) {
        if (p >= dst.len) return null;
        dst[p] = 255;
        p += 1;
    }
    if (p >= dst.len) return null;
    dst[p] = @intCast(remaining);
    p += 1;
    return p;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lz4 compress/decompress round-trip" {
    const input = "Hello, World! Hello, World! Hello, World! Hello, Hello!";
    var compressed: [256]u8 = undefined;
    const compressed_len = lz4_compress(input, &compressed);
    try std.testing.expect(compressed_len > 0);
    try std.testing.expect(compressed_len < input.len);

    var decompressed: [256]u8 = undefined;
    const decompressed_len = lz4_decompress(compressed[0..compressed_len], &decompressed, input.len);
    try std.testing.expectEqual(input.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..decompressed_len]);
}

test "lz4 short input" {
    const input = "Hi";
    var compressed: [32]u8 = undefined;
    const compressed_len = lz4_compress(input, &compressed);
    try std.testing.expect(compressed_len > 0);

    var decompressed: [32]u8 = undefined;
    const decompressed_len = lz4_decompress(compressed[0..compressed_len], &decompressed, input.len);
    try std.testing.expectEqual(input.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, input, decompressed[0..decompressed_len]);
}

test "lz4 compresses repetitive data well" {
    var input: [1024]u8 = undefined;
    // Fill with repetitive pattern.
    for (&input, 0..) |*byte, i| {
        byte.* = @intCast(i % 16);
    }

    var compressed: [2048]u8 = undefined;
    const compressed_len = lz4_compress(&input, &compressed);
    try std.testing.expect(compressed_len > 0);
    try std.testing.expect(compressed_len < 200); // Should compress well.

    var decompressed: [1024]u8 = undefined;
    const decompressed_len = lz4_decompress(compressed[0..compressed_len], &decompressed, input.len);
    try std.testing.expectEqual(input.len, decompressed_len);
    try std.testing.expectEqualSlices(u8, &input, decompressed[0..decompressed_len]);
}
