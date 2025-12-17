const std = @import("std");
const task_mod = @import("task.zig");
const util = @import("util.zig");
const Task = task_mod.Task;
const TaskRegistry = task_mod.TaskRegistry;
const TargetOS = task_mod.TargetOS;

/// Command or command group for help display
const CommandEntry = struct {
    name: []const u8,
    description: ?[]const u8,
    is_group: bool, // true if this is a group with subcommands
    has_arch_variants: bool,
};

/// Print overview help (list all commands and command groups)
/// Groups tasks by prefix: secrets.init, secrets.view -> "secrets" group
pub fn printOverview(registry: *const TaskRegistry) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("USAGE:\n");
    try stdout.writeAll(util.Color.Reset);
    try stdout.writeAll("  zake <command> [ARGUMENTS...] [FLAGS...]\n\n");

    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("AVAILABLE COMMANDS:\n");
    try stdout.writeAll(util.Color.Reset);

    if (registry.tasks.items.len == 0) {
        try stdout.writeAll("  (no commands defined)\n");
        try stdout_writer.interface.flush();
        return;
    }

    // Build command entries (groups and standalone tasks)
    var commands = std.StringHashMap(CommandEntry).init(std.heap.page_allocator);
    defer commands.deinit();

    for (registry.tasks.items) |*t| {
        // Check if task name contains a dot (is a subcommand)
        if (std.mem.indexOf(u8, t.name, ".")) |dot_pos| {
            // Extract the group prefix (e.g., "secrets" from "secrets.view")
            const group_name = t.name[0..dot_pos];

            const existing = commands.get(group_name);
            if (existing == null) {
                // Create group entry - description is the group name + " commands"
                try commands.put(group_name, CommandEntry{
                    .name = group_name,
                    .description = null, // Will show subcommand count
                    .is_group = true,
                    .has_arch_variants = false,
                });
            }
        } else {
            // Standalone task (no dot)
            const existing = commands.get(t.name);
            if (existing == null) {
                try commands.put(t.name, CommandEntry{
                    .name = t.name,
                    .description = t.description,
                    .is_group = false,
                    .has_arch_variants = hasArchVariants(registry, t.name),
                });
            } else if (existing.?.is_group) {
                // There's both a group and a standalone task with same name
                // Mark it as a group that also has a direct command
                var entry = existing.?;
                entry.description = t.description;
                try commands.put(t.name, entry);
            }
        }
    }

    // Find longest name for alignment
    var max_name_len: usize = 0;
    var iter = commands.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.len > max_name_len) {
            max_name_len = entry.key_ptr.len;
        }
    }

    // Collect and sort command names
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.heap.page_allocator);

    var iter2 = commands.iterator();
    while (iter2.next()) |entry| {
        try names.append(std.heap.page_allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Print each command/group
    for (names.items) |name| {
        const cmd = commands.get(name).?;

        try stdout.writeAll("  ");
        try stdout.writeAll(util.Color.Cyan);
        try stdout.writeAll(name);
        try stdout.writeAll(util.Color.Reset);

        // Padding
        const padding = max_name_len - name.len + 4;
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try stdout.writeByte(' ');
        }

        // Description or group indicator
        if (cmd.is_group) {
            // Count subcommands in this group
            const subcount = countSubcommands(registry, name);
            if (cmd.description) |desc| {
                try stdout.writeAll(desc);
                try stdout.writeAll(util.Color.Gray);
                try stdout.print(" (+{d} subcommands)", .{subcount});
                try stdout.writeAll(util.Color.Reset);
            } else {
                try stdout.writeAll(util.Color.Gray);
                try stdout.print("{d} subcommands", .{subcount});
                try stdout.writeAll(util.Color.Reset);
            }
        } else {
            if (cmd.description) |desc| {
                try stdout.writeAll(desc);
            }
            if (cmd.has_arch_variants) {
                try stdout.writeAll(util.Color.Gray);
                try stdout.writeAll(" [multi-arch]");
                try stdout.writeAll(util.Color.Reset);
            }
        }

        try stdout.writeByte('\n');
    }

    try stdout.writeAll("\n");
    try stdout.writeAll("Run 'zake <command> --help' for more information.\n");
    try stdout_writer.interface.flush();
}

/// Count subcommands for a group prefix
fn countSubcommands(registry: *const TaskRegistry, prefix: []const u8) usize {
    var seen = std.StringHashMap(void).init(std.heap.page_allocator);
    defer seen.deinit();

    for (registry.tasks.items) |t| {
        if (std.mem.startsWith(u8, t.name, prefix) and
            t.name.len > prefix.len and
            t.name[prefix.len] == '.')
        {
            // Extract the subcommand name (first part after prefix)
            const rest = t.name[prefix.len + 1 ..];
            const subname = if (std.mem.indexOf(u8, rest, ".")) |dot|
                rest[0..dot]
            else
                rest;

            seen.put(subname, {}) catch {};
        }
    }
    return seen.count();
}

/// Print help for a command group (shows subcommands)
pub fn printCommandGroupHelp(registry: *const TaskRegistry, group_name: []const u8) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buf);
    const stdout = &stdout_writer.interface;

    // Check if there's a direct task with this name
    var direct_task: ?*const Task = null;
    for (registry.tasks.items) |*t| {
        if (std.mem.eql(u8, t.name, group_name)) {
            direct_task = t;
            break;
        }
    }

    // Print group description if available
    if (direct_task) |dt| {
        if (dt.description) |desc| {
            try stdout.writeAll(desc);
            try stdout.writeAll("\n\n");
        }
    }

    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("USAGE:\n");
    try stdout.writeAll(util.Color.Reset);
    try stdout.writeAll("  zake ");
    try stdout.writeAll(group_name);
    try stdout.writeAll(" <command> [ARGUMENTS...] [FLAGS...]\n\n");

    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("AVAILABLE COMMANDS:\n");
    try stdout.writeAll(util.Color.Reset);

    // Collect subcommands
    var subcommands = std.StringHashMap(*const Task).init(std.heap.page_allocator);
    defer subcommands.deinit();

    const prefix_with_dot_len = group_name.len + 1;

    for (registry.tasks.items) |*t| {
        if (std.mem.startsWith(u8, t.name, group_name) and
            t.name.len > group_name.len and
            t.name[group_name.len] == '.')
        {
            // Extract subcommand name (e.g., "view" from "secrets.view")
            const subname = t.name[prefix_with_dot_len..];

            // Only show immediate subcommands (no further dots)
            if (std.mem.indexOf(u8, subname, ".") == null) {
                if (subcommands.get(subname) == null) {
                    try subcommands.put(subname, t);
                }
            }
        }
    }

    // Find longest subcommand name
    var max_len: usize = 0;
    var iter = subcommands.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.len > max_len) {
            max_len = entry.key_ptr.len;
        }
    }

    // Collect and sort
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.heap.page_allocator);

    var iter2 = subcommands.iterator();
    while (iter2.next()) |entry| {
        try names.append(std.heap.page_allocator, entry.key_ptr.*);
    }

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Print subcommands
    for (names.items) |name| {
        const task = subcommands.get(name).?;

        try stdout.writeAll("  ");
        try stdout.writeAll(util.Color.Cyan);
        try stdout.writeAll(name);
        try stdout.writeAll(util.Color.Reset);

        // Padding
        const padding = max_len - name.len + 4;
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try stdout.writeByte(' ');
        }

        if (task.description) |desc| {
            try stdout.writeAll(desc);
        }

        try stdout.writeByte('\n');
    }

    try stdout.writeAll("\n");
    try stdout.print("Run 'zake {s} <command> --help' for command-specific help.\n", .{group_name});
    try stdout_writer.interface.flush();
}

/// Check if a name is a command group (has subcommands)
pub fn isCommandGroup(registry: *const TaskRegistry, name: []const u8) bool {
    for (registry.tasks.items) |t| {
        if (std.mem.startsWith(u8, t.name, name) and
            t.name.len > name.len and
            t.name[name.len] == '.')
        {
            return true;
        }
    }
    return false;
}

/// Check if a task has multiple arch variants
fn hasArchVariants(registry: *const TaskRegistry, name: []const u8) bool {
    var count: usize = 0;
    for (registry.tasks.items) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            count += 1;
            if (count > 1) return true;
        }
    }
    return false;
}

/// Print help for a specific task
/// If registry is provided, also shows subcommands if this task is a group
pub fn printTaskHelp(task: *const Task, registry: ?*const TaskRegistry) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buf);
    const stdout = &stdout_writer.interface;

    // Print description
    if (task.description) |desc| {
        try stdout.writeAll(desc);
        try stdout.writeAll("\n\n");
    }

    // Print usage
    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("USAGE:\n");
    try stdout.writeAll(util.Color.Reset);
    try stdout.writeAll("  zake ");
    try stdout.writeAll(util.Color.Cyan);
    // Replace dots with spaces for display (secrets.view -> secrets view)
    for (task.name) |c| {
        if (c == '.') {
            try stdout.writeByte(' ');
        } else {
            try stdout.writeByte(c);
        }
    }
    try stdout.writeAll(util.Color.Reset);

    // Print flags placeholder if any
    if (task.flags.items.len > 0) {
        try stdout.writeAll(" [FLAGS]");
    }

    // Print arguments
    for (task.arguments.items) |arg| {
        try stdout.writeByte(' ');
        if (arg.is_optional) {
            try stdout.print("[{s}]", .{arg.name});
        } else {
            try stdout.print("<{s}>", .{arg.name});
        }
    }

    try stdout.writeAll("\n\n");

    // Print arguments section if any
    if (task.arguments.items.len > 0) {
        try stdout.writeAll(util.Color.Bold);
        try stdout.writeAll("ARGUMENTS:\n");
        try stdout.writeAll(util.Color.Reset);

        for (task.arguments.items) |arg| {
            try stdout.writeAll("  ");
            if (arg.is_optional) {
                try stdout.print("[{s}]", .{arg.name});
            } else {
                try stdout.print("<{s}>", .{arg.name});
            }

            // Type
            try stdout.writeAll(" [string]");

            // Padding
            const padding = 20 - arg.name.len;
            var i: usize = 0;
            while (i < padding) : (i += 1) {
                try stdout.writeByte(' ');
            }

            // Description
            if (arg.description) |desc| {
                try stdout.writeAll(desc);
            }
            try stdout.writeByte('\n');
        }

        try stdout.writeByte('\n');
    }

    // Print flags section if any
    if (task.flags.items.len > 0) {
        try stdout.writeAll(util.Color.Bold);
        try stdout.writeAll("FLAGS:\n");
        try stdout.writeAll(util.Color.Reset);

        for (task.flags.items) |flag| {
            try stdout.writeAll("  ");

            // Short name
            if (flag.short_name) |short| {
                try stdout.print("-{c}, ", .{short});
            } else {
                try stdout.writeAll("    ");
            }

            // Long name
            try stdout.print("--{s} [string]", .{flag.long_name});

            // Padding (approximate)
            const name_len = flag.long_name.len + 10;
            if (name_len < 25) {
                const padding = 25 - name_len;
                var i: usize = 0;
                while (i < padding) : (i += 1) {
                    try stdout.writeByte(' ');
                }
            }

            // Description
            if (flag.description) |desc| {
                try stdout.writeAll(desc);
            }

            // Default value
            try stdout.writeAll(util.Color.Gray);
            try stdout.print(" (default: \"{s}\")", .{flag.default_value});
            try stdout.writeAll(util.Color.Reset);

            try stdout.writeByte('\n');
        }

        try stdout.writeByte('\n');
    }

    // Show subcommands if this task is also a group
    if (registry) |reg| {
        if (isCommandGroup(reg, task.name)) {
            try stdout.writeAll(util.Color.Bold);
            try stdout.writeAll("SUBCOMMANDS:\n");
            try stdout.writeAll(util.Color.Reset);

            // Collect subcommands
            var subcommands = std.StringHashMap(*const Task).init(std.heap.page_allocator);
            defer subcommands.deinit();

            const prefix_with_dot_len = task.name.len + 1;

            for (reg.tasks.items) |*t| {
                if (std.mem.startsWith(u8, t.name, task.name) and
                    t.name.len > task.name.len and
                    t.name[task.name.len] == '.')
                {
                    const subname = t.name[prefix_with_dot_len..];
                    if (std.mem.indexOf(u8, subname, ".") == null) {
                        if (subcommands.get(subname) == null) {
                            try subcommands.put(subname, t);
                        }
                    }
                }
            }

            // Find longest name
            var max_len: usize = 0;
            var iter = subcommands.iterator();
            while (iter.next()) |entry| {
                if (entry.key_ptr.len > max_len) {
                    max_len = entry.key_ptr.len;
                }
            }

            // Collect and sort
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(std.heap.page_allocator);

            var iter2 = subcommands.iterator();
            while (iter2.next()) |entry| {
                try names.append(std.heap.page_allocator, entry.key_ptr.*);
            }

            std.mem.sort([]const u8, names.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lessThan);

            for (names.items) |name| {
                const sub_task = subcommands.get(name).?;
                try stdout.writeAll("  ");
                try stdout.writeAll(util.Color.Cyan);
                try stdout.writeAll(name);
                try stdout.writeAll(util.Color.Reset);

                const padding = max_len - name.len + 4;
                var i: usize = 0;
                while (i < padding) : (i += 1) {
                    try stdout.writeByte(' ');
                }

                if (sub_task.description) |desc| {
                    try stdout.writeAll(desc);
                }
                try stdout.writeByte('\n');
            }
        }
    }

    try stdout_writer.interface.flush();
}
