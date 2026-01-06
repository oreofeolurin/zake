const std = @import("std");
const util = @import("util.zig");
const main_mod = @import("main.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const fs = std.fs;

/// Variable map type (same as executor.VarMap)
pub const VarMap = StringHashMap([]const u8);

/// Result of a stdlib function call
pub const StdlibResult = union(enum) {
    string: []const u8, // Owned string result
    void_result: void, // No return value
    err: []const u8, // Error message
};

/// Execute a stdlib function call
/// Format: zake::namespace.function(arg1, arg2, ...) or zake::namespace.function("literal", ...)
/// Unquoted args are resolved from vars, quoted args are string literals
/// Returns the result or an error
pub fn executeStdlibCall(allocator: Allocator, call: []const u8, vars: VarMap, registry: ?*const anyopaque) !StdlibResult {
    // Strip "zake::" prefix
    const prefix = "zake::";
    if (!std.mem.startsWith(u8, call, prefix)) {
        return StdlibResult{ .err = "Invalid stdlib call: missing zake:: prefix" };
    }
    const rest = call[prefix.len..];

    // Handle zake::run(task, args...) special case (no namespace)
    if (std.mem.startsWith(u8, rest, "run(")) {
        const paren_pos = 3; // "run".len
        const close_paren = std.mem.lastIndexOf(u8, rest, ")") orelse {
            return StdlibResult{ .err = "Invalid stdlib call: missing closing parenthesis" };
        };
        const args_str = rest[paren_pos + 1 .. close_paren];
        var args = try parseArgs(allocator, args_str);
        defer {
            for (args.items) |arg| allocator.free(arg);
            args.deinit(allocator);
        }
        return executeRun(allocator, args.items, registry);
    }

    // Parse: namespace.function(args)
    const dot_pos = std.mem.indexOf(u8, rest, ".") orelse {
        return StdlibResult{ .err = "Invalid stdlib call: missing namespace" };
    };

    const paren_pos = std.mem.indexOf(u8, rest, "(") orelse {
        return StdlibResult{ .err = "Invalid stdlib call: missing opening parenthesis" };
    };

    if (paren_pos <= dot_pos) {
        return StdlibResult{ .err = "Invalid stdlib call format" };
    }

    const namespace = rest[0..dot_pos];
    const function = rest[dot_pos + 1 .. paren_pos];

    // Find closing paren
    const close_paren = std.mem.lastIndexOf(u8, rest, ")") orelse {
        return StdlibResult{ .err = "Invalid stdlib call: missing closing parenthesis" };
    };

    // Parse arguments
    const args_str = rest[paren_pos + 1 .. close_paren];
    var raw_args = try parseArgs(allocator, args_str);
    defer {
        for (raw_args.items) |arg| allocator.free(arg);
        raw_args.deinit(allocator);
    }

    // Resolve each argument: quoted = literal, unquoted = variable lookup
    var args: ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    for (raw_args.items) |raw_arg| {
        const resolved = try resolveArg(allocator, raw_arg, vars);
        try args.append(allocator, resolved);
    }

    // Dispatch to namespace
    if (std.mem.eql(u8, namespace, "log")) {
        return executeLog(function, args.items);
    } else if (std.mem.eql(u8, namespace, "fs")) {
        return executeFs(allocator, function, args.items);
    } else if (std.mem.eql(u8, namespace, "path")) {
        return executePath(allocator, function, args.items);
    } else if (std.mem.eql(u8, namespace, "str")) {
        return executeStr(allocator, function, args.items);
    } else if (std.mem.eql(u8, namespace, "sys")) {
        return executeSys(allocator, function, args.items);
    } else if (std.mem.eql(u8, namespace, "io")) {
        return executeIo(allocator, function, args.items);
    } else if (std.mem.eql(u8, namespace, "json")) {
        return executeJson(allocator, function, args.items);
    } else {
        return StdlibResult{ .err = "Unknown stdlib namespace" };
    }
}

/// Check if a line looks like a stdlib call (zake::namespace.function(...))
pub fn isStdlibCall(line: []const u8) bool {
    // Must start with "zake::"
    const prefix = "zake::";
    if (!std.mem.startsWith(u8, line, prefix)) return false;

    const rest = line[prefix.len..];

    // Must have a dot before a paren
    const dot_pos = std.mem.indexOf(u8, rest, ".") orelse return false;
    const paren_pos = std.mem.indexOf(u8, rest, "(") orelse return false;

    // Dot must come before paren
    if (dot_pos >= paren_pos) return false;

    // Must end with )
    if (rest.len == 0 or rest[rest.len - 1] != ')') return false;

    // Namespace must be valid identifier
    const namespace = rest[0..dot_pos];
    if (namespace.len == 0) return false;

    // Check it's a known namespace
    return std.mem.eql(u8, namespace, "log") or
        std.mem.eql(u8, namespace, "fs") or
        std.mem.eql(u8, namespace, "path") or
        std.mem.eql(u8, namespace, "str") or
        std.mem.eql(u8, namespace, "sys") or
        std.mem.eql(u8, namespace, "io") or
        std.mem.eql(u8, namespace, "json");
}

/// Resolve a stdlib argument:
/// - Quoted strings ("value") -> return the literal value (without quotes)
/// - Unquoted identifiers (varname) -> look up in vars map
/// - If not found in vars, return as-is (might be a literal like a number)
pub fn resolveArg(allocator: Allocator, raw_arg: []const u8, vars: VarMap) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw_arg, " \t");

    // Quoted string - return literal (quotes already stripped by parseArgs for escaped strings)
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }

    // Unquoted - look up in variables
    if (vars.get(trimmed)) |value| {
        return allocator.dupe(u8, value);
    }

    // Not found - return as literal (could be a number or other literal)
    return allocator.dupe(u8, trimmed);
}

/// Parse comma-separated arguments, handling quoted strings with escape sequences
pub fn parseArgs(allocator: Allocator, args_str: []const u8) !ArrayList([]const u8) {
    var args: ArrayList([]const u8) = .empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    const trimmed = std.mem.trim(u8, args_str, " \t");
    if (trimmed.len == 0) return args;

    var i: usize = 0;
    while (i < trimmed.len) {
        // Skip whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
        if (i >= trimmed.len) break;

        // Check for quoted string
        if (trimmed[i] == '"') {
            i += 1; // Skip opening quote
            const start = i;
            // Find closing quote, skipping escaped quotes
            while (i < trimmed.len) {
                if (trimmed[i] == '"' and (i == 0 or trimmed[i - 1] != '\\')) {
                    break; // Found unescaped closing quote
                }
                i += 1;
            }
            // Process escape sequences and extract arg
            const raw_arg = trimmed[start..i];
            const arg = try processEscapes(allocator, raw_arg);
            try args.append(allocator, arg);
            if (i < trimmed.len) i += 1; // Skip closing quote
        } else {
            // Unquoted arg - read until comma or end
            const start = i;
            while (i < trimmed.len and trimmed[i] != ',') : (i += 1) {}
            const arg = std.mem.trim(u8, trimmed[start..i], " \t");
            if (arg.len > 0) {
                const arg_copy = try allocator.dupe(u8, arg);
                try args.append(allocator, arg_copy);
            }
        }

        // Skip comma
        while (i < trimmed.len and (trimmed[i] == ',' or trimmed[i] == ' ' or trimmed[i] == '\t')) : (i += 1) {}
    }

    return args;
}

/// Process escape sequences in a string (\" -> ", \\ -> \)
fn processEscapes(allocator: Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const next = input[i + 1];
            if (next == '"' or next == '\\') {
                try result.append(allocator, next);
                i += 2;
                continue;
            }
        }
        try result.append(allocator, input[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// log namespace - Colored logging
// ============================================================================

fn executeLog(function: []const u8, args: []const []const u8) StdlibResult {
    if (args.len == 0) {
        return StdlibResult{ .err = "log functions require a message argument" };
    }

    const message = args[0];

    if (std.mem.eql(u8, function, "info")) {
        util.printInfo("{s}", .{message});
    } else if (std.mem.eql(u8, function, "success")) {
        util.printSuccess("{s}", .{message});
    } else if (std.mem.eql(u8, function, "warn")) {
        util.printWarning("{s}", .{message});
    } else if (std.mem.eql(u8, function, "error")) {
        util.printError("{s}", .{message});
    } else {
        return StdlibResult{ .err = "Unknown log function" };
    }

    return StdlibResult{ .void_result = {} };
}

// ============================================================================
// fs namespace - File system operations
// ============================================================================

fn executeFs(allocator: Allocator, function: []const u8, args: []const []const u8) StdlibResult {
    if (std.mem.eql(u8, function, "mkdir")) {
        if (args.len == 0) return StdlibResult{ .err = "fs.mkdir requires a path argument" };
        const path = args[0];

        // Create directory (mkdir -p style)
        fs.cwd().makePath(path) catch |err| {
            std.debug.print("fs.mkdir failed: {s}\n", .{@errorName(err)});
            return StdlibResult{ .err = "fs.mkdir failed" };
        };
        return StdlibResult{ .void_result = {} };
    } else if (std.mem.eql(u8, function, "remove")) {
        if (args.len == 0) return StdlibResult{ .err = "fs.remove requires a path argument" };
        const path = args[0];

        // Try to delete as file first, then as directory
        fs.cwd().deleteFile(path) catch {
            fs.cwd().deleteTree(path) catch |err| {
                std.debug.print("fs.remove failed: {s}\n", .{@errorName(err)});
                return StdlibResult{ .err = "fs.remove failed" };
            };
        };
        return StdlibResult{ .void_result = {} };
    } else if (std.mem.eql(u8, function, "exists")) {
        if (args.len == 0) return StdlibResult{ .err = "fs.exists requires a path argument" };
        const path = args[0];

        // Check if file/dir exists
        const exists = blk: {
            fs.cwd().access(path, .{}) catch break :blk false;
            break :blk true;
        };

        const result = allocator.dupe(u8, if (exists) "true" else "false") catch return StdlibResult{ .err = "fs.exists allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "copy")) {
        if (args.len < 2) return StdlibResult{ .err = "fs.copy requires source and destination arguments" };
        const src = args[0];
        const dest = args[1];

        fs.cwd().copyFile(src, fs.cwd(), dest, .{}) catch |err| {
            std.debug.print("fs.copy failed: {s}\n", .{@errorName(err)});
            return StdlibResult{ .err = "fs.copy failed" };
        };
        return StdlibResult{ .void_result = {} };
    } else {
        return StdlibResult{ .err = "Unknown fs function" };
    }
}

// ============================================================================
// path namespace - Path manipulation
// ============================================================================

fn executePath(allocator: Allocator, function: []const u8, args: []const []const u8) StdlibResult {
    if (std.mem.eql(u8, function, "join")) {
        if (args.len == 0) return StdlibResult{ .string = "" };

        // Join all args with path separator
        var result: ArrayList(u8) = .empty;
        for (args, 0..) |part, i| {
            if (i > 0 and result.items.len > 0 and result.items[result.items.len - 1] != '/') {
                result.append(allocator, '/') catch return StdlibResult{ .err = "path.join allocation failed" };
            }
            result.appendSlice(allocator, part) catch return StdlibResult{ .err = "path.join allocation failed" };
        }

        return StdlibResult{ .string = result.toOwnedSlice(allocator) catch return StdlibResult{ .err = "path.join allocation failed" } };
    } else if (std.mem.eql(u8, function, "basename")) {
        if (args.len == 0) return StdlibResult{ .err = "path.basename requires a path argument" };
        const path = args[0];

        const basename = std.fs.path.basename(path);
        const result = allocator.dupe(u8, basename) catch return StdlibResult{ .err = "path.basename allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "dirname")) {
        if (args.len == 0) return StdlibResult{ .err = "path.dirname requires a path argument" };
        const path = args[0];

        const dirname = std.fs.path.dirname(path) orelse ".";
        const result = allocator.dupe(u8, dirname) catch return StdlibResult{ .err = "path.dirname allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "ext")) {
        if (args.len == 0) return StdlibResult{ .err = "path.ext requires a path argument" };
        const path = args[0];

        const ext = std.fs.path.extension(path);
        const result = allocator.dupe(u8, ext) catch return StdlibResult{ .err = "path.ext allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "last")) {
        // Get last N path components
        // Usage: zake::path.last(N) -> uses original pwd (where zake was invoked)
        //        zake::path.last(path, N) -> uses provided path
        const count_arg_idx: usize = if (args.len == 1) 0 else if (args.len == 2) 1 else {
            return StdlibResult{ .err = "path.last requires 1 or 2 arguments" };
        };

        const count_str = args[count_arg_idx];
        const count = std.fmt.parseInt(usize, count_str, 10) catch {
            return StdlibResult{ .err = "path.last count must be a number" };
        };

        // Get the path to process
        const path_to_process = if (args.len == 1) blk: {
            // Use original working directory (where zake was invoked)
            break :blk main_mod.original_invoke_dir;
        } else args[0];

        // Split path and get last N components
        var components: ArrayList([]const u8) = .empty;
        defer components.deinit(allocator);

        var path_iter = std.mem.splitScalar(u8, path_to_process, '/');
        while (path_iter.next()) |component| {
            if (component.len > 0) {
                components.append(allocator, component) catch {
                    return StdlibResult{ .err = "path.last allocation failed" };
                };
            }
        }

        if (components.items.len >= count) {
            const start_idx = components.items.len - count;
            const result_parts = components.items[start_idx..];

            // Join with /
            var result: ArrayList(u8) = .empty;
            defer result.deinit(allocator);

            for (result_parts, 0..) |part, i| {
                if (i > 0) result.append(allocator, '/') catch {
                    return StdlibResult{ .err = "path.last allocation failed" };
                };
                result.appendSlice(allocator, part) catch {
                    return StdlibResult{ .err = "path.last allocation failed" };
                };
            }

            const final = result.toOwnedSlice(allocator) catch {
                return StdlibResult{ .err = "path.last allocation failed" };
            };
            return StdlibResult{ .string = final };
        } else {
            // Not enough components, return full path
            const result = allocator.dupe(u8, path_to_process) catch return StdlibResult{ .err = "path.last allocation failed" };
            return StdlibResult{ .string = result };
        }
    } else {
        return StdlibResult{ .err = "Unknown path function" };
    }
}

// ============================================================================
// str namespace - String manipulation
// ============================================================================

fn executeStr(allocator: Allocator, function: []const u8, args: []const []const u8) StdlibResult {
    if (std.mem.eql(u8, function, "upper")) {
        if (args.len == 0) return StdlibResult{ .err = "str.upper requires a string argument" };
        const input = args[0];

        var result = allocator.alloc(u8, input.len) catch return StdlibResult{ .err = "str.upper allocation failed" };
        for (input, 0..) |c, i| {
            result[i] = std.ascii.toUpper(c);
        }
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "lower")) {
        if (args.len == 0) return StdlibResult{ .err = "str.lower requires a string argument" };
        const input = args[0];

        var result = allocator.alloc(u8, input.len) catch return StdlibResult{ .err = "str.lower allocation failed" };
        for (input, 0..) |c, i| {
            result[i] = std.ascii.toLower(c);
        }
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "replace")) {
        if (args.len < 3) return StdlibResult{ .err = "str.replace requires string, old, new arguments" };
        const input = args[0];
        const old = args[1];
        const new = args[2];

        // Simple replace all
        var result: ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < input.len) {
            if (i + old.len <= input.len and std.mem.eql(u8, input[i .. i + old.len], old)) {
                result.appendSlice(allocator, new) catch return StdlibResult{ .err = "str.replace allocation failed" };
                i += old.len;
            } else {
                result.append(allocator, input[i]) catch return StdlibResult{ .err = "str.replace allocation failed" };
                i += 1;
            }
        }

        return StdlibResult{ .string = result.toOwnedSlice(allocator) catch return StdlibResult{ .err = "str.replace allocation failed" } };
    } else if (std.mem.eql(u8, function, "trim")) {
        if (args.len == 0) return StdlibResult{ .err = "str.trim requires a string argument" };
        const input = args[0];

        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        const result = allocator.dupe(u8, trimmed) catch return StdlibResult{ .err = "str.trim allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "contains")) {
        if (args.len < 2) return StdlibResult{ .err = "str.contains requires string and substring arguments" };
        const haystack = args[0];
        const needle = args[1];

        const contains = std.mem.indexOf(u8, haystack, needle) != null;
        const result = allocator.dupe(u8, if (contains) "true" else "false") catch return StdlibResult{ .err = "str.contains allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "is_empty")) {
        // Check if string is empty or whitespace only
        // Usage: zake::str.is_empty("") -> "true", zake::str.is_empty("  ") -> "true"
        if (args.len == 0) return StdlibResult{ .err = "str.is_empty requires a string argument" };
        const input = args[0];

        const trimmed = std.mem.trim(u8, input, " \t\n\r");
        const result = allocator.dupe(u8, if (trimmed.len == 0) "true" else "false") catch return StdlibResult{ .err = "str.is_empty allocation failed" };
        return StdlibResult{ .string = result };
    } else {
        return StdlibResult{ .err = "Unknown str function" };
    }
}

/// Execute sys namespace functions (pwd, env)
fn executeSys(allocator: Allocator, function: []const u8, args: []const []const u8) StdlibResult {
    if (std.mem.eql(u8, function, "pwd")) {
        // Get original working directory (where zake was invoked, not where Zakefile is)
        const result = allocator.dupe(u8, main_mod.original_invoke_dir) catch return StdlibResult{ .err = "sys.pwd allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "env")) {
        // Get environment variable with optional default
        // Usage: zake::sys.env("VAR") or zake::sys.env("VAR", "default")
        if (args.len == 0) return StdlibResult{ .err = "sys.env requires at least one argument (variable name)" };

        const var_name = args[0];
        const default_value = if (args.len >= 2) args[1] else "";

        // Get environment variable
        var env_name_buf: [256]u8 = undefined;
        if (var_name.len >= 256) {
            return StdlibResult{ .err = "sys.env: variable name too long" };
        }
        @memcpy(env_name_buf[0..var_name.len], var_name);
        env_name_buf[var_name.len] = 0;

        const env_value = std.posix.getenv(env_name_buf[0..var_name.len :0]) orelse default_value;
        const result = allocator.dupe(u8, env_value) catch return StdlibResult{ .err = "sys.env allocation failed" };
        return StdlibResult{ .string = result };
    } else {
        return StdlibResult{ .err = "Unknown sys function" };
    }
}

// ============================================================================
// io namespace - Input/Output operations
// ============================================================================

/// Read a line from stdin up to newline
fn readLineFromStdin(buf: []u8) ![]u8 {
    const stdin_file = std.fs.File.stdin();
    var i: usize = 0;
    while (i < buf.len) {
        const bytes_read = stdin_file.read(buf[i .. i + 1]) catch |err| {
            if (i == 0) return err;
            break;
        };
        if (bytes_read == 0) break; // EOF
        if (buf[i] == '\n') break;
        i += 1;
    }
    return buf[0..i];
}

fn executeIo(allocator: Allocator, function: []const u8, args: []const []const u8) StdlibResult {
    const stdout_file = std.fs.File.stdout();

    if (std.mem.eql(u8, function, "prompt")) {
        // Prompt user for input
        // Usage: zake::io.prompt("Enter your name: ")
        if (args.len == 0) return StdlibResult{ .err = "io.prompt requires a message argument" };

        const message = args[0];
        _ = stdout_file.write(message) catch return StdlibResult{ .err = "io.prompt: failed to write prompt" };

        // Read line from stdin
        var buf: [4096]u8 = undefined;
        const line = readLineFromStdin(&buf) catch {
            return StdlibResult{ .string = allocator.dupe(u8, "") catch return StdlibResult{ .err = "io.prompt allocation failed" } };
        };

        const result = allocator.dupe(u8, line) catch return StdlibResult{ .err = "io.prompt allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "prompt_secret")) {
        // Prompt for secret input (no echo)
        // Usage: zake::io.prompt_secret("Password: ")
        if (args.len == 0) return StdlibResult{ .err = "io.prompt_secret requires a message argument" };

        const message = args[0];
        _ = stdout_file.write(message) catch return StdlibResult{ .err = "io.prompt_secret: failed to write prompt" };

        // Disable echo for password input
        const stdin_file = std.fs.File.stdin();
        const stdin_fd = stdin_file.handle;
        var termios = std.posix.tcgetattr(stdin_fd) catch {
            // Fallback to regular input if terminal control not available
            var buf: [4096]u8 = undefined;
            const line = readLineFromStdin(&buf) catch {
                return StdlibResult{ .string = allocator.dupe(u8, "") catch return StdlibResult{ .err = "io.prompt_secret allocation failed" } };
            };
            const result = allocator.dupe(u8, line) catch return StdlibResult{ .err = "io.prompt_secret allocation failed" };
            return StdlibResult{ .string = result };
        };

        // Save original settings and disable echo
        const original_lflag = termios.lflag;
        termios.lflag.ECHO = false;
        std.posix.tcsetattr(stdin_fd, .NOW, termios) catch {};

        // Read the secret
        var buf: [4096]u8 = undefined;
        const line = readLineFromStdin(&buf) catch blk: {
            // Restore echo before returning
            termios.lflag = original_lflag;
            std.posix.tcsetattr(stdin_fd, .NOW, termios) catch {};
            _ = stdout_file.write("\n") catch {};
            break :blk "";
        };

        // Restore echo and print newline
        termios.lflag = original_lflag;
        std.posix.tcsetattr(stdin_fd, .NOW, termios) catch {};
        _ = stdout_file.write("\n") catch {};

        const result = allocator.dupe(u8, line) catch return StdlibResult{ .err = "io.prompt_secret allocation failed" };
        return StdlibResult{ .string = result };
    } else if (std.mem.eql(u8, function, "confirm")) {
        // Yes/no confirmation
        // Usage: zake::io.confirm("Are you sure?") returns "true" or "false"
        if (args.len == 0) return StdlibResult{ .err = "io.confirm requires a message argument" };

        const message = args[0];
        _ = stdout_file.write(message) catch return StdlibResult{ .err = "io.confirm: failed to write prompt" };
        _ = stdout_file.write(" (yes/no): ") catch {};

        var buf: [256]u8 = undefined;
        const line = readLineFromStdin(&buf) catch {
            const result = allocator.dupe(u8, "false") catch return StdlibResult{ .err = "io.confirm allocation failed" };
            return StdlibResult{ .string = result };
        };

        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        const confirmed = std.mem.eql(u8, trimmed, "yes") or
            std.mem.eql(u8, trimmed, "y") or
            std.mem.eql(u8, trimmed, "Y") or
            std.mem.eql(u8, trimmed, "YES");

        const result = allocator.dupe(u8, if (confirmed) "true" else "false") catch return StdlibResult{ .err = "io.confirm allocation failed" };
        return StdlibResult{ .string = result };
    } else {
        return StdlibResult{ .err = "Unknown io function" };
    }
}

// ============================================================================
// json namespace - JSON manipulation (simple key-value operations)
// ============================================================================

fn executeJson(allocator: Allocator, function: []const u8, args: []const []const u8) StdlibResult {
    if (std.mem.eql(u8, function, "get")) {
        // Get value from JSON string by key
        // Usage: zake::json.get('{"key": "value"}', "key") -> "value"
        if (args.len < 2) return StdlibResult{ .err = "json.get requires json_string and key arguments" };

        const json_str = args[0];
        const key = args[1];

        // Parse JSON
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return StdlibResult{ .err = "json.get: invalid JSON" };
        };
        defer parsed.deinit();

        // Navigate to key
        switch (parsed.value) {
            .object => |obj| {
                if (obj.get(key)) |value| {
                    return jsonValueToString(allocator, value);
                } else {
                    // Key not found - return empty string
                    const result = allocator.dupe(u8, "") catch return StdlibResult{ .err = "json.get allocation failed" };
                    return StdlibResult{ .string = result };
                }
            },
            else => return StdlibResult{ .err = "json.get: expected object" },
        }
    } else if (std.mem.eql(u8, function, "set")) {
        // Set value in JSON string
        // Usage: zake::json.set(existing, key, value) or zake::json.set('{"a": 1}', "b", "2") -> '{"a":1,"b":"2"}'
        if (args.len < 3) return StdlibResult{ .err = "json.set requires json_string, key, and value arguments" };

        const json_str = args[0];
        const key = args[1];
        const new_value = args[2];

        // Parse existing JSON
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            // If invalid JSON or empty, start with empty object
            var result: ArrayList(u8) = .empty;
            result.appendSlice(allocator, "{\"") catch return StdlibResult{ .err = "json.set allocation failed" };
            result.appendSlice(allocator, key) catch return StdlibResult{ .err = "json.set allocation failed" };
            result.appendSlice(allocator, "\":\"") catch return StdlibResult{ .err = "json.set allocation failed" };
            // Escape the value
            for (new_value) |c| {
                switch (c) {
                    '"' => result.appendSlice(allocator, "\\\"") catch return StdlibResult{ .err = "json.set allocation failed" },
                    '\\' => result.appendSlice(allocator, "\\\\") catch return StdlibResult{ .err = "json.set allocation failed" },
                    '\n' => result.appendSlice(allocator, "\\n") catch return StdlibResult{ .err = "json.set allocation failed" },
                    '\r' => result.appendSlice(allocator, "\\r") catch return StdlibResult{ .err = "json.set allocation failed" },
                    '\t' => result.appendSlice(allocator, "\\t") catch return StdlibResult{ .err = "json.set allocation failed" },
                    else => result.append(allocator, c) catch return StdlibResult{ .err = "json.set allocation failed" },
                }
            }
            result.appendSlice(allocator, "\"}") catch return StdlibResult{ .err = "json.set allocation failed" };
            return StdlibResult{ .string = result.toOwnedSlice(allocator) catch return StdlibResult{ .err = "json.set allocation failed" } };
        };
        defer parsed.deinit();

        // Rebuild JSON with new key
        switch (parsed.value) {
            .object => |obj| {
                var result: ArrayList(u8) = .empty;
                result.append(allocator, '{') catch return StdlibResult{ .err = "json.set allocation failed" };

                var first = true;
                var it = obj.iterator();
                var key_found = false;

                while (it.next()) |entry| {
                    if (!first) {
                        result.append(allocator, ',') catch return StdlibResult{ .err = "json.set allocation failed" };
                    }
                    first = false;

                    result.append(allocator, '"') catch return StdlibResult{ .err = "json.set allocation failed" };
                    result.appendSlice(allocator, entry.key_ptr.*) catch return StdlibResult{ .err = "json.set allocation failed" };
                    result.appendSlice(allocator, "\":") catch return StdlibResult{ .err = "json.set allocation failed" };

                    if (std.mem.eql(u8, entry.key_ptr.*, key)) {
                        // Replace with new value
                        result.append(allocator, '"') catch return StdlibResult{ .err = "json.set allocation failed" };
                        for (new_value) |c| {
                            switch (c) {
                                '"' => result.appendSlice(allocator, "\\\"") catch return StdlibResult{ .err = "json.set allocation failed" },
                                '\\' => result.appendSlice(allocator, "\\\\") catch return StdlibResult{ .err = "json.set allocation failed" },
                                '\n' => result.appendSlice(allocator, "\\n") catch return StdlibResult{ .err = "json.set allocation failed" },
                                '\r' => result.appendSlice(allocator, "\\r") catch return StdlibResult{ .err = "json.set allocation failed" },
                                '\t' => result.appendSlice(allocator, "\\t") catch return StdlibResult{ .err = "json.set allocation failed" },
                                else => result.append(allocator, c) catch return StdlibResult{ .err = "json.set allocation failed" },
                            }
                        }
                        result.append(allocator, '"') catch return StdlibResult{ .err = "json.set allocation failed" };
                        key_found = true;
                    } else {
                        // Keep original value
                        appendJsonValue(allocator, &result, entry.value_ptr.*) catch return StdlibResult{ .err = "json.set allocation failed" };
                    }
                }

                // Add new key if not found
                if (!key_found) {
                    if (!first) {
                        result.append(allocator, ',') catch return StdlibResult{ .err = "json.set allocation failed" };
                    }
                    result.append(allocator, '"') catch return StdlibResult{ .err = "json.set allocation failed" };
                    result.appendSlice(allocator, key) catch return StdlibResult{ .err = "json.set allocation failed" };
                    result.appendSlice(allocator, "\":\"") catch return StdlibResult{ .err = "json.set allocation failed" };
                    for (new_value) |c| {
                        switch (c) {
                            '"' => result.appendSlice(allocator, "\\\"") catch return StdlibResult{ .err = "json.set allocation failed" },
                            '\\' => result.appendSlice(allocator, "\\\\") catch return StdlibResult{ .err = "json.set allocation failed" },
                            '\n' => result.appendSlice(allocator, "\\n") catch return StdlibResult{ .err = "json.set allocation failed" },
                            '\r' => result.appendSlice(allocator, "\\r") catch return StdlibResult{ .err = "json.set allocation failed" },
                            '\t' => result.appendSlice(allocator, "\\t") catch return StdlibResult{ .err = "json.set allocation failed" },
                            else => result.append(allocator, c) catch return StdlibResult{ .err = "json.set allocation failed" },
                        }
                    }
                    result.append(allocator, '"') catch return StdlibResult{ .err = "json.set allocation failed" };
                }

                result.append(allocator, '}') catch return StdlibResult{ .err = "json.set allocation failed" };
                return StdlibResult{ .string = result.toOwnedSlice(allocator) catch return StdlibResult{ .err = "json.set allocation failed" } };
            },
            else => return StdlibResult{ .err = "json.set: expected object" },
        }
    } else if (std.mem.eql(u8, function, "has")) {
        // Check if JSON has key
        // Usage: zake::json.has(existing, key) or zake::json.has('{"key": "value"}', "key") -> "true"
        if (args.len < 2) return StdlibResult{ .err = "json.has requires json_string and key arguments" };

        const json_str = args[0];
        const key = args[1];

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            const result = allocator.dupe(u8, "false") catch return StdlibResult{ .err = "json.has allocation failed" };
            return StdlibResult{ .string = result };
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| {
                const has_key = obj.contains(key);
                const result = allocator.dupe(u8, if (has_key) "true" else "false") catch return StdlibResult{ .err = "json.has allocation failed" };
                return StdlibResult{ .string = result };
            },
            else => {
                const result = allocator.dupe(u8, "false") catch return StdlibResult{ .err = "json.has allocation failed" };
                return StdlibResult{ .string = result };
            },
        }
    } else if (std.mem.eql(u8, function, "delete")) {
        // Delete key from JSON
        // Usage: zake::json.delete(existing, key) or zake::json.delete('{"a": 1, "b": 2}', "a") -> '{"b":2}'
        if (args.len < 2) return StdlibResult{ .err = "json.delete requires json_string and key arguments" };

        const json_str = args[0];
        const key = args[1];

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return StdlibResult{ .err = "json.delete: invalid JSON" };
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| {
                var result: ArrayList(u8) = .empty;
                result.append(allocator, '{') catch return StdlibResult{ .err = "json.delete allocation failed" };

                var first = true;
                var it = obj.iterator();

                while (it.next()) |entry| {
                    // Skip the key to delete
                    if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;

                    if (!first) {
                        result.append(allocator, ',') catch return StdlibResult{ .err = "json.delete allocation failed" };
                    }
                    first = false;

                    result.append(allocator, '"') catch return StdlibResult{ .err = "json.delete allocation failed" };
                    result.appendSlice(allocator, entry.key_ptr.*) catch return StdlibResult{ .err = "json.delete allocation failed" };
                    result.appendSlice(allocator, "\":") catch return StdlibResult{ .err = "json.delete allocation failed" };
                    appendJsonValue(allocator, &result, entry.value_ptr.*) catch return StdlibResult{ .err = "json.delete allocation failed" };
                }

                result.append(allocator, '}') catch return StdlibResult{ .err = "json.delete allocation failed" };
                return StdlibResult{ .string = result.toOwnedSlice(allocator) catch return StdlibResult{ .err = "json.delete allocation failed" } };
            },
            else => return StdlibResult{ .err = "json.delete: expected object" },
        }
    } else if (std.mem.eql(u8, function, "keys")) {
        // Get all keys from JSON object
        // Usage: zake::json.keys('{"a": 1, "b": 2}') -> "a,b"
        if (args.len == 0) return StdlibResult{ .err = "json.keys requires a json_string argument" };

        const json_str = args[0];

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return StdlibResult{ .err = "json.keys: invalid JSON" };
        };
        defer parsed.deinit();

        switch (parsed.value) {
            .object => |obj| {
                var result: ArrayList(u8) = .empty;
                var first = true;
                var it = obj.iterator();

                while (it.next()) |entry| {
                    if (!first) {
                        result.append(allocator, ',') catch return StdlibResult{ .err = "json.keys allocation failed" };
                    }
                    first = false;
                    result.appendSlice(allocator, entry.key_ptr.*) catch return StdlibResult{ .err = "json.keys allocation failed" };
                }

                return StdlibResult{ .string = result.toOwnedSlice(allocator) catch return StdlibResult{ .err = "json.keys allocation failed" } };
            },
            else => return StdlibResult{ .err = "json.keys: expected object" },
        }
    } else {
        return StdlibResult{ .err = "Unknown json function" };
    }
}

// ============================================================================
// zake::run - Execute task and capture output
// ============================================================================

fn executeRun(allocator: Allocator, args: []const []const u8, registry_ptr: ?*const anyopaque) StdlibResult {
    _ = allocator;
    _ = args;
    _ = registry_ptr;
    // This is a placeholder. The actual execution happens in executor.zig
    // because stdlib cannot depend on executor (circular dependency).
    // We return a specific error that executor.zig will catch and handle.
    return StdlibResult{ .err = "__ZAKE_RUN_TASK__" };
}

/// Convert a JSON value to a string result
fn jsonValueToString(allocator: Allocator, value: std.json.Value) StdlibResult {
    switch (value) {
        .string => |s| {
            const result = allocator.dupe(u8, s) catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return StdlibResult{ .err = "json format failed" };
            const result = allocator.dupe(u8, slice) catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return StdlibResult{ .err = "json format failed" };
            const result = allocator.dupe(u8, slice) catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
        .bool => |b| {
            const result = allocator.dupe(u8, if (b) "true" else "false") catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
        .null => {
            const result = allocator.dupe(u8, "null") catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
        .number_string => |s| {
            const result = allocator.dupe(u8, s) catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
        else => {
            // For arrays and objects, return empty for now
            const result = allocator.dupe(u8, "") catch return StdlibResult{ .err = "json allocation failed" };
            return StdlibResult{ .string = result };
        },
    }
}

/// Append a JSON value to an ArrayList
fn appendJsonValue(allocator: Allocator, result: *ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .string => |s| {
            try result.append(allocator, '"');
            for (s) |c| {
                switch (c) {
                    '"' => try result.appendSlice(allocator, "\\\""),
                    '\\' => try result.appendSlice(allocator, "\\\\"),
                    '\n' => try result.appendSlice(allocator, "\\n"),
                    '\r' => try result.appendSlice(allocator, "\\r"),
                    '\t' => try result.appendSlice(allocator, "\\t"),
                    else => try result.append(allocator, c),
                }
            }
            try result.append(allocator, '"');
        },
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return;
            try result.appendSlice(allocator, slice);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return;
            try result.appendSlice(allocator, slice);
        },
        .bool => |b| {
            try result.appendSlice(allocator, if (b) "true" else "false");
        },
        .null => {
            try result.appendSlice(allocator, "null");
        },
        .number_string => |s| {
            try result.appendSlice(allocator, s);
        },
        .array => |arr| {
            try result.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try result.append(allocator, ',');
                try appendJsonValue(allocator, result, item);
            }
            try result.append(allocator, ']');
        },
        .object => |obj| {
            try result.append(allocator, '{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try result.append(allocator, ',');
                first = false;
                try result.append(allocator, '"');
                try result.appendSlice(allocator, entry.key_ptr.*);
                try result.appendSlice(allocator, "\":");
                try appendJsonValue(allocator, result, entry.value_ptr.*);
            }
            try result.append(allocator, '}');
        },
    }
}
