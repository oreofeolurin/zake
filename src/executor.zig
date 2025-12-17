const std = @import("std");
const task_mod = @import("task.zig");
const util = @import("util.zig");
const Task = task_mod.Task;
const ScriptLine = task_mod.ScriptLine;
const TargetOS = task_mod.TargetOS;
const TaskRegistry = task_mod.TaskRegistry;
const Condition = task_mod.Condition;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const builtin = @import("builtin");
const fs = std.fs;

/// Variable map for substitution
pub const VarMap = StringHashMap([]const u8);

/// Maximum recursion depth for task invocations
const MAX_RECURSION_DEPTH = 32;

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

/// Evaluate a when: condition expression
/// Supports:
///   - ${VAR} == "value" / ${VAR} != "value"
///   - {{var}} == "value"
///   - $(command) - true if output is non-empty
///   - "value" - true if non-empty
///   - Plain truthy check (any non-empty, non-"false", non-"0" value is true)
fn evaluateCondition(allocator: Allocator, expression: []const u8, vars: VarMap) !bool {
    // First, expand all variables in the expression
    const expanded = try substituteVariables(allocator, expression, vars);
    defer allocator.free(expanded);

    // Check for comparison operators
    if (std.mem.indexOf(u8, expanded, "==")) |op_pos| {
        const left = std.mem.trim(u8, expanded[0..op_pos], " \t\"");
        const right = std.mem.trim(u8, expanded[op_pos + 2 ..], " \t\"");
        return std.mem.eql(u8, left, right);
    }

    if (std.mem.indexOf(u8, expanded, "!=")) |op_pos| {
        const left = std.mem.trim(u8, expanded[0..op_pos], " \t\"");
        const right = std.mem.trim(u8, expanded[op_pos + 2 ..], " \t\"");
        return !std.mem.eql(u8, left, right);
    }

    // No comparison - treat as truthy check
    // Empty, "false", "0", "no" are falsy
    const trimmed = std.mem.trim(u8, expanded, " \t\"");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "false")) return false;
    if (std.mem.eql(u8, trimmed, "0")) return false;
    if (std.mem.eql(u8, trimmed, "no")) return false;

    return true;
}
/// Execute a task with given variable bindings
/// registry is optional - only needed if task uses 'run' command
pub fn executeTask(allocator: Allocator, task_ptr: *const Task, vars: VarMap) !u8 {
    var completed = std.StringHashMap(void).init(allocator);
    defer {
        var it = completed.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        completed.deinit();
    }
    return executeTaskInternal(allocator, task_ptr, vars, null, 0, &completed);
}

/// Execute a task with registry (allows 'run' command and requires:)
pub fn executeTaskWithRegistry(allocator: Allocator, task_ptr: *const Task, vars: VarMap, registry: *const TaskRegistry) !u8 {
    var completed = std.StringHashMap(void).init(allocator);
    defer {
        var it = completed.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        completed.deinit();
    }
    return executeTaskInternal(allocator, task_ptr, vars, registry, 0, &completed);
}

/// Internal task execution with recursion tracking
fn executeTaskInternal(
    allocator: Allocator,
    task_ptr: *const Task,
    vars: VarMap,
    registry: ?*const TaskRegistry,
    depth: usize,
    completed: *std.StringHashMap(void),
) !u8 {
    if (depth >= MAX_RECURSION_DEPTH) {
        util.printError("Maximum task recursion depth ({d}) exceeded", .{MAX_RECURSION_DEPTH});
        return error.RecursionLimitExceeded;
    }

    // Check when: condition before executing
    if (task_ptr.condition) |cond| {
        const satisfied = try evaluateCondition(allocator, cond.expression, vars);
        if (!satisfied) {
            util.printInfo("Skipping task '{s}' (condition not met)", .{task_ptr.name});
            return 0; // Skip silently without error
        }
    }

    // Execute dependencies first (requires:)
    if (registry != null and task_ptr.requires.items.len > 0) {
        for (task_ptr.requires.items) |dep_name| {
            // Skip if already executed
            if (completed.contains(dep_name)) {
                continue;
            }

            const dep_task = registry.?.findTaskConst(dep_name) orelse {
                util.printError("Required task '{s}' not found", .{dep_name});
                return error.DependencyNotFound;
            };

            // Execute dependency with empty vars (deps don't inherit args)
            var dep_vars = VarMap.init(allocator);
            defer dep_vars.deinit();

            // Copy global vars for dependencies
            var global_iter = vars.iterator();
            while (global_iter.next()) |entry| {
                // Only copy if it looks like a global var (uppercase)
                if (entry.key_ptr.len > 0 and std.ascii.isUpper(entry.key_ptr.*[0])) {
                    const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                    errdefer allocator.free(key_copy);
                    const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
                    try dep_vars.put(key_copy, value_copy);
                }
            }

            const code = try executeTaskInternal(allocator, dep_task, dep_vars, registry, depth + 1, completed);
            if (code != 0) {
                util.printError("Dependency '{s}' failed with exit code {d}", .{ dep_name, code });
                return code;
            }

            // Mark as completed
            const name_copy = try allocator.dupe(u8, dep_name);
            try completed.put(name_copy, {});
        }
    }

    // Create a mutable copy of vars for let statements
    var local_vars = VarMap.init(allocator);
    defer {
        var iter = local_vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        local_vars.deinit();
    }

    // Copy incoming vars to local_vars
    var incoming_iter = vars.iterator();
    while (incoming_iter.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
        try local_vars.put(key_copy, value_copy);
    }

    for (task_ptr.script_lines.items) |script_line| {
        const content = script_line.content;

        // Check for "let varname = value" statement
        if (std.mem.startsWith(u8, content, "let ")) {
            const rest = content[4..]; // Skip "let "

            // Find the equals sign
            const eq_pos = std.mem.indexOf(u8, rest, "=") orelse {
                util.printError("Invalid let statement: missing '=' in '{s}'", .{content});
                return error.InvalidLetStatement;
            };

            // Extract variable name (trim whitespace)
            const var_name = std.mem.trim(u8, rest[0..eq_pos], " \t");
            if (var_name.len == 0) {
                util.printError("Invalid let statement: empty variable name", .{});
                return error.InvalidLetStatement;
            }

            // Extract value (trim whitespace)
            const raw_value = std.mem.trim(u8, rest[eq_pos + 1 ..], " \t");

            // Substitute variables in the value
            const substituted_value = try substituteVariables(allocator, raw_value, local_vars);

            // Store in local_vars (overwrite if exists)
            const key_copy = try allocator.dupe(u8, var_name);
            errdefer allocator.free(key_copy);

            // Remove old entry if exists
            if (local_vars.fetchRemove(var_name)) |old| {
                allocator.free(old.key);
                allocator.free(old.value);
            }

            try local_vars.put(key_copy, substituted_value);
            continue;
        }

        // Check for "run taskname [args...]" statement
        if (std.mem.startsWith(u8, content, "run ")) {
            if (registry == null) {
                util.printError("Cannot use 'run' command: no task registry available", .{});
                return error.NoRegistryForRun;
            }

            const rest = std.mem.trim(u8, content[4..], " \t"); // Skip "run "

            // Parse task name and arguments
            var parts = std.mem.splitScalar(u8, rest, ' ');
            const task_name = parts.next() orelse {
                util.printError("Invalid run statement: missing task name", .{});
                return error.InvalidRunStatement;
            };

            // Find the target task
            const target_task = registry.?.findTaskConst(task_name) orelse {
                util.printError("run: task '{s}' not found", .{task_name});
                return error.TaskNotFound;
            };

            // Build vars for the target task
            var run_vars = VarMap.init(allocator);
            defer {
                var iter = run_vars.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                run_vars.deinit();
            }

            // Collect positional arguments
            var arg_idx: usize = 0;
            while (parts.next()) |part| {
                const trimmed_part = std.mem.trim(u8, part, " \t");
                if (trimmed_part.len == 0) continue;

                // Check for --flag=value or --flag value
                if (std.mem.startsWith(u8, trimmed_part, "--")) {
                    // Parse flag
                    const flag_part = trimmed_part[2..];
                    if (std.mem.indexOf(u8, flag_part, "=")) |eq_idx| {
                        const flag_name = flag_part[0..eq_idx];
                        const flag_value = flag_part[eq_idx + 1 ..];
                        const key_copy = try allocator.dupe(u8, flag_name);
                        const val_copy = try allocator.dupe(u8, flag_value);
                        try run_vars.put(key_copy, val_copy);
                    }
                } else {
                    // Positional argument - map to task's argument by index
                    if (arg_idx < target_task.arguments.items.len) {
                        const arg_def = target_task.arguments.items[arg_idx];
                        const key_copy = try allocator.dupe(u8, arg_def.name);
                        const val_copy = try allocator.dupe(u8, trimmed_part);
                        try run_vars.put(key_copy, val_copy);
                    }
                    arg_idx += 1;
                }
            }

            // Apply default flag values
            for (target_task.flags.items) |flag| {
                if (run_vars.get(flag.long_name) == null) {
                    const key_copy = try allocator.dupe(u8, flag.long_name);
                    const val_copy = try allocator.dupe(u8, flag.default_value);
                    try run_vars.put(key_copy, val_copy);
                }
            }

            // Execute the target task recursively
            const code = try executeTaskInternal(allocator, target_task, run_vars, registry, depth + 1, completed);
            if (code != 0) {
                return code;
            }
            continue;
        }

        // Regular command - substitute variables
        const substituted = try substituteVariables(allocator, content, local_vars);
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

            // First check VarMap, then fall back to environment variable
            const value = vars.get(var_name) orelse blk: {
                // Check environment variable as fallback
                var env_name_buf: [256]u8 = undefined;
                if (var_name.len < 256) {
                    @memcpy(env_name_buf[0..var_name.len], var_name);
                    env_name_buf[var_name.len] = 0;
                    break :blk std.posix.getenv(env_name_buf[0..var_name.len :0]) orelse "";
                }
                break :blk "";
            };

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
