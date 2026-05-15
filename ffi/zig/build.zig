// SPDX-License-Identifier: PMPL-1.0-or-later
//
// Burble Coprocessor — Zig 0.15 build configuration.
//
// Compiles SIMD-accelerated audio processing kernels as Erlang NIFs.
// The output shared library is loaded by Burble.Coprocessor.ZigBackend.

const std = @import("std");

const APT_FALLBACK = "/usr/lib/erlang/usr/include";

fn dirHasNifHeader(b: *std.Build, dir: []const u8) bool {
    const hdr = std.fs.path.join(b.allocator, &.{ dir, "erl_nif.h" }) catch return false;
    std.fs.accessAbsolute(hdr, .{}) catch return false;
    return true;
}

/// Locate the directory containing erl_nif.h without hardcoding an
/// install layout. Resolution order:
///   1. -Derl-include=... build option (explicit override, trusted as-is)
///   2. $ERL_NIF_INCLUDE_DIR (if it actually contains the header)
///   3. ask `erl` for code:root_dir() + system version, then probe both
///      known OTP header layouts (usr/include and erts-<vsn>/include) and
///      return whichever actually contains erl_nif.h. This is what makes
///      erlef/setup-beam (CI), kerl and asdf work — none of which use the
///      Debian apt path.
///   4. fall back to the apt path (dev convenience).
fn resolveErlInclude(b: *std.Build) []const u8 {
    if (b.option(
        []const u8,
        "erl-include",
        "Path to Erlang NIF headers (directory containing erl_nif.h)",
    )) |opt| {
        emitDiag(b, "option", opt, "", "");
        return opt;
    }

    if (std.process.getEnvVarOwned(b.allocator, "ERL_NIF_INCLUDE_DIR")) |env_dir| {
        if (env_dir.len > 0 and dirHasNifHeader(b, env_dir)) {
            emitDiag(b, "env", env_dir, "", "");
            return env_dir;
        }
    } else |_| {}

    // Print "<root_dir>|<erts version>" so we can build both candidate dirs.
    const argv = [_][]const u8{
        "erl",                                                                           "-noshell", "-eval",
        "io:format(\"~s|~s\", [code:root_dir(), erlang:system_info(version)]), halt().",
    };
    if (std.process.Child.run(.{ .allocator = b.allocator, .argv = &argv })) |res| {
        if (res.term == .Exited and res.term.Exited == 0) {
            const out = std.mem.trim(u8, res.stdout, " \t\r\n");
            var it = std.mem.splitScalar(u8, out, '|');
            const root = it.next() orelse "";
            const vsn = it.next() orelse "";
            if (root.len > 0) {
                const usr = std.fs.path.join(b.allocator, &.{ root, "usr", "include" }) catch "";
                if (usr.len > 0 and dirHasNifHeader(b, usr)) {
                    emitDiag(b, "erl/usr", usr, root, vsn);
                    return usr;
                }
                if (vsn.len > 0) {
                    const erts_dir = std.fmt.allocPrint(b.allocator, "erts-{s}", .{vsn}) catch "";
                    const erts = std.fs.path.join(b.allocator, &.{ root, erts_dir, "include" }) catch "";
                    if (erts.len > 0 and dirHasNifHeader(b, erts)) {
                        emitDiag(b, "erl/erts", erts, root, vsn);
                        return erts;
                    }
                }
                // Header not found under either layout but we have a root:
                // usr/include is the canonical install location — return it
                // so the compile error names a real, diagnosable path.
                if (usr.len > 0) {
                    emitDiag(b, "erl/usr-nohdr", usr, root, vsn);
                    return usr;
                }
            }
            emitDiag(b, "erl-unparsed", out, root, vsn);
        } else {
            emitDiag(b, "erl-nonzero", APT_FALLBACK, "", "");
        }
    } else |err| {
        emitDiag(b, "erl-spawn-failed", APT_FALLBACK, @errorName(err), "");
    }

    return APT_FALLBACK;
}

// TEMPORARY DIAGNOSTIC (remove once CI is green): emits a GitHub Actions
// warning annotation. Annotations are visible without log-download auth,
// so this surfaces the resolved Erlang layout from a failing CI run.
// Warnings never gate the build.
fn emitDiag(b: *std.Build, via: []const u8, chosen: []const u8, root: []const u8, vsn: []const u8) void {
    _ = b;
    std.debug.print(
        "::warning title=burble-erl-include::via={s} chosen={s} root={s} vsn={s}\n",
        .{ via, chosen, root, vsn },
    );
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Erlang NIF header include path — resolved dynamically; see
    // resolveErlInclude. Hardcoding breaks erlef/setup-beam (CI).
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
