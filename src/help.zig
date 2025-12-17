const std = @import("std");
const task_mod = @import("task.zig");
const util = @import("util.zig");
const Task = task_mod.Task;
const TaskRegistry = task_mod.TaskRegistry;
const TargetOS = task_mod.TargetOS;

/// Print overview help (list all tasks)
/// Deduplicates tasks by name, showing only unique task names
pub fn printOverview(registry: *const TaskRegistry) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var stdout_writer = stdout_file.writer(&buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("USAGE:\n");
    try stdout.writeAll(util.Color.Reset);
    try stdout.writeAll("  zake <task> [ARGUMENTS...] [FLAGS...]\n\n");

    try stdout.writeAll(util.Color.Bold);
    try stdout.writeAll("AVAILABLE TASKS:\n");
    try stdout.writeAll(util.Color.Reset);

    if (registry.tasks.items.len == 0) {
        try stdout.writeAll("  (no tasks defined)\n");
        try stdout_writer.interface.flush();
        return;
    }

    // Track seen task names to avoid duplicates
    var seen = std.StringHashMap(*const Task).init(std.heap.page_allocator);
    defer seen.deinit();

    // First pass: collect unique task names and find best description
    // (prefer the task variant that matches current OS, or any)
    for (registry.tasks.items) |*t| {
        const existing = seen.get(t.name);
        if (existing == null) {
            try seen.put(t.name, t);
        } else {
            // If we find a variant that matches current OS better, use it
            // Priority: exact OS match > current entry
            const current_task = existing.?;
            if (current_task.target_os == .any and t.target_os != .any) {
                // Keep the platform-specific description if it exists
                if (t.description != null) {
                    try seen.put(t.name, t);
                }
            }
        }
    }

    // Find the longest task name for alignment
    var max_name_len: usize = 0;
    var iter = seen.iterator();
    while (iter.next()) |entry| {
        if (entry.key_ptr.len > max_name_len) {
            max_name_len = entry.key_ptr.len;
        }
    }

    // Collect task names for sorting
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.heap.page_allocator);

    var iter2 = seen.iterator();
    while (iter2.next()) |entry| {
        try names.append(std.heap.page_allocator, entry.key_ptr.*);
    }

    // Sort alphabetically
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // Print each unique task
    for (names.items) |name| {
        const task_ptr = seen.get(name).?;

        try stdout.writeAll("  ");
        try stdout.writeAll(util.Color.Cyan);
        try stdout.writeAll(name);
        try stdout.writeAll(util.Color.Reset);

        // Add padding
        const padding = max_name_len - name.len + 4;
        var i: usize = 0;
        while (i < padding) : (i += 1) {
            try stdout.writeByte(' ');
        }

        // Print description
        if (task_ptr.description) |desc| {
            try stdout.writeAll(desc);
        }

        // If task has arch variants, show indicator
        if (hasArchVariants(registry, name)) {
            try stdout.writeAll(util.Color.Gray);
            try stdout.writeAll(" [multi-arch]");
            try stdout.writeAll(util.Color.Reset);
        }

        try stdout.writeByte('\n');
    }

    try stdout.writeAll("\n");
    try stdout.writeAll("Run 'zake <task> --help' for task-specific help.\n");
    try stdout_writer.interface.flush();
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
pub fn printTaskHelp(task: *const Task) !void {
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
    try stdout.writeAll(task.name);
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
    }

    try stdout_writer.interface.flush();
}
