const std = @import("std");
const task_mod = @import("task.zig");
const util = @import("util.zig");
const Task = task_mod.Task;
const ScriptLine = task_mod.ScriptLine;
const TargetOS = task_mod.TargetOS;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const builtin = @import("builtin");

/// Variable map for substitution
pub const VarMap = StringHashMap([]const u8);

/// Check if a task should execute on the current OS based on its arch: directive
pub fn shouldExecuteOnCurrentOS(target: TargetOS) bool {
    const current = builtin.os.tag;
    return switch (target) {
        .any => true,
        .linux => current == .linux,
        .windows => current == .windows,
        .macos, .darwin => current == .macos,
        .unix => current != .windows,
    };
}

/// Execute a task with given variable bindings
pub fn executeTask(allocator: Allocator, task_ptr: *const Task, vars: VarMap) !u8 {
    for (task_ptr.script_lines.items) |script_line| {
        // Substitute variables in the command
        const substituted = try substituteVariables(allocator, script_line.content, vars);
        defer allocator.free(substituted);

        // Execute the command
        const code = try executeShellCommand(allocator, substituted, !script_line.is_silent);
        if (code != 0) {
            return code;
        }
    }

    return 0;
}

/// Substitute variables in a template string
/// Supports:
///   {{var}} - Zake variables (from args, flags, let, vars)
///   ${VAR} - Environment variables
///   $(cmd) - Shell command substitution
pub fn substituteVariables(gpa: Allocator, template: []const u8, vars: VarMap) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(gpa);

    var i: usize = 0;
    while (i < template.len) {
        // Check for {{var}}
        if (i + 2 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const close_pos = std.mem.indexOf(u8, template[i + 2 ..], "}}") orelse {
                util.printError("Unclosed variable '{{{{' at position {d}", .{i});
                return error.UnclosedVariable;
            };

            const var_name = template[i + 2 .. i + 2 + close_pos];
            const value = vars.get(var_name) orelse "";

            try result.appendSlice(gpa, value);
            i = i + 2 + close_pos + 2;
            continue;
        }

        // Check for ${VAR}
        if (i + 2 < template.len and template[i] == '$' and template[i + 1] == '{') {
            const close_pos = std.mem.indexOf(u8, template[i + 2 ..], "}") orelse {
                util.printError("Unclosed environment variable '${{' at position {d}", .{i});
                return error.UnclosedEnvVar;
            };

            const var_name = template[i + 2 .. i + 2 + close_pos];

            // Get environment variable (allocate temporary buffer for the name)
            var env_name_buf: [256]u8 = undefined;
            if (var_name.len >= 256) {
                return error.EnvVarNameTooLong;
            }
            @memcpy(env_name_buf[0..var_name.len], var_name);
            env_name_buf[var_name.len] = 0;

            const env_value = std.posix.getenv(env_name_buf[0..var_name.len :0]) orelse "";

            try result.appendSlice(gpa, env_value);
            i = i + 2 + close_pos + 1;
            continue;
        }

        // Check for $(command)
        if (i + 2 < template.len and template[i] == '$' and template[i + 1] == '(') {
            const close_pos = std.mem.indexOf(u8, template[i + 2 ..], ")") orelse {
                util.printError("Unclosed command substitution '$(' at position {d}", .{i});
                return error.UnclosedCommandSub;
            };

            const command = template[i + 2 .. i + 2 + close_pos];
            const output = try executeShellCommandCapture(gpa, command);
            defer gpa.free(output);

            // Trim trailing newline from command output
            const trimmed = std.mem.trimRight(u8, output, "\n\r");
            try result.appendSlice(gpa, trimmed);

            i = i + 2 + close_pos + 1;
            continue;
        }

        // Regular character
        try result.append(gpa, template[i]);
        i += 1;
    }

    return result.toOwnedSlice(gpa);
}

/// Execute a shell command and return exit code
pub fn executeShellCommand(allocator: Allocator, command: []const u8, echo: bool) !u8 {
    if (echo) {
        const stdout = std.fs.File.stdout();
        var buf: [4096]u8 = undefined;
        var writer = stdout.writer(&buf);
        try writer.interface.print("{s}$ {s}{s}\n", .{ util.Color.Gray, command, util.Color.Reset });
        try writer.interface.flush();
    }

    const shell = getShellArgs();

    var argv: ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, shell[0]);
    try argv.append(allocator, shell[1]);
    try argv.append(allocator, command);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();

    return switch (term) {
        .Exited => |code| code,
        .Signal => 1,
        .Stopped => 1,
        .Unknown => 1,
    };
}

/// Execute a shell command and capture its output
fn executeShellCommandCapture(allocator: Allocator, command: []const u8) ![]u8 {
    const shell = getShellArgs();

    var argv: ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, shell[0]);
    try argv.append(allocator, shell[1]);
    try argv.append(allocator, command);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    errdefer allocator.free(stdout);

    const term = try child.wait();
    _ = term; // Ignore exit code for command substitution

    return stdout;
}

/// Get shell command arguments for the current platform
fn getShellArgs() [2][]const u8 {
    return if (builtin.os.tag == .windows)
        [_][]const u8{ "cmd.exe", "/C" }
    else
        [_][]const u8{ "sh", "-c" };
}
