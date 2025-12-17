const std = @import("std");
const parser_mod = @import("parser.zig");
const executor_mod = @import("executor.zig");
const help_mod = @import("help.zig");
const task_mod = @import("task.zig");
const util = @import("util.zig");

const Parser = parser_mod.Parser;
const TaskRegistry = task_mod.TaskRegistry;
const VarMap = executor_mod.VarMap;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Get command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Find and read Zakefile
    const zakefile_content = readZakefile(allocator) catch |err| {
        switch (err) {
            error.FileNotFound => {
                util.printError("Zakefile not found in current directory.", .{});
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

    // Get task name
    const task_name = args[1];

    // Check for global --help or -h
    if (std.mem.eql(u8, task_name, "--help") or std.mem.eql(u8, task_name, "-h")) {
        try help_mod.printOverview(&registry);
        std.process.exit(0);
    }

    // Find the task
    const task = registry.findTask(task_name) orelse {
        util.printError("Task '{s}' not found.", .{task_name});
        const stderr_file = std.fs.File.stderr();
        var buf: [1024]u8 = undefined;
        var stderr_writer = stderr_file.writer(&buf);
        try stderr_writer.interface.writeAll("\nRun 'zake' to see available tasks.\n");
        try stderr_writer.interface.flush();
        std.process.exit(3);
    };

    // Check for task-specific --help
    if (args.len > 2) {
        if (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h")) {
            try help_mod.printTaskHelp(task);
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

    try parseTaskArgs(allocator, task, args[2..], &vars);

    // Execute the task
    const exit_code = executor_mod.executeTask(allocator, task, vars) catch |err| {
        util.printError("Task execution failed: {s}", .{@errorName(err)});
        std.process.exit(1);
    };

    if (exit_code != 0) {
        util.printError("Task '{s}' failed with exit code {d}", .{ task_name, exit_code });
        std.process.exit(exit_code);
    }
}

/// Read the Zakefile from the current directory
fn readZakefile(allocator: std.mem.Allocator) ![]u8 {
    const cwd = std.fs.cwd();
    const file = try cwd.openFile("Zakefile", .{});
    defer file.close();

    const max_size = 10 * 1024 * 1024; // 10 MB max
    return try file.readToEndAlloc(allocator, max_size);
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
