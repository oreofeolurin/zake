const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

/// Represents a when: condition expression
pub const Condition = struct {
    expression: []const u8, // The raw expression to evaluate

    pub fn deinit(self: *Condition, allocator: Allocator) void {
        allocator.free(self.expression);
    }
};

/// Represents a single task defined in the Zakefile
pub const Task = struct {
    name: []const u8,
    description: ?[]const u8,
    arguments: ArrayList(Argument),
    flags: ArrayList(Flag),
    script_lines: ArrayList(ScriptLine),
    requires: ArrayList([]const u8), // Task dependencies
    aliases: ArrayList([]const u8), // Alternative task names
    condition: ?Condition, // Optional when: condition
    target_os: TargetOS, // Which OS this task runs on
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) !Task {
        return Task{
            .name = try allocator.dupe(u8, name),
            .description = null,
            .arguments = .empty,
            .flags = .empty,
            .script_lines = .empty,
            .requires = .empty,
            .aliases = .empty,
            .condition = null,
            .target_os = .any, // Default: runs on all platforms
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Task) void {
        self.allocator.free(self.name);
        if (self.description) |desc| {
            self.allocator.free(desc);
        }

        for (self.arguments.items) |*arg| {
            arg.deinit(self.allocator);
        }
        self.arguments.deinit(self.allocator);

        for (self.flags.items) |*flag| {
            flag.deinit(self.allocator);
        }
        self.flags.deinit(self.allocator);

        for (self.script_lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.script_lines.deinit(self.allocator);

        for (self.requires.items) |req| {
            self.allocator.free(req);
        }
        self.requires.deinit(self.allocator);

        for (self.aliases.items) |alias| {
            self.allocator.free(alias);
        }
        self.aliases.deinit(self.allocator);

        if (self.condition) |*cond| {
            var c = cond.*;
            c.deinit(self.allocator);
        }
    }

    pub fn setDescription(self: *Task, desc: []const u8) !void {
        if (self.description) |old_desc| {
            self.allocator.free(old_desc);
        }
        self.description = try self.allocator.dupe(u8, desc);
    }

    pub fn setTargetOS(self: *Task, os: TargetOS) void {
        self.target_os = os;
    }

    pub fn addArgument(self: *Task, arg: Argument) !void {
        try self.arguments.append(self.allocator, arg);
    }

    pub fn addFlag(self: *Task, flag: Flag) !void {
        try self.flags.append(self.allocator, flag);
    }

    pub fn addScriptLine(self: *Task, line: ScriptLine) !void {
        try self.script_lines.append(self.allocator, line);
    }

    pub fn addRequires(self: *Task, task_name: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, task_name);
        try self.requires.append(self.allocator, name_copy);
    }

    pub fn addAlias(self: *Task, alias_name: []const u8) !void {
        const alias_copy = try self.allocator.dupe(u8, alias_name);
        try self.aliases.append(self.allocator, alias_copy);
    }

    pub fn setCondition(self: *Task, expression: []const u8) !void {
        if (self.condition) |*old| {
            var c = old.*;
            c.deinit(self.allocator);
        }
        self.condition = Condition{
            .expression = try self.allocator.dupe(u8, expression),
        };
    }
};

/// Represents a positional argument for a task
pub const Argument = struct {
    name: []const u8,
    arg_type: ArgType,
    is_optional: bool,
    description: ?[]const u8,

    pub fn init(allocator: Allocator, name: []const u8, arg_type: ArgType, is_optional: bool, description: ?[]const u8) !Argument {
        return Argument{
            .name = try allocator.dupe(u8, name),
            .arg_type = arg_type,
            .is_optional = is_optional,
            .description = if (description) |desc| try allocator.dupe(u8, desc) else null,
        };
    }

    pub fn deinit(self: *Argument, allocator: Allocator) void {
        allocator.free(self.name);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};

/// Argument/Flag type (currently only string)
pub const ArgType = enum {
    string,
    // Future: int, bool, path
};

/// Represents an optional named flag for a task
pub const Flag = struct {
    long_name: []const u8,
    short_name: ?u8, // Single character, e.g., 'e' for -e
    flag_type: ArgType,
    default_value: []const u8,
    description: ?[]const u8,

    pub fn init(
        allocator: Allocator,
        long_name: []const u8,
        short_name: ?u8,
        flag_type: ArgType,
        default_value: []const u8,
        description: ?[]const u8,
    ) !Flag {
        return Flag{
            .long_name = try allocator.dupe(u8, long_name),
            .short_name = short_name,
            .flag_type = flag_type,
            .default_value = try allocator.dupe(u8, default_value),
            .description = if (description) |desc| try allocator.dupe(u8, desc) else null,
        };
    }

    pub fn deinit(self: *Flag, allocator: Allocator) void {
        allocator.free(self.long_name);
        allocator.free(self.default_value);
        if (self.description) |desc| {
            allocator.free(desc);
        }
    }
};

/// Target operating system for conditional execution
/// Used with arch: directive for platform-specific task overloads
pub const TargetOS = enum {
    any, // Run on all platforms (default)
    linux, // Linux only
    windows, // Windows only
    macos, // macOS only
    darwin, // Alias for macos
    unix, // Linux, macOS, FreeBSD, etc. (anything non-Windows)

    /// Parse a string into a TargetOS
    pub fn fromString(str: []const u8) ?TargetOS {
        const lower = str; // Assuming already lowercase
        if (std.mem.eql(u8, lower, "linux")) return .linux;
        if (std.mem.eql(u8, lower, "windows")) return .windows;
        if (std.mem.eql(u8, lower, "macos")) return .macos;
        if (std.mem.eql(u8, lower, "darwin")) return .darwin;
        if (std.mem.eql(u8, lower, "unix")) return .unix;
        if (std.mem.eql(u8, lower, "any")) return .any;
        if (std.mem.eql(u8, lower, "default")) return .any;
        return null;
    }

    /// Convert to display string
    pub fn toString(self: TargetOS) []const u8 {
        return switch (self) {
            .any => "any",
            .linux => "linux",
            .windows => "windows",
            .macos => "macos",
            .darwin => "darwin",
            .unix => "unix",
        };
    }
};

/// Represents a single line in a task's script block
pub const ScriptLine = struct {
    content: []const u8,
    is_silent: bool, // true if prefixed with @
    ignore_error: bool, // true if prefixed with ?

    pub fn init(allocator: Allocator, content: []const u8, is_silent: bool, ignore_error: bool) !ScriptLine {
        return ScriptLine{
            .content = try allocator.dupe(u8, content),
            .is_silent = is_silent,
            .ignore_error = ignore_error,
        };
    }

    pub fn deinit(self: *ScriptLine, allocator: Allocator) void {
        allocator.free(self.content);
    }
};

/// Registry of all tasks parsed from the Zakefile
pub const TaskRegistry = struct {
    tasks: ArrayList(Task),
    global_vars: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TaskRegistry {
        return TaskRegistry{
            .tasks = .empty,
            .global_vars = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TaskRegistry) void {
        for (self.tasks.items) |*task| {
            task.deinit();
        }
        self.tasks.deinit(self.allocator);

        // Free global vars
        var iter = self.global_vars.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.global_vars.deinit();
    }

    pub fn addTask(self: *TaskRegistry, task_to_add: Task) !void {
        try self.tasks.append(self.allocator, task_to_add);
    }

    pub fn addGlobalVar(self: *TaskRegistry, name: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.global_vars.put(key_copy, value_copy);
    }

    /// Find a task by name or alias. If multiple tasks with the same name exist
    /// (due to arch: overloads), returns the best match for the current OS:
    /// 1. Exact OS match (e.g., arch:macos on macOS)
    /// 2. Category match (e.g., arch:unix on macOS)
    /// 3. Fallback to arch:any (no arch directive)
    pub fn findTask(self: *TaskRegistry, name: []const u8) ?*Task {
        const builtin = @import("builtin");
        const current_os = builtin.os.tag;

        var exact_match: ?*Task = null;
        var unix_match: ?*Task = null;
        var any_match: ?*Task = null;

        for (self.tasks.items) |*t| {
            const name_matches = std.mem.eql(u8, t.name, name) or blk: {
                // Check aliases
                for (t.aliases.items) |alias| {
                    if (std.mem.eql(u8, alias, name)) break :blk true;
                }
                break :blk false;
            };

            if (name_matches) {
                switch (t.target_os) {
                    .any => any_match = t,
                    .linux => if (current_os == .linux) {
                        exact_match = t;
                    },
                    .windows => if (current_os == .windows) {
                        exact_match = t;
                    },
                    .macos, .darwin => if (current_os == .macos) {
                        exact_match = t;
                    },
                    .unix => if (current_os != .windows) {
                        unix_match = t;
                    },
                }
            }
        }

        // Priority: exact > unix > any
        return exact_match orelse unix_match orelse any_match;
    }

    /// Find a task by name or alias (const version)
    pub fn findTaskConst(self: *const TaskRegistry, name: []const u8) ?*const Task {
        const builtin = @import("builtin");
        const current_os = builtin.os.tag;

        var exact_match: ?*const Task = null;
        var unix_match: ?*const Task = null;
        var any_match: ?*const Task = null;

        for (self.tasks.items) |*t| {
            const name_matches = std.mem.eql(u8, t.name, name) or blk: {
                // Check aliases
                for (t.aliases.items) |alias| {
                    if (std.mem.eql(u8, alias, name)) break :blk true;
                }
                break :blk false;
            };

            if (name_matches) {
                switch (t.target_os) {
                    .any => any_match = t,
                    .linux => if (current_os == .linux) {
                        exact_match = t;
                    },
                    .windows => if (current_os == .windows) {
                        exact_match = t;
                    },
                    .macos, .darwin => if (current_os == .macos) {
                        exact_match = t;
                    },
                    .unix => if (current_os != .windows) {
                        unix_match = t;
                    },
                }
            }
        }

        return exact_match orelse unix_match orelse any_match;
    }

    /// Get all unique task names (for help display)
    /// Deduplicates names that have arch: overloads
    pub fn getUniqueTaskNames(self: *TaskRegistry, allocator: Allocator) ![][]const u8 {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        var names: ArrayList([]const u8) = .empty;
        errdefer names.deinit(allocator);

        for (self.tasks.items) |t| {
            if (!seen.contains(t.name)) {
                try seen.put(t.name, {});
                try names.append(allocator, t.name);
            }
        }

        return names.toOwnedSlice(allocator);
    }
};
