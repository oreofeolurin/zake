const std = @import("std");
const builtin = @import("builtin");

/// ANSI color codes for terminal output
pub const Color = struct {
    pub const Reset = "\x1b[0m";
    pub const Red = "\x1b[31m";
    pub const Green = "\x1b[32m";
    pub const Yellow = "\x1b[33m";
    pub const Blue = "\x1b[34m";
    pub const Cyan = "\x1b[36m";
    pub const Gray = "\x1b[90m";
    pub const Bold = "\x1b[1m";
};

/// Print colored text to stderr
pub fn printColored(comptime color: []const u8, comptime fmt: []const u8, args: anytype) void {
    const stderr = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    var writer = stderr.writer(&buf);
    writer.interface.print(color ++ fmt ++ Color.Reset, args) catch {};
    writer.interface.flush() catch {};
}

/// Print error message
pub fn printError(comptime fmt: []const u8, args: anytype) void {
    printColored(Color.Red ++ Color.Bold, "Error: " ++ fmt ++ "\n", args);
}

/// Print success message
pub fn printSuccess(comptime fmt: []const u8, args: anytype) void {
    printColored(Color.Green, fmt ++ "\n", args);
}

/// Print info message
pub fn printInfo(comptime fmt: []const u8, args: anytype) void {
    printColored(Color.Blue, fmt ++ "\n", args);
}

/// Print warning message
pub fn printWarning(comptime fmt: []const u8, args: anytype) void {
    printColored(Color.Yellow, "Warning: " ++ fmt ++ "\n", args);
}

/// Get the appropriate shell for the current platform
pub fn getShell() struct { []const []const u8 } {
    return if (builtin.os.tag == .windows)
        .{&[_][]const u8{ "cmd.exe", "/C" }}
    else
        .{&[_][]const u8{ "sh", "-c" }};
}

/// Check if stdout is a TTY (for color output)
pub fn isTTY() bool {
    return std.io.getStdOut().isTty();
}

/// Cross-platform environment variable lookup.
/// Returns an allocated copy of the value, or null if not set.
/// Caller is responsible for freeing the returned slice.
pub fn lookupEnvVar(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    if (comptime builtin.os.tag == .windows) {
        return std.process.getEnvVarOwned(allocator, name) catch null;
    } else {
        var name_buf: [4096]u8 = undefined;
        if (name.len >= name_buf.len) return null;
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;
        const val = std.posix.getenv(name_buf[0..name.len :0]) orelse return null;
        return allocator.dupe(u8, val) catch null;
    }
}
