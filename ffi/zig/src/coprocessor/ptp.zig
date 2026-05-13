// Burble Coprocessor — PTP hardware clock kernel.
//
// Reads the PTP hardware clock via /dev/ptp0 ioctl (PTP_CLOCK_GETTIME).
// On systems without a PTP hardware clock, returns an error so the
// Elixir caller can fall back to phc2sys/NTP/system clock.

const std = @import("std");
const builtin = @import("builtin");

pub const PTP_CLOCK_GETTIME = 0xc0087001; // from linux/ptp_clock.h

/// Mirrors struct ptp_clock_time from linux/ptp_clock.h:
///   struct ptp_clock_time { __s64 sec; __u32 nsec; __u32 reserved; }
pub const PtpClockTime = extern struct {
    seconds: i64,
    nanoseconds: u32,
    reserved: u32,
};

/// Read the PTP hardware clock. Returns nanoseconds since epoch as i64.
/// Returns error.NoPtpDevice if the device path doesn't exist.
/// Returns error.IoctlFailed if the ioctl call fails.
/// Returns error.UnsupportedOS on non-Linux platforms.
pub fn read_ptp_clock(device_path: []const u8) error{ NoPtpDevice, IoctlFailed, UnsupportedOS }!i64 {
    if (builtin.os.tag != .linux) {
        return error.UnsupportedOS;
    }

    const fd = std.posix.open(device_path, .{ .ACCMODE = .RDONLY }, 0) catch {
        return error.NoPtpDevice;
    };
    defer std.posix.close(fd);

    var pct: PtpClockTime = undefined;
    const rc = std.os.linux.ioctl(fd, PTP_CLOCK_GETTIME, @intFromPtr(&pct));
    switch (std.os.linux.E.init(rc)) {
        .SUCCESS => return @as(i64, pct.seconds) * 1_000_000_000 + @as(i64, pct.nanoseconds),
        else => |err| {
            std.debug.print("PTP_CLOCK_GETTIME failed: {}\n", .{err});
            return error.IoctlFailed;
        },
    }
}

test "read_ptp_clock returns error on non-existent device" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const result = read_ptp_clock("/dev/nonexistent_ptp_device");
    try std.testing.expectError(error.NoPtpDevice, result);
}

test "read_ptp_clock returns UnsupportedOS on non-Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    const result = read_ptp_clock("/dev/ptp0");
    try std.testing.expectError(error.UnsupportedOS, result);
}
