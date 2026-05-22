// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Build configuration for Burble Desktop (Gossamer shell).
//
// Links against libgossamer for webview, libpipewire for audio routing,
// and system libraries for tray/hotkeys.
//
// Build:
//   zig build -Doptimize=ReleaseFast
//
// Output:
//   zig-out/bin/burble-desktop (~4MB static binary)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "burble-desktop",
        .target = target,
        .optimize = optimize,
    });

    // Link libgossamer (Gossamer webview shell).
    // Path relative to the Burble repo — Gossamer is a sibling repo.
    const gossamer_lib = "../../../../gossamer/src/interface/ffi/zig-out/lib";
    exe.addLibraryPath(.{ .cwd_relative = gossamer_lib });
    exe.linkSystemLibrary("gossamer");

    // Link WebKitGTK (Linux webview backend).
    exe.linkSystemLibrary("webkit2gtk-4.1");
    exe.linkSystemLibrary("gtk-3");

    // Link PipeWire for native audio routing (optional — graceful fallback).
    exe.linkSystemLibrary("pipewire-0.3");

    // Link libnotify for desktop notifications.
    exe.linkSystemLibrary("notify");

    // Standard C library.
    exe.linkLibC();

    b.installArtifact(exe);

    // Run step.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run Burble Desktop");
    run_step.dependOn(&run_cmd.step);
}
