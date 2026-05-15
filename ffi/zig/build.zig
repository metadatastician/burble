// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Burble Coprocessor — Zig 0.15 build configuration.
//
// Compiles SIMD-accelerated audio processing kernels as Erlang NIFs.
// The output shared library is loaded by Burble.Coprocessor.ZigBackend.

const std = @import("std");

const APT_FALLBACK = "/usr/lib/erlang/usr/include";

/// Locate the directory containing erl_nif.h without hardcoding an
/// install layout. See the call site in build() for resolution order.
fn resolveErlInclude(b: *std.Build) []const u8 {
    if (b.option(
        []const u8,
        "erl-include",
        "Path to Erlang NIF headers (directory containing erl_nif.h)",
    )) |opt| return opt;

    if (std.process.getEnvVarOwned(b.allocator, "ERL_NIF_INCLUDE_DIR")) |env_dir| {
        if (env_dir.len > 0) return env_dir;
    } else |_| {}

    const argv = [_][]const u8{
        "erl",   "-noshell",
        "-eval", "io:format(\"~s\", [filename:join([code:root_dir(), \"usr\", \"include\"])]), halt().",
    };
    if (std.process.Child.run(.{ .allocator = b.allocator, .argv = &argv })) |res| {
        if (res.term == .Exited and res.term.Exited == 0) {
            const trimmed = std.mem.trim(u8, res.stdout, " \t\r\n");
            if (trimmed.len > 0) return b.dupe(trimmed);
        }
    } else |_| {}

    return APT_FALLBACK;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Erlang NIF header include path.
    //
    // Must NOT be hardcoded: `erlef/setup-beam` (CI) and kerl/asdf install
    // OTP into a tool cache, not the Debian apt path `/usr/lib/erlang`.
    // Resolution order:
    //   1. -Derl-include=... build option (explicit override)
    //   2. $ERL_NIF_INCLUDE_DIR environment variable
    //   3. ask `erl` for code:root_dir() and append usr/include
    //   4. fall back to the apt path (last resort, dev convenience)
    const erl_include = resolveErlInclude(b);

    // Zig 0.15 requires every .zig file to belong to exactly one module.
    // Each kernel is therefore its own named module, declared once and
    // shared by both the NIF library and the test runner. Cross-file
    // references use module names (@import("dsp")), never file paths
    // (@import("dsp.zig")) — the latter would pull a file into a second
    // module and trigger "file exists in modules X and Y".
    const audio_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dsp_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/dsp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const neural_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/neural.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dsp", .module = dsp_mod },
        },
    });
    const compression_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/compression.zig"),
        .target = target,
        .optimize = optimize,
    });
    const firewall_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/firewall.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ptp_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/ptp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Root module for the NIF shared library.
    const nif_mod = b.createModule(.{
        .root_source_file = b.path("src/coprocessor/nif.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "audio", .module = audio_mod },
            .{ .name = "dsp", .module = dsp_mod },
            .{ .name = "neural", .module = neural_mod },
            .{ .name = "compression", .module = compression_mod },
            .{ .name = "firewall", .module = firewall_mod },
            .{ .name = "ptp", .module = ptp_mod },
        },
    });

    nif_mod.addIncludePath(.{ .cwd_relative = erl_include });

    // Build as shared library (Erlang NIF).
    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "burble_coprocessor",
        .root_module = nif_mod,
    });

    b.installArtifact(lib);

    // Unit tests.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/coprocessor_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "audio", .module = audio_mod },
            .{ .name = "dsp", .module = dsp_mod },
            .{ .name = "neural", .module = neural_mod },
        },
    });

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run coprocessor unit tests");
    test_step.dependOn(&run_tests.step);
}
