// SPDX-License-Identifier: MPL-2.0
//
// Burble ABI — Zig mirror of Idris2 formal proofs.
//
// This file defines the Zig types that MUST match the memory layout
// and integer values proven in Burble.ABI.Types and Burble.ABI.Permissions.

const std = @import("std");

/// Result codes (matches Burble.ABI.Types.CoprocessorResult)
pub const Result = enum(i32) {
    ok = 0,
    err = 1,
    invalid_param = 2,
    buffer_too_small = 3,
    not_initialised = 4,
    codec_error = 5,
    crypto_error = 6,
    out_of_memory = 7,
};

/// Participant roles (matches Burble.ABI.Permissions.Role)
pub const Role = enum(i32) {
    listener = 0,
    speaker = 1,
    moderator = 2,
    owner = 3,
};

/// Signaling states (matches Burble.ABI.WebRTCSignaling.SignalingState)
pub const SignalingState = enum(i32) {
    stable = 0,
    have_local_offer = 1,
    have_remote_offer = 2,
    have_local_pranswer = 3,
    have_remote_pranswer = 4,
    closed = 5,
};

/// Validates a role transition (runtime enforcement of formal proof).
pub fn canEscalate(from: Role, to: Role, authoriser: Role) bool {
    return (@intFromEnum(from) < @intFromEnum(to)) and (@intFromEnum(to) < @intFromEnum(authoriser));
}

/// Validates a signaling state transition.
pub fn isValidTransition(from: SignalingState, to: SignalingState) bool {
    // Matches logic in Burble.ABI.WebRTCSignaling.tryTransition
    return switch (from) {
        .stable => (to == .have_local_offer or to == .have_remote_offer or to == .closed),
        .have_local_offer => (to == .stable or to == .have_remote_pranswer or to == .closed),
        .have_remote_offer => (to == .stable or to == .have_local_pranswer or to == .closed),
        .have_remote_pranswer => (to == .stable or to == .closed),
        .have_local_pranswer => (to == .stable or to == .closed),
        .closed => false,
    };
}
