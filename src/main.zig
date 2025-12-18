const std = @import("std");
const parser_mod = @import("parser.zig");
const executor_mod = @import("executor.zig");
const help_mod = @import("help.zig");
const task_mod = @import("task.zig");
const util = @import("util.zig");

const Parser = parser_mod.Parser;
const TaskRegistry = task_mod.TaskRegistry;
const VarMap = executor_mod.VarMap;

/// Original directory where zake was invoked (before chdir to Zakefile location)
pub var original_invoke_dir: []const u8 = ".";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Capture original working directory before any chdir
    // Store it globally so stdlib can access it
    var original_cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const original_cwd = std.fs.cwd().realpath(".", &original_cwd_buf) catch ".";
    original_invoke_dir = try allocator.dupe(u8, original_cwd);
    defer allocator.free(original_invoke_dir);

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Find and read Zakefile
    const zakefile_content = readZakefile(allocator) catch |err| {
        switch (err) {
            error.FileNotFound => {
                util.printError("Zakefile not found.", .{});
                std.debug.print("\nSearched current directory and up to 5 parent levels for:\n", .{});
                std.debug.print("  - Zakefile\n", .{});
                std.debug.print("  - *.zake files\n", .{});
                std.process.exit(10);
            },
            else => {
                util.printError("Failed to read Zakefile: {s}", .{@errorName(err)});
                std.process.exit(10);
            },
        }
    };
    defer allocator.free(zakefile_content);

    // Parse Zakefile
    var zakefile_parser = Parser.init(allocator);
    defer zakefile_parser.deinit();

    // Set base directory for imports (directory containing the Zakefile)
    zakefile_parser.setBaseDir(".");

    var registry = zakefile_parser.parse(zakefile_content) catch |err| {
        util.printError("Failed to parse Zakefile: {s}", .{@errorName(err)});
        std.process.exit(2);
    };
    defer registry.deinit();

    // If no arguments, show overview help
    if (args.len < 2) {
        try help_mod.printOverview(&registry);
        std.process.exit(0);
    }

    // Check for global --help or -h
    if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
        try help_mod.printOverview(&registry);
        std.process.exit(0);
    }

    // Resolve task name with subcommand support
    // Try joining args with dots: "secrets" "view" -> "secrets.view"
    const resolve_result = resolveTaskName(allocator, &registry, args[1..]) catch |err| {
        util.printError("Failed to resolve task: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    const task = resolve_result.task orelse blk: {
        // Task not found - check if it's a command group
        if (help_mod.isCommandGroup(&registry, args[1])) {
            // Check if user wants help for this group
            if (resolve_result.remaining_args.len > 0) {
                const next_arg = resolve_result.remaining_args[0];
                if (std.mem.eql(u8, next_arg, "--help") or
                    std.mem.eql(u8, next_arg, "-h") or
                    std.mem.eql(u8, next_arg, "help"))
                {
                    try help_mod.printCommandGroupHelp(&registry, args[1]);
                    std.process.exit(0);
                }
            }
            // Show group help by default when no subcommand specified
            try help_mod.printCommandGroupHelp(&registry, args[1]);
            std.process.exit(0);
        }

        util.printError("Command '{s}' not found.", .{args[1]});
        const stderr_file = std.fs.File.stderr();
        var buf: [1024]u8 = undefined;
        var stderr_writer = stderr_file.writer(&buf);
        try stderr_writer.interface.writeAll("\nRun 'zake' to see available commands.\n");
        try stderr_writer.interface.flush();
        std.process.exit(3);
        break :blk undefined;
    };

    const remaining_args = resolve_result.remaining_args;

    // Check for task-specific --help
    if (remaining_args.len > 0) {
        if (std.mem.eql(u8, remaining_args[0], "--help") or std.mem.eql(u8, remaining_args[0], "-h")) {
            try help_mod.printTaskHelp(task, &registry);
            std.process.exit(0);
        }
    }

    // Parse task arguments and flags
    var vars = VarMap.init(allocator);
    defer {
        var iter = vars.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        vars.deinit();
    }

    // Add global vars from Zakefile
    var global_iter = registry.global_vars.iterator();
    while (global_iter.next()) |entry| {
        const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(key_copy);
        const value_copy = try allocator.dupe(u8, entry.value_ptr.*);
        try vars.put(key_copy, value_copy);
    }

    try parseTaskArgs(allocator, task, remaining_args, &vars);

    // Execute the task (with registry for 'run' command support)
    const exit_code = executor_mod.executeTaskWithRegistry(allocator, task, vars, &registry) catch |err| {
        util.printError("Task execution failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    if (exit_code != 0) {
        util.printError("Task '{s}' failed with exit code {d}", .{ task.name, exit_code });
        std.process.exit(exit_code);
    }
}

/// Find and read the Zakefile, searching current directory and up to 5 parent levels
/// Search order in each directory: Zakefile, then *.zake files (alphabetically first wins)
fn readZakefile(allocator: std.mem.Allocator) ![]u8 {
    const result = try findZakefile(allocator);
    defer if (result.path) |p| allocator.free(p);

    if (result.path == null) {
        return error.FileNotFound;
    }

    // Change to the directory containing the Zakefile for relative imports
    if (result.dir) |dir| {
        std.posix.chdir(dir) catch {};
    }

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(result.filename, .{});
    defer file.close();

    const max_size = 10 * 1024 * 1024; // 10 MB max
    return try file.readToEndAlloc(allocator, max_size);
}

/// Result of Zakefile search
const FindResult = struct {
    path: ?[]const u8, // Full path (owned, must be freed)
    dir: ?[]const u8, // Directory containing file (slice of path)
    filename: []const u8, // Just the filename
};

/// Search for Zakefile in current directory and up to 5 parent levels
fn findZakefile(allocator: std.mem.Allocator) !FindResult {
    const max_levels = 5;
    var search_path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Get absolute path of current directory
    const cwd_path = try std.fs.cwd().realpath(".", &search_path_buf);

    var current_path: []const u8 = cwd_path;
    var level: usize = 0;

    while (level <= max_levels) : (level += 1) {
        // Try to open directory
        var dir = std.fs.openDirAbsolute(current_path, .{ .iterate = true }) catch {
            break; // Can't open directory, stop searching
        };
        defer dir.close();

        // First, try "Zakefile"
        if (dir.openFile("Zakefile", .{})) |file| {
            file.close();
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ current_path, "Zakefile" });
            const dir_end = std.mem.lastIndexOf(u8, full_path, "/") orelse 0;
            return FindResult{
                .path = full_path,
                .dir = if (dir_end > 0) full_path[0..dir_end] else null,
                .filename = "Zakefile",
            };
        } else |_| {}

        // Second, try *.zake files (find first alphabetically)
        var first_zake: ?[]const u8 = null;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zake")) {
                if (first_zake == null or std.mem.lessThan(u8, entry.name, first_zake.?)) {
                    if (first_zake) |fz| allocator.free(fz);
                    first_zake = try allocator.dupe(u8, entry.name);
                }
            }
        }

        if (first_zake) |zake_file| {
            const full_path = try std.fs.path.join(allocator, &[_][]const u8{ current_path, zake_file });
            const dir_end = std.mem.lastIndexOf(u8, full_path, "/") orelse 0;
            const filename = try allocator.dupe(u8, zake_file);
            allocator.free(zake_file);
            return FindResult{
                .path = full_path,
                .dir = if (dir_end > 0) full_path[0..dir_end] else null,
                .filename = filename,
            };
        }

        // Move to parent directory
        if (std.fs.path.dirname(current_path)) |parent| {
            current_path = parent;
        } else {
            break; // Reached root
        }
    }

    return FindResult{ .path = null, .dir = null, .filename = "" };
}

/// Result of task name resolution
const ResolveResult = struct {
    task: ?*const task_mod.Task,
    remaining_args: []const [:0]const u8,
};

/// Resolve task name with subcommand support
/// Tries joining CLI args with dots to find a matching task:
///   "secrets" "view" -> tries "secrets.view", then "secrets"
///   "build" -> tries "build"
fn resolveTaskName(
    allocator: std.mem.Allocator,
    registry: *TaskRegistry,
    args: []const [:0]const u8,
) !ResolveResult {
    if (args.len == 0) {
        return ResolveResult{ .task = null, .remaining_args = args };
    }

    // Try progressively longer dot-joined names
    // Start with most specific (all args joined) and work backwards
    var max_parts = @min(args.len, 10); // Limit depth to 10 subcommands

    // Find how many args could be part of the task name (stop at first flag)
    for (args, 0..) |arg, idx| {
        if (arg.len > 0 and arg[0] == '-') {
            max_parts = @min(max_parts, idx);
            break;
        }
    }

    // Try from longest to shortest
    var parts: usize = max_parts;
    while (parts > 0) : (parts -= 1) {
        // Build the task name by joining args[0..parts] with dots
        var name_buf: [512]u8 = undefined;
        var name_len: usize = 0;

        for (args[0..parts], 0..) |arg, i| {
            if (i > 0) {
                name_buf[name_len] = '.';
                name_len += 1;
            }
            if (name_len + arg.len > name_buf.len) {
                return error.TaskNameTooLong;
            }
            @memcpy(name_buf[name_len .. name_len + arg.len], arg);
            name_len += arg.len;
        }

        const task_name = name_buf[0..name_len];

        // Try to find this task
        if (registry.findTask(task_name)) |task| {
            return ResolveResult{
                .task = task,
                .remaining_args = args[parts..],
            };
        }
    }

    // No match found - return null task with original first arg
    _ = allocator;
    return ResolveResult{ .task = null, .remaining_args = args };
}

/// Parse task arguments and flags from command line
fn parseTaskArgs(
    allocator: std.mem.Allocator,
    task: *const task_mod.Task,
    args: []const [:0]const u8,
    vars: *VarMap,
) !void {
    // Initialize flags with default values
    for (task.flags.items) |flag| {
        const key = try allocator.dupe(u8, flag.long_name);
        const value = try allocator.dupe(u8, flag.default_value);
        try vars.put(key, value);
    }

    var arg_index: usize = 0;
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];

        // Check if it's a flag
        if (std.mem.startsWith(u8, arg, "--")) {
            // Long flag (--name=value or --name value)
            const flag_name = if (std.mem.indexOf(u8, arg, "=")) |eq_pos|
                arg[2..eq_pos]
            else
                arg[2..];

            // Find the flag
            var found = false;
            for (task.flags.items) |flag| {
                if (std.mem.eql(u8, flag.long_name, flag_name)) {
                    found = true;

                    // Get the value
                    const value = if (std.mem.indexOf(u8, arg, "=")) |eq_pos|
                        arg[eq_pos + 1 ..]
                    else blk: {
                        i += 1;
                        if (i >= args.len) {
                            util.printError("Flag '--{s}' requires a value", .{flag_name});
                            std.process.exit(4);
                        }
                        break :blk args[i];
                    };

                    // Update the flag value in vars
                    const entry = vars.getPtr(flag.long_name).?;
                    allocator.free(entry.*);
                    entry.* = try allocator.dupe(u8, value);
                    break;
                }
            }

            if (!found) {
                util.printError("Unknown flag '--{s}' for task '{s}'", .{ flag_name, task.name });
                std.process.exit(4);
            }
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // Short flag (-n value or -n=value)
            const short_char = arg[1];

            // Find the flag
            var found = false;
            for (task.flags.items) |flag| {
                if (flag.short_name) |short| {
                    if (short == short_char) {
                        found = true;

                        // Get the value
                        const value = if (arg.len > 2 and arg[2] == '=')
                            arg[3..]
                        else blk: {
                            i += 1;
                            if (i >= args.len) {
                                util.printError("Flag '-{c}' requires a value", .{short_char});
                                std.process.exit(4);
                            }
                            break :blk args[i];
                        };

                        // Update the flag value in vars
                        const entry = vars.getPtr(flag.long_name).?;
                        allocator.free(entry.*);
                        entry.* = try allocator.dupe(u8, value);
                        break;
                    }
                }
            }

            if (!found) {
                util.printError("Unknown flag '-{c}' for task '{s}'", .{ short_char, task.name });
                std.process.exit(4);
            }
        } else {
            // Positional argument
            if (arg_index >= task.arguments.items.len) {
                util.printError("Too many arguments for task '{s}'", .{task.name});
                std.process.exit(4);
            }

            const task_arg = task.arguments.items[arg_index];
            const key = try allocator.dupe(u8, task_arg.name);
            const value = try allocator.dupe(u8, arg);
            try vars.put(key, value);
            arg_index += 1;
        }

        i += 1;
    }

    // Check if all required arguments were provided
    for (task.arguments.items, 0..) |task_arg, idx| {
        if (!task_arg.is_optional and idx >= arg_index) {
            util.printError("Missing required argument '<{s}>' for task '{s}'", .{ task_arg.name, task.name });
            const stderr_file = std.fs.File.stderr();
            var buf: [1024]u8 = undefined;
            var stderr_writer = stderr_file.writer(&buf);
            try stderr_writer.interface.writeAll("\nRun 'zake ");
            try stderr_writer.interface.writeAll(task.name);
            try stderr_writer.interface.writeAll(" --help' for usage information.\n");
            try stderr_writer.interface.flush();
            std.process.exit(4);
        }
    }

    // Set empty string for optional arguments that weren't provided
    for (task.arguments.items, 0..) |task_arg, idx| {
        if (task_arg.is_optional and idx >= arg_index) {
            const key = try allocator.dupe(u8, task_arg.name);
            const value = try allocator.dupe(u8, "");
            try vars.put(key, value);
        }
    }
}
