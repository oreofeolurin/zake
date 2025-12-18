const std = @import("std");
const util = @import("util.zig");
const main_mod = @import("main.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const fs = std.fs;

/// Result of a stdlib function call
pub const StdlibResult = union(enum) {
    string: []const u8, // Owned string result
    void_result: void, // No return value
    err: []const u8, // Error message
};

/// Execute a stdlib function call
/// Format: zake::namespace.function("arg1", "arg2", ...)
/// Returns the result or an error
pub fn executeStdlibCall(allocator: Allocator, call: []const u8) !StdlibResult {
    // Strip "zake::" prefix
    const prefix = "zake::";
    if (!std.mem.startsWith(u8, call, prefix)) {
        return StdlibResult{ .err = "Invalid stdlib call: missing zake:: prefix" };
    }
    const rest = call[prefix.len..];

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
    var args = try parseArgs(allocator, args_str);
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
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
        std.mem.eql(u8, namespace, "sys");
}

/// Parse comma-separated arguments, handling quoted strings
fn parseArgs(allocator: Allocator, args_str: []const u8) !ArrayList([]const u8) {
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
            while (i < trimmed.len and trimmed[i] != '"') : (i += 1) {}
            const arg = try allocator.dupe(u8, trimmed[start..i]);
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
    _ = allocator;

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

        return StdlibResult{ .string = if (exists) "true" else "false" };
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
        return StdlibResult{ .string = if (contains) "true" else "false" };
    } else {
        return StdlibResult{ .err = "Unknown str function" };
    }
}

/// Execute sys namespace functions (pwd, getcwd, etc.)
fn executeSys(allocator: Allocator, function: []const u8, args: [][]const u8) StdlibResult {
    _ = args; // Currently unused but may be needed for future sys functions
    
    if (std.mem.eql(u8, function, "pwd")) {
        // Get original working directory (where zake was invoked, not where Zakefile is)
        const result = allocator.dupe(u8, main_mod.original_invoke_dir) catch return StdlibResult{ .err = "sys.pwd allocation failed" };
        return StdlibResult{ .string = result };
    } else {
        return StdlibResult{ .err = "Unknown sys function" };
    }
}
