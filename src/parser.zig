const std = @import("std");
const task = @import("task.zig");
const Task = task.Task;
const Argument = task.Argument;
const Flag = task.Flag;
const ScriptLine = task.ScriptLine;
const ArgType = task.ArgType;
const TargetOS = task.TargetOS;
const TaskRegistry = task.TaskRegistry;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

/// Parser state machine
const ParserState = enum {
    TopLevel, // Outside any task
    InTaskDefinition, // Inside task, before script:
    InScript, // Inside script: block
};

/// Parser for Zakefile
pub const Parser = struct {
    allocator: Allocator,
    registry: TaskRegistry,
    current_task: ?*Task,
    state: ParserState,
    pending_description: ?[]const u8,
    line_number: usize,

    pub fn init(allocator: Allocator) Parser {
        return Parser{
            .allocator = allocator,
            .registry = TaskRegistry.init(allocator),
            .current_task = null,
            .state = .TopLevel,
            .pending_description = null,
            .line_number = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        if (self.pending_description) |desc| {
            self.allocator.free(desc);
        }
        self.registry.deinit();
    }

    /// Parse the entire Zakefile content
    pub fn parse(self: *Parser, content: []const u8) !TaskRegistry {
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            self.line_number += 1;
            try self.parseLine(line);
        }

        // Transfer ownership of registry
        const result = self.registry;
        self.registry = TaskRegistry.init(self.allocator);
        return result;
    }

    /// Parse a single line
    fn parseLine(self: *Parser, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Skip empty lines
        if (trimmed.len == 0) {
            return;
        }

        // Handle comments
        if (trimmed[0] == '#') {
            // Check if it's a description comment (##)
            if (trimmed.len > 1 and trimmed[1] == '#') {
                try self.handleDescriptionComment(trimmed);
            }
            return;
        }

        // Check for Makefile-style variable assignment at top level (not indented)
        // Formats: VAR = value, VAR := value, VAR ?= value
        if (!isIndented(line) and self.current_task == null) {
            if (try self.tryParseMakefileVar(trimmed)) {
                return;
            }
        }

        // Check if this is a task definition (ends with : and not indented)
        if (!isIndented(line) and std.mem.endsWith(u8, trimmed, ":")) {
            // Make sure it's not a variable assignment (has = before :)
            const eq_pos = std.mem.indexOf(u8, trimmed, "=");
            const colon_pos = std.mem.indexOf(u8, trimmed, ":");
            if (eq_pos == null or (colon_pos != null and colon_pos.? < eq_pos.?)) {
                try self.startNewTask(trimmed);
                return;
            }
        }

        // Must be inside a task for anything else
        if (self.current_task == null) {
            std.debug.print("Error at line {d}: Content outside of any task\n", .{self.line_number});
            return error.ContentOutsideTask;
        }

        // Parse task body based on current state
        if (std.mem.startsWith(u8, trimmed, "arg:")) {
            try self.parseArgument(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "flag:")) {
            try self.parseFlag(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "arch:")) {
            try self.parseArch(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "script:")) {
            self.state = .InScript;
        } else if (self.state == .InScript) {
            try self.parseScriptLine(trimmed);
        } else {
            // Unknown directive in definition zone
            std.debug.print("Error at line {d}: Unknown directive: {s}\n", .{ self.line_number, trimmed });
            return error.UnknownDirective;
        }
    }

    /// Try to parse Makefile-style variable assignment
    /// Returns true if line was a variable assignment, false otherwise
    fn tryParseMakefileVar(self: *Parser, line: []const u8) !bool {
        // Look for assignment operators: ?=, :=, =
        var op_pos: ?usize = null;
        var op_len: usize = 1;
        var is_conditional: bool = false;

        // Check for ?= first
        if (std.mem.indexOf(u8, line, "?=")) |pos| {
            op_pos = pos;
            op_len = 2;
            is_conditional = true;
        }
        // Check for :=
        else if (std.mem.indexOf(u8, line, ":=")) |pos| {
            op_pos = pos;
            op_len = 2;
        }
        // Check for simple =
        else if (std.mem.indexOf(u8, line, "=")) |pos| {
            // Make sure it's not part of another operator
            if (pos > 0 and (line[pos - 1] == '?' or line[pos - 1] == ':' or line[pos - 1] == '!')) {
                return false;
            }
            op_pos = pos;
            op_len = 1;
        }

        if (op_pos == null) {
            return false;
        }

        const pos = op_pos.?;

        // Extract variable name (must be valid identifier)
        const var_name = std.mem.trim(u8, line[0..pos], " \t");
        if (var_name.len == 0) {
            return false;
        }

        // Check if var_name looks like an identifier (letters, digits, underscore)
        for (var_name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_') {
                return false; // Not a variable assignment
            }
        }

        // Extract value
        const value = std.mem.trim(u8, line[pos + op_len ..], " \t");

        // Process $(VAR) references in the value
        const processed_value = try self.expandMakefileVars(value);
        defer if (processed_value.ptr != value.ptr) self.allocator.free(processed_value);

        // For conditional assignment, only set if not already defined
        if (is_conditional) {
            if (self.registry.global_vars.get(var_name) != null) {
                return true; // Already defined, skip
            }
        }

        try self.registry.addGlobalVar(var_name, processed_value);
        return true;
    }

    /// Expand $(VAR) references in a value using already-defined global vars
    fn expandMakefileVars(self: *Parser, value: []const u8) ![]const u8 {
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(self.allocator);

        var i: usize = 0;
        var has_substitutions = false;

        while (i < value.len) {
            // Check for $(VAR)
            if (i + 2 < value.len and value[i] == '$' and value[i + 1] == '(') {
                const close_pos = std.mem.indexOf(u8, value[i + 2 ..], ")") orelse {
                    // No closing paren, treat as literal
                    try result.append(self.allocator, value[i]);
                    i += 1;
                    continue;
                };

                const var_ref = value[i + 2 .. i + 2 + close_pos];
                has_substitutions = true;

                // Look up in global vars
                if (self.registry.global_vars.get(var_ref)) |var_value| {
                    try result.appendSlice(self.allocator, var_value);
                } else {
                    // Check environment variable as fallback
                    var env_name_buf: [256]u8 = undefined;
                    if (var_ref.len < 256) {
                        @memcpy(env_name_buf[0..var_ref.len], var_ref);
                        env_name_buf[var_ref.len] = 0;
                        if (std.posix.getenv(env_name_buf[0..var_ref.len :0])) |env_val| {
                            try result.appendSlice(self.allocator, env_val);
                        }
                        // If not found, leave empty (like Make)
                    }
                }

                i = i + 2 + close_pos + 1;
                continue;
            }

            try result.append(self.allocator, value[i]);
            i += 1;
        }

        if (has_substitutions) {
            return result.toOwnedSlice(self.allocator);
        } else {
            result.deinit(self.allocator);
            return value;
        }
    }

    /// Handle description comment (##)
    fn handleDescriptionComment(self: *Parser, line: []const u8) !void {
        // Remove ## and trim
        const desc = std.mem.trim(u8, line[2..], " \t");
        if (self.pending_description) |old_desc| {
            self.allocator.free(old_desc);
        }
        self.pending_description = try self.allocator.dupe(u8, desc);
    }

    /// Start a new task definition
    fn startNewTask(self: *Parser, line: []const u8) !void {
        // Finalize current task if any
        if (self.current_task != null) {
            self.current_task = null;
        }

        // Extract task name (remove trailing :)
        const task_name = std.mem.trim(u8, line[0 .. line.len - 1], " \t");

        // Create new task
        var new_task = try Task.init(self.allocator, task_name);

        // Set description if we have one pending
        if (self.pending_description) |desc| {
            try new_task.setDescription(desc);
            self.allocator.free(desc);
            self.pending_description = null;
        }

        // Add to registry
        try self.registry.addTask(new_task);

        // Set as current task (get pointer to the task in the registry)
        self.current_task = &self.registry.tasks.items[self.registry.tasks.items.len - 1];
        self.state = .InTaskDefinition;
    }

    /// Parse an argument definition
    /// Format: arg: <name> [type] "description"
    /// Or: arg: <name> [type?] "description" (optional)
    fn parseArgument(self: *Parser, line: []const u8) !void {
        const content = std.mem.trim(u8, line[4..], " \t"); // Skip "arg:"

        // Find <name>
        const start_bracket = std.mem.indexOf(u8, content, "<") orelse {
            std.debug.print("Error at line {d}: Argument missing <name>\n", .{self.line_number});
            return error.InvalidArgumentSyntax;
        };

        const end_bracket = std.mem.indexOf(u8, content[start_bracket..], ">") orelse {
            std.debug.print("Error at line {d}: Argument missing closing >\n", .{self.line_number});
            return error.InvalidArgumentSyntax;
        };

        const arg_name = content[start_bracket + 1 .. start_bracket + end_bracket];

        // Find [type] or [type?]
        const type_start = std.mem.indexOf(u8, content[start_bracket + end_bracket..], "[") orelse {
            std.debug.print("Error at line {d}: Argument missing [type]\n", .{self.line_number});
            return error.InvalidArgumentSyntax;
        };

        const type_end = std.mem.indexOf(u8, content[start_bracket + end_bracket + type_start..], "]") orelse {
            std.debug.print("Error at line {d}: Argument missing closing ]\n", .{self.line_number});
            return error.InvalidArgumentSyntax;
        };

        const type_section = content[start_bracket + end_bracket + type_start + 1 .. start_bracket + end_bracket + type_start + type_end];

        // Check if optional (ends with ?)
        const is_optional = std.mem.endsWith(u8, type_section, "?");
        const type_str = if (is_optional) type_section[0 .. type_section.len - 1] else type_section;

        // Parse type (currently only "string" supported)
        const arg_type = if (std.mem.eql(u8, type_str, "string"))
            ArgType.string
        else {
            std.debug.print("Error at line {d}: Unknown type '{s}'\n", .{ self.line_number, type_str });
            return error.UnknownType;
        };

        // Find description (everything after ])
        const after_type = content[start_bracket + end_bracket + type_start + type_end + 1 ..];
        const description = extractDescription(after_type);

        // Create argument
        const arg = try Argument.init(self.allocator, arg_name, arg_type, is_optional, description);
        try self.current_task.?.addArgument(arg);
    }

    /// Parse a flag definition
    /// Format: flag: --long-name|-s [type="default"] "description"
    fn parseFlag(self: *Parser, line: []const u8) !void {
        const content = std.mem.trim(u8, line[5..], " \t"); // Skip "flag:"

        // Find --long-name
        const long_start = std.mem.indexOf(u8, content, "--") orelse {
            std.debug.print("Error at line {d}: Flag missing --long-name\n", .{self.line_number});
            return error.InvalidFlagSyntax;
        };

        // Find where long name ends (space, |, or [)
        var long_end = long_start + 2;
        while (long_end < content.len and content[long_end] != ' ' and content[long_end] != '|' and content[long_end] != '[') {
            long_end += 1;
        }

        const long_name = content[long_start + 2 .. long_end];

        // Find short name (optional)
        var short_name: ?u8 = null;
        var search_start = long_end;

        if (std.mem.indexOf(u8, content[long_end..], "|-")) |pipe_pos| {
            const short_pos = long_end + pipe_pos + 2;
            if (short_pos < content.len) {
                short_name = content[short_pos];
                search_start = short_pos + 1;
            }
        }

        // Find [type="default"]
        const type_start = std.mem.indexOf(u8, content[search_start..], "[") orelse {
            std.debug.print("Error at line {d}: Flag missing [type=\"default\"]\n", .{self.line_number});
            return error.InvalidFlagSyntax;
        };

        const type_end = std.mem.indexOf(u8, content[search_start + type_start..], "]") orelse {
            std.debug.print("Error at line {d}: Flag missing closing ]\n", .{self.line_number});
            return error.InvalidFlagSyntax;
        };

        const type_section = content[search_start + type_start + 1 .. search_start + type_start + type_end];

        // Parse type and default value (e.g., string="dev")
        const equals_pos = std.mem.indexOf(u8, type_section, "=") orelse {
            std.debug.print("Error at line {d}: Flag missing default value\n", .{self.line_number});
            return error.InvalidFlagSyntax;
        };

        const type_str = std.mem.trim(u8, type_section[0..equals_pos], " \t");
        var default_value = std.mem.trim(u8, type_section[equals_pos + 1 ..], " \t");

        // Remove quotes from default value
        if (default_value.len >= 2 and default_value[0] == '"' and default_value[default_value.len - 1] == '"') {
            default_value = default_value[1 .. default_value.len - 1];
        }

        // Parse type
        const flag_type = if (std.mem.eql(u8, type_str, "string"))
            ArgType.string
        else {
            std.debug.print("Error at line {d}: Unknown type '{s}'\n", .{ self.line_number, type_str });
            return error.UnknownType;
        };

        // Find description
        const after_type = content[search_start + type_start + type_end + 1 ..];
        const description = extractDescription(after_type);

        // Create flag
        const flag = try Flag.init(self.allocator, long_name, short_name, flag_type, default_value, description);
        try self.current_task.?.addFlag(flag);
    }

    /// Parse arch: directive
    /// Format: arch: linux|windows|macos|darwin|unix
    fn parseArch(self: *Parser, line: []const u8) !void {
        const content = std.mem.trim(u8, line[5..], " \t"); // Skip "arch:"

        if (TargetOS.fromString(content)) |target| {
            self.current_task.?.setTargetOS(target);
        } else {
            std.debug.print("Error at line {d}: Unknown architecture '{s}'\n", .{ self.line_number, content });
            std.debug.print("Valid values: linux, windows, macos, darwin, unix, any\n", .{});
            return error.UnknownArchitecture;
        }
    }

    /// Parse a script line
    fn parseScriptLine(self: *Parser, line: []const u8) !void {
        // Check if line starts with @ (silent)
        const is_silent = line.len > 0 and line[0] == '@';
        const content = if (is_silent) std.mem.trim(u8, line[1..], " \t") else line;

        const script_line = try ScriptLine.init(self.allocator, content, is_silent);
        try self.current_task.?.addScriptLine(script_line);
    }
};

/// Check if a line is indented
fn isIndented(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

/// Extract description from text (finds text in quotes or after #)
fn extractDescription(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;

    // Look for quoted string
    if (std.mem.indexOf(u8, trimmed, "\"")) |start| {
        if (std.mem.lastIndexOf(u8, trimmed, "\"")) |end| {
            if (end > start) {
                return trimmed[start + 1 .. end];
            }
        }
    }

    // Look for comment after #
    if (std.mem.indexOf(u8, trimmed, "#")) |hash_pos| {
        return std.mem.trim(u8, trimmed[hash_pos + 1 ..], " \t");
    }

    return null;
}