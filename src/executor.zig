const std = @import("std");
const task_mod = @import("task.zig");
const util = @import("util.zig");
const stdlib = @import("stdlib.zig");
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

/// Errors that can occur during task execution
const ExecutorError = error{
    RecursionLimitExceeded,
    DependencyNotFound,
    InvalidLetStatement,
    StdlibError,
    NoRegistryForRun,
    InvalidRunStatement,
    TaskNotFound,
    UnclosedVariable,
    UnclosedEnvVar,
    EnvVarNameTooLong,
    UnclosedCommandSub,
    ChildProcessFailed,
    OutOfMemory,
};

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
    return isTruthy(trimmed);
}

/// Check if a value is "truthy" (non-empty, not "false", not "0", not "no")
fn isTruthy(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\"");
    if (trimmed.len == 0) return false;
    if (std.mem.eql(u8, trimmed, "false")) return false;
    if (std.mem.eql(u8, trimmed, "0")) return false;
    if (std.mem.eql(u8, trimmed, "no")) return false;
    return true;
}

/// Find the position of the ternary '?' operator, skipping those inside quotes/parens
fn findTernaryOperator(expr: []const u8) ?usize {
    var in_quotes = false;
    var paren_depth: usize = 0;
    var i: usize = 0;

    while (i < expr.len) : (i += 1) {
        const c = expr[i];

        if (c == '"' and (i == 0 or expr[i - 1] != '\\')) {
            in_quotes = !in_quotes;
        } else if (!in_quotes) {
            if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (c == '?' and paren_depth == 0) {
                // Make sure it's not ?? (nullish coalescing)
                if (i + 1 < expr.len and expr[i + 1] == '?') {
                    i += 1; // Skip the second ?
                    continue;
                }
                return i;
            }
        }
    }
    return null;
}

/// Find the matching ':' for a ternary operator (after the '?')
fn findColonForTernary(expr: []const u8) ?usize {
    var in_quotes = false;
    var paren_depth: usize = 0;
    var ternary_depth: usize = 0;
    var i: usize = 0;

    while (i < expr.len) : (i += 1) {
        const c = expr[i];

        if (c == '"' and (i == 0 or expr[i - 1] != '\\')) {
            in_quotes = !in_quotes;
        } else if (!in_quotes) {
            if (c == '(') {
                paren_depth += 1;
            } else if (c == ')') {
                if (paren_depth > 0) paren_depth -= 1;
            } else if (c == '?' and paren_depth == 0) {
                // Nested ternary - skip ??
                if (i + 1 < expr.len and expr[i + 1] == '?') {
                    i += 1;
                    continue;
                }
                ternary_depth += 1;
            } else if (c == ':' and paren_depth == 0) {
                if (ternary_depth == 0) {
                    return i;
                }
                ternary_depth -= 1;
            }
        }
    }
    return null;
}

/// Evaluate an expression with operators: ||, ??, and ternary (? :)
/// Returns the first truthy value for ||, first non-empty for ??
/// For ternary: condition ? true_value : false_value (like JavaScript)
/// Also handles function calls and variable substitution
fn evaluateExpression(allocator: Allocator, expression: []const u8, vars: VarMap, registry: ?*const TaskRegistry) ![]const u8 {
    const trimmed = std.mem.trim(u8, expression, " \t");

    // Check for ternary operator (condition ? true_val : false_val) - must check BEFORE ||
    // Need to find ? that's not inside quotes or parens
    if (findTernaryOperator(trimmed)) |q_pos| {
        // Find the matching : for this ?
        const after_q = trimmed[q_pos + 1 ..];
        if (findColonForTernary(after_q)) |colon_offset| {
            const colon_pos = q_pos + 1 + colon_offset;

            const condition_expr = std.mem.trim(u8, trimmed[0..q_pos], " \t");
            const true_expr = std.mem.trim(u8, trimmed[q_pos + 1 .. colon_pos], " \t");
            const false_expr = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");

            // Evaluate condition
            const condition_value = try evaluateSingleValue(allocator, condition_expr, vars, registry);
            defer allocator.free(condition_value);

            // Check if condition is truthy
            const is_truthy = isTruthy(condition_value);

            // Evaluate and return appropriate branch
            if (is_truthy) {
                return evaluateExpression(allocator, true_expr, vars, registry);
            } else {
                return evaluateExpression(allocator, false_expr, vars, registry);
            }
        }
    }

    // Check for || operator (logical OR - first truthy value)
    if (std.mem.indexOf(u8, trimmed, "||")) |op_pos| {
        const left_expr = std.mem.trim(u8, trimmed[0..op_pos], " \t");
        const right_expr = std.mem.trim(u8, trimmed[op_pos + 2 ..], " \t");

        // Evaluate left side
        const left_value = try evaluateSingleValue(allocator, left_expr, vars, registry);
        defer allocator.free(left_value);

        // If left is truthy (non-empty), return it
        const left_trimmed = std.mem.trim(u8, left_value, " \t");
        if (left_trimmed.len > 0) {
            return allocator.dupe(u8, left_value);
        }

        // Otherwise evaluate and return right side
        return evaluateExpression(allocator, right_expr, vars, registry);
    }

    // Check for ?? operator (nullish coalescing - first non-empty)
    if (std.mem.indexOf(u8, trimmed, "??")) |op_pos| {
        const left_expr = std.mem.trim(u8, trimmed[0..op_pos], " \t");
        const right_expr = std.mem.trim(u8, trimmed[op_pos + 2 ..], " \t");

        // Evaluate left side
        const left_value = try evaluateSingleValue(allocator, left_expr, vars, registry);
        defer allocator.free(left_value);

        // If left is non-empty, return it
        const left_trimmed = std.mem.trim(u8, left_value, " \t");
        if (left_trimmed.len > 0) {
            return allocator.dupe(u8, left_value);
        }

        // Otherwise evaluate and return right side
        return evaluateExpression(allocator, right_expr, vars, registry);
    }

    // No operators - evaluate single value
    return evaluateSingleValue(allocator, trimmed, vars, registry);
}

/// Evaluate a single value (no operators)
/// Handles: variable substitution, stdlib calls, string literals
fn evaluateSingleValue(allocator: Allocator, value: []const u8, vars: VarMap, registry: ?*const TaskRegistry) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t");

    // Handle zake::run() specially - executes task and returns exit code
    if (std.mem.startsWith(u8, trimmed, "zake::run(")) {
        return executeZakeRun(allocator, trimmed, vars, registry, false);
    }

    // Handle zake::call() - calls task and captures stdout
    if (std.mem.startsWith(u8, trimmed, "zake::call(")) {
        return executeZakeRun(allocator, trimmed, vars, registry, true);
    }

    // Handle zake::exec() - executes shell command and captures output
    if (std.mem.startsWith(u8, trimmed, "zake::exec(")) {
        return executeZakeExec(allocator, trimmed, vars);
    }

    // Check if it's a stdlib call BEFORE substitution
    if (stdlib.isStdlibCall(trimmed)) {
        const result = try stdlib.executeStdlibCall(allocator, trimmed, vars, @ptrCast(registry));
        return switch (result) {
            .string => |s| s,
            .void_result => try allocator.dupe(u8, ""),
            .err => |e| {
                util.printError("Stdlib error: {s}", .{e});
                return error.StdlibError;
            },
        };
    }

    // Substitute variables
    const substituted = try substituteVariables(allocator, trimmed, vars);

    // Remove surrounding quotes if present
    if (substituted.len >= 2 and substituted[0] == '"' and substituted[substituted.len - 1] == '"') {
        const unquoted = try allocator.dupe(u8, substituted[1 .. substituted.len - 1]);
        allocator.free(substituted);
        return unquoted;
    }

    return substituted;
}

/// Execute a task with given variable bindings
/// Execute zake::run(task_name, args...) or zake::call(task_name, args...)
/// If capture_output is true, captures stdout; otherwise returns exit code
fn executeZakeRun(allocator: Allocator, call: []const u8, vars: VarMap, registry: ?*const TaskRegistry, capture_output: bool) ![]const u8 {
    if (registry == null) {
        util.printError("zake::run/call requires registry context", .{});
        return error.StdlibError;
    }

    // Parse: zake::run(task_name, arg1, arg2, ...) or zake::call(...)
    const prefix = if (capture_output) "zake::call(" else "zake::run(";
    if (!std.mem.startsWith(u8, call, prefix)) {
        return error.InvalidSyntax;
    }

    const close_paren = std.mem.lastIndexOf(u8, call, ")") orelse {
        util.printError("zake::run/call: missing closing parenthesis", .{});
        return error.InvalidSyntax;
    };

    const args_str = call[prefix.len..close_paren];

    // Parse arguments (task name and optional args)
    var raw_args = stdlib.parseArgs(allocator, args_str) catch {
        util.printError("zake::run/call: failed to parse arguments", .{});
        return error.InvalidSyntax;
    };
    defer {
        for (raw_args.items) |arg| allocator.free(arg);
        raw_args.deinit(allocator);
    }

    if (raw_args.items.len == 0) {
        util.printError("zake::run/call requires at least a task name", .{});
        return error.InvalidSyntax;
    }

    // Resolve all arguments (task name and positional args) using vars map
    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    for (raw_args.items) |raw_arg| {
        const resolved = try stdlib.resolveArg(allocator, raw_arg, vars);
        try args.append(allocator, resolved);
    }

    const task_name = args.items[0];

    // Find the task
    const task = registry.?.findTask(task_name) orelse {
        util.printError("zake::run/call: task '{s}' not found", .{task_name});
        return error.TaskNotFound;
    };

    // Build vars for the task (remaining args as positional arguments)
    var task_vars = VarMap.init(allocator);
    defer {
        var iter = task_vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        task_vars.deinit();
    }

    // First, copy global variables from the registry
    var global_iter = registry.?.global_vars.iterator();
    while (global_iter.next()) |entry| {
        const key = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, entry.value_ptr.*);
        try task_vars.put(key, val);
    }

    // Also copy caller's local variables (for nested calls)
    var caller_iter = vars.iterator();
    while (caller_iter.next()) |entry| {
        // Don't overwrite if already set (globals take precedence from registry)
        if (!task_vars.contains(entry.key_ptr.*)) {
            const key = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(key);
            const val = try allocator.dupe(u8, entry.value_ptr.*);
            try task_vars.put(key, val);
        }
    }

    // Map positional arguments to task argument names (overwrite any existing)
    var arg_idx: usize = 1; // Start after task name
    for (task.arguments.items) |task_arg| {
        if (arg_idx < args.items.len) {
            const key = try allocator.dupe(u8, task_arg.name);
            const val = try allocator.dupe(u8, args.items[arg_idx]);
            // Remove old value if exists
            if (task_vars.fetchRemove(task_arg.name)) |old| {
                allocator.free(old.key);
                allocator.free(old.value);
            }
            try task_vars.put(key, val);
            arg_idx += 1;
        } else if (!task_arg.is_optional) {
            util.printError("zake::run/call: missing required argument '{s}' for task '{s}'", .{ task_arg.name, task_name });
            return error.MissingArgument;
        }
    }

    if (capture_output) {
        // For call, we execute the task's script and capture stdout
        // Build a shell script from the task's script lines and execute it
        return executeTaskCaptureOutput(allocator, task, task_vars, registry);
    } else {
        // For run, execute normally and return exit code
        var completed = std.StringHashMap(void).init(allocator);
        defer {
            var it = completed.keyIterator();
            while (it.next()) |key| allocator.free(key.*);
            completed.deinit();
        }

        const exit_code = executeTaskInternal(allocator, task, task_vars, registry, 0, &completed) catch |err| {
            util.printError("zake::run/call: task '{s}' failed: {s}", .{ task.name, @errorName(err) });
            return error.TaskFailed;
        };

        var buf: [16]u8 = undefined;
        const code_str = std.fmt.bufPrint(&buf, "{d}", .{exit_code}) catch "0";
        return allocator.dupe(u8, code_str);
    }
}

/// Execute zake::exec("shell command") - runs shell command and captures output
fn executeZakeExec(allocator: Allocator, call: []const u8, vars: VarMap) ![]const u8 {
    const prefix = "zake::exec(";
    if (!std.mem.startsWith(u8, call, prefix)) {
        return error.InvalidSyntax;
    }

    const close_paren = std.mem.lastIndexOf(u8, call, ")") orelse {
        util.printError("zake::exec: missing closing parenthesis", .{});
        return error.InvalidSyntax;
    };

    const args_str = call[prefix.len..close_paren];

    // Parse the command argument
    var args = stdlib.parseArgs(allocator, args_str) catch {
        util.printError("zake::exec: failed to parse arguments", .{});
        return error.InvalidSyntax;
    };
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    if (args.items.len == 0) {
        util.printError("zake::exec requires a command string", .{});
        return error.InvalidSyntax;
    }

    // Resolve the command argument (supports variables)
    const raw_command = args.items[0];
    const command = try stdlib.resolveArg(allocator, raw_command, vars);
    defer allocator.free(command);

    // Substitute variables in the command
    const substituted_command = try substituteVariables(allocator, command, vars);
    defer allocator.free(substituted_command);

    // Execute the shell command and capture output
    var child = std.process.Child.init(&[_][]const u8{ "/bin/sh", "-c", substituted_command }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const output = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024); // 1MB max

    const term = try child.wait();
    if (term.Exited != 0) {
        allocator.free(output);
        util.printError("zake::exec: command failed with exit code {d}", .{term.Exited});
        return error.CommandFailed;
    }

    // Trim trailing newline
    var result = output;
    while (result.len > 0 and (result[result.len - 1] == '\n' or result[result.len - 1] == '\r')) {
        result = result[0 .. result.len - 1];
    }

    if (result.len != output.len) {
        const trimmed = try allocator.dupe(u8, result);
        allocator.free(output);
        return trimmed;
    }

    return output;
}

/// Execute a task and capture its stdout output
/// Used by zake::call() to get output from tasks
fn executeTaskCaptureOutput(allocator: Allocator, task: *const Task, vars: VarMap, registry: ?*const TaskRegistry) ![]const u8 {
    _ = registry; // May be used for nested runs later

    // Build a combined shell script from all script lines
    var script_builder: std.ArrayList(u8) = .empty;
    defer script_builder.deinit(allocator);

    // Add variable exports
    var var_iter = vars.iterator();
    while (var_iter.next()) |entry| {
        try script_builder.appendSlice(allocator, entry.key_ptr.*);
        try script_builder.appendSlice(allocator, "='");
        // Escape single quotes in value
        for (entry.value_ptr.*) |c| {
            if (c == '\'') {
                try script_builder.appendSlice(allocator, "'\\''");
            } else {
                try script_builder.append(allocator, c);
            }
        }
        try script_builder.appendSlice(allocator, "'\n");
    }

    // Process script lines - only include @ silent commands (output capture)
    for (task.script_lines.items) |script_line| {
        const content = script_line.content;

        // Only capture output from @ prefixed (silent) commands
        const is_silent = script_line.is_silent;
        if (!is_silent) continue;

        // Substitute variables in the content
        const substituted = try substituteVariables(allocator, content, vars);
        defer allocator.free(substituted);

        try script_builder.appendSlice(allocator, substituted);
        try script_builder.append(allocator, '\n');
    }

    if (script_builder.items.len == 0) {
        // No silent commands to capture - return empty string
        return allocator.dupe(u8, "");
    }

    const script = try script_builder.toOwnedSlice(allocator);
    defer allocator.free(script);

    // Execute the script and capture output
    var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", script }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    const output = try child.stdout.?.readToEndAlloc(allocator, 1024 * 1024); // 1MB max

    const term = try child.wait();
    if (term.Exited != 0) {
        allocator.free(output);
        return error.TaskFailed;
    }

    // Trim trailing newline
    var result = output;
    while (result.len > 0 and (result[result.len - 1] == '\n' or result[result.len - 1] == '\r')) {
        result = result[0 .. result.len - 1];
    }

    if (result.len != output.len) {
        const trimmed = try allocator.dupe(u8, result);
        allocator.free(output);
        return trimmed;
    }

    return output;
}

/// Execute a task, returning exit code
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
) anyerror!u8 {
    return executeTaskCore(allocator, task_ptr, vars, registry, depth, completed, false);
}

/// Execute task script only (for matrix expansion, skips matrix check)
fn executeTaskScriptOnly(
    allocator: Allocator,
    task_ptr: *const Task,
    vars: VarMap,
    registry: ?*const TaskRegistry,
    depth: usize,
    completed: *std.StringHashMap(void),
) anyerror!u8 {
    return executeTaskCore(allocator, task_ptr, vars, registry, depth, completed, true);
}

/// Core task execution
fn executeTaskCore(
    allocator: Allocator,
    task_ptr: *const Task,
    vars: VarMap,
    registry: ?*const TaskRegistry,
    depth: usize,
    completed: *std.StringHashMap(void),
    skip_matrix: bool,
) anyerror!u8 {
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

    // Handle matrix execution - run task for each combination
    if (!skip_matrix) {
        if (task_ptr.matrix) |*matrix| {
            var combinations = try matrix.getCombinations(allocator);
            defer {
                for (combinations.items) |*combo| {
                    combo.deinit();
                }
                combinations.deinit(allocator);
            }

            if (combinations.items.len > 0) {
                util.printInfo("Running matrix: {d} combination(s) for '{s}'", .{ combinations.items.len, task_ptr.name });

                for (combinations.items, 0..) |combo, idx| {
                    // Create vars with matrix values added
                    var matrix_vars = VarMap.init(allocator);
                    defer {
                        var iter = matrix_vars.iterator();
                        while (iter.next()) |entry| {
                            allocator.free(entry.key_ptr.*);
                            allocator.free(entry.value_ptr.*);
                        }
                        matrix_vars.deinit();
                    }

                    // Copy incoming vars
                    var incoming_iter = vars.iterator();
                    while (incoming_iter.next()) |entry| {
                        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key_copy);
                        const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
                        try matrix_vars.put(key_copy, value_copy);
                    }

                    // Add matrix variables
                    var combo_iter = combo.iterator();
                    while (combo_iter.next()) |entry| {
                        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(key_copy);
                        const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
                        try matrix_vars.put(key_copy, value_copy);
                    }

                    util.printInfo("[{d}/{d}] {s}", .{ idx + 1, combinations.items.len, task_ptr.name });

                    // Execute task with these vars (skip matrix to avoid infinite recursion)
                    const code = try executeTaskScriptOnly(allocator, task_ptr, matrix_vars, registry, depth, completed);
                    if (code != 0) {
                        return code;
                    }
                }
                return 0;
            }
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
        var content = script_line.content;

        // Check for explicit shell prefix ($) - skip keyword parsing
        const is_explicit_shell = std.mem.startsWith(u8, content, "$ ");
        if (is_explicit_shell) {
            content = std.mem.trim(u8, content[2..], " \t"); // Skip "$ "
        }

        // Check for "let varname = value" statement (unless explicit shell)
        if (!is_explicit_shell and std.mem.startsWith(u8, content, "let ")) {
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

            // Evaluate expression (handles ||, ??, function calls, etc.)
            const evaluated_value = try evaluateExpression(allocator, raw_value, local_vars, registry);
            defer allocator.free(evaluated_value);

            // Store in local_vars (overwrite if exists)
            const key_copy = try allocator.dupe(u8, var_name);
            errdefer allocator.free(key_copy);

            // Remove old entry if exists
            if (local_vars.fetchRemove(var_name)) |old| {
                allocator.free(old.key);
                allocator.free(old.value);
            }

            const value_copy = try allocator.dupe(u8, evaluated_value);
            try local_vars.put(key_copy, value_copy);
            continue;
        }

        // Check for "run taskname [args...]" statement (unless explicit shell)
        if (!is_explicit_shell and std.mem.startsWith(u8, content, "run ")) {
            if (registry == null) {
                util.printError("Cannot use 'run' command: no task registry available", .{});
                return error.NoRegistryForRun;
            }

            const rest_raw = std.mem.trim(u8, content[4..], " \t"); // Skip "run "
            // Substitute variables in the run arguments
            const rest = try substituteVariables(allocator, rest_raw, local_vars);
            defer allocator.free(rest);

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
            if (code != 0 and !script_line.ignore_error) {
                return code;
            }
            continue;
        }

        // Check for stdlib calls: namespace.function(args) (unless explicit shell)
        if (!is_explicit_shell and stdlib.isStdlibCall(content)) {
            // Don't substitute variables - stdlib will resolve args from local_vars
            const result = try stdlib.executeStdlibCall(allocator, content, local_vars, @ptrCast(registry));
            switch (result) {
                .void_result => {},
                .string => |s| {
                    // String results from stdlib are typically used in let statements
                    // For now, just free them if not captured
                    allocator.free(s);
                },
                .err => |e| {
                    if (!script_line.ignore_error) {
                        util.printError("Stdlib error: {s}", .{e});
                        return error.StdlibError;
                    }
                },
            }
            continue;
        }

        // Regular command - substitute variables
        const substituted = try substituteVariables(allocator, content, local_vars);
        defer allocator.free(substituted);

        // Execute the command
        const code = try executeShellCommand(allocator, substituted, !script_line.is_silent);
        if (code != 0 and !script_line.ignore_error) {
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
            const env_val_opt = if (vars.get(var_name) == null) util.lookupEnvVar(gpa, var_name) else null;
            defer if (env_val_opt) |ev| gpa.free(ev);
            const value = vars.get(var_name) orelse (env_val_opt orelse "");

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

            if (var_name.len >= 256) {
                return error.EnvVarNameTooLong;
            }

            const env_value_opt = util.lookupEnvVar(gpa, var_name);
            defer if (env_value_opt) |ev| gpa.free(ev);
            const env_value = env_value_opt orelse "";

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
