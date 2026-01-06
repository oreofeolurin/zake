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
    InMultilineScript, // Inside a multi-line script block ($ or @)
};

/// Parser for Zakefile
pub const Parser = struct {
    allocator: Allocator,
    registry: TaskRegistry,
    current_task: ?*Task,
    state: ParserState,
    pending_description: ?[]const u8,
    line_number: usize,
    base_dir: ?[]const u8, // Base directory for resolving imports
    multiline_buffer: std.ArrayList(u8), // Buffer for multi-line script content
    multiline_silent: bool, // Whether current multi-line block is silent
    multiline_ignore_error: bool, // Whether current multi-line block ignores errors
    multiline_indent: usize, // Indentation level of multi-line content
    multiline_marker: u8, // The marker that started this block (@ or $)

    pub fn init(allocator: Allocator) Parser {
        return Parser{
            .allocator = allocator,
            .registry = TaskRegistry.init(allocator),
            .current_task = null,
            .state = .TopLevel,
            .pending_description = null,
            .line_number = 0,
            .base_dir = null,
            .multiline_buffer = .empty,
            .multiline_silent = false,
            .multiline_ignore_error = false,
            .multiline_indent = 0,
            .multiline_marker = 0,
        };
    }

    pub fn setBaseDir(self: *Parser, dir: []const u8) void {
        self.base_dir = dir;
    }

    pub fn deinit(self: *Parser) void {
        if (self.pending_description) |desc| {
            self.allocator.free(desc);
        }
        self.multiline_buffer.deinit(self.allocator);
        self.registry.deinit();
    }

    /// Parse the entire Zakefile content
    pub fn parse(self: *Parser, content: []const u8) anyerror!TaskRegistry {
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            self.line_number += 1;
            try self.parseLine(line);
        }

        // Finalize any pending multi-line block
        try self.finalizeMultilineBlock();

        // Transfer ownership of registry
        const result = self.registry;
        self.registry = TaskRegistry.init(self.allocator);
        return result;
    }

    /// Finalize a multi-line script block and add it to the current task
    fn finalizeMultilineBlock(self: *Parser) !void {
        if (self.state != .InMultilineScript or self.multiline_buffer.items.len == 0) {
            self.state = .InScript;
            self.multiline_marker = 0;
            return;
        }

        // Add the accumulated multi-line content as a single script line
        const script_line = try ScriptLine.initMultiline(
            self.allocator,
            self.multiline_buffer.items,
            self.multiline_silent,
            self.multiline_ignore_error,
        );
        try self.current_task.?.addScriptLine(script_line);

        // Reset multi-line state
        self.multiline_buffer.clearRetainingCapacity();
        self.multiline_silent = false;
        self.multiline_ignore_error = false;
        self.multiline_indent = 0;
        self.multiline_marker = 0;
        self.state = .InScript;
    }
    /// Parse a single line
    fn parseLine(self: *Parser, line: []const u8) anyerror!void {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        // Handle multi-line script accumulation
        if (self.state == .InMultilineScript) {
            // Check for end marker: a line with just @ or $ (must be indented)
            if (isIndented(line) and trimmed.len == 1 and (trimmed[0] == '@' or trimmed[0] == '$')) {
                if (trimmed[0] == self.multiline_marker) {
                    // Matching end marker found - finalize the block
                    try self.finalizeMultilineBlock();
                    return;
                } else {
                    // Mismatched marker - error
                    const util = @import("util.zig");
                    util.printError("Line {d}: Mismatched block marker. Block started with '{c}' but ended with '{c}'", .{ self.line_number, self.multiline_marker, trimmed[0] });
                    return error.MismatchedBlockMarker;
                }
            }

            // Check if this line is still part of the multi-line block
            // Allow blank lines within the block
            if (trimmed.len == 0) {
                // Blank line - add it to preserve formatting
                if (self.multiline_buffer.items.len > 0) {
                    try self.multiline_buffer.append(self.allocator, '\n');
                }
                return;
            }

            // It must be indented at least as much as the content start
            if (isIndented(line)) {
                const indent = getIndentLevel(line);
                // Accept lines that are indented at the multiline indent level or more
                if (indent >= self.multiline_indent) {
                    // Add newline if not the first line
                    if (self.multiline_buffer.items.len > 0) {
                        try self.multiline_buffer.append(self.allocator, '\n');
                    }
                    // Strip the base indentation and add the content
                    const content_start = self.multiline_indent;
                    if (content_start < line.len) {
                        try self.multiline_buffer.appendSlice(self.allocator, std.mem.trimRight(u8, line[content_start..], " \t\r"));
                    }
                    return;
                }
            }
            // Line is not indented enough - finalize the multi-line block
            try self.finalizeMultilineBlock();
            // Fall through to process this line normally
        }

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

        // Check for import: directive at top level
        // Supports: import: path, import "path"
        if (!isIndented(line)) {
            if (std.mem.startsWith(u8, trimmed, "import:")) {
                try self.parseImportColon(trimmed);
                return;
            } else if (std.mem.startsWith(u8, trimmed, "import ")) {
                try self.parseImportQuoted(trimmed);
                return;
            }
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
        } else if (std.mem.startsWith(u8, trimmed, "requires:")) {
            try self.parseRequires(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "when:")) {
            try self.parseWhen(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "alias:")) {
            try self.parseAlias(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "matrix:")) {
            try self.parseMatrix(trimmed);
        } else if (std.mem.startsWith(u8, trimmed, "script:")) {
            self.state = .InScript;
        } else if (std.mem.startsWith(u8, trimmed, "zake::")) {
            // Stdlib call - treat as script line and enter script mode
            self.state = .InScript;
            try self.parseScriptLine(trimmed, line);
        } else if (std.mem.startsWith(u8, trimmed, "let ")) {
            // Variable assignment - treat as script line and enter script mode
            self.state = .InScript;
            try self.parseScriptLine(trimmed, line);
        } else if (self.state == .InScript) {
            try self.parseScriptLine(trimmed, line);
        } else {
            // Not a directive - assume it's a script line and enter script mode
            // This handles implicit script lines without explicit "script:" block
            self.state = .InScript;
            try self.parseScriptLine(trimmed, line);
        }
    }

    /// Parse requires: directive (task dependencies)
    /// Format: requires: task1 task2 task3
    fn parseRequires(self: *Parser, line: []const u8) !void {
        const content = std.mem.trim(u8, line[9..], " \t"); // Skip "requires:"

        // Split by spaces to get task names
        var iter = std.mem.splitAny(u8, content, " \t,");
        while (iter.next()) |dep_name| {
            const trimmed_dep = std.mem.trim(u8, dep_name, " \t");
            if (trimmed_dep.len > 0) {
                try self.current_task.?.addRequires(trimmed_dep);
            }
        }
    }

    /// Parse when: directive (conditional execution)
    /// Format: when: <expression>
    /// Supports: ${VAR} == "value", {{var}} != "", $(cmd), boolean expressions
    fn parseWhen(self: *Parser, line: []const u8) !void {
        const expression = std.mem.trim(u8, line[5..], " \t"); // Skip "when:"
        if (expression.len == 0) {
            std.debug.print("Error at line {d}: Empty when: expression\n", .{self.line_number});
            return error.InvalidCondition;
        }
        try self.current_task.?.setCondition(expression);
    }

    /// Parse alias: directive (alternative task names)
    /// Format: alias: name1 name2 name3
    fn parseAlias(self: *Parser, line: []const u8) !void {
        const content = std.mem.trim(u8, line[6..], " \t"); // Skip "alias:"

        // Split by spaces to get alias names
        var iter = std.mem.splitAny(u8, content, " \t,");
        while (iter.next()) |alias_name| {
            const trimmed_alias = std.mem.trim(u8, alias_name, " \t");
            if (trimmed_alias.len > 0) {
                try self.current_task.?.addAlias(trimmed_alias);
            }
        }
    }

    /// Parse matrix: directive (combinatorial execution)
    /// Format: matrix: var=[val1, val2, val3]
    /// Multiple matrix lines can be used for multiple dimensions
    fn parseMatrix(self: *Parser, line: []const u8) !void {
        const content = std.mem.trim(u8, line[7..], " \t"); // Skip "matrix:"

        // Find the equals sign
        const eq_pos = std.mem.indexOf(u8, content, "=") orelse {
            std.debug.print("Error at line {d}: Invalid matrix format, expected var=[...]\n", .{self.line_number});
            return error.InvalidMatrix;
        };

        const var_name = std.mem.trim(u8, content[0..eq_pos], " \t");
        if (var_name.len == 0) {
            std.debug.print("Error at line {d}: Empty matrix variable name\n", .{self.line_number});
            return error.InvalidMatrix;
        }

        // Get the values part - should be [val1, val2, ...]
        const values_part = std.mem.trim(u8, content[eq_pos + 1 ..], " \t");

        if (!std.mem.startsWith(u8, values_part, "[") or !std.mem.endsWith(u8, values_part, "]")) {
            std.debug.print("Error at line {d}: Matrix values must be in brackets [...]\n", .{self.line_number});
            return error.InvalidMatrix;
        }

        // Extract values between brackets
        const values_content = values_part[1 .. values_part.len - 1];

        // Parse comma-separated values
        var values: ArrayList([]const u8) = .empty;
        defer values.deinit(self.allocator);

        var iter = std.mem.splitScalar(u8, values_content, ',');
        while (iter.next()) |val| {
            const trimmed_val = std.mem.trim(u8, val, " \t");
            if (trimmed_val.len > 0) {
                try values.append(self.allocator, trimmed_val);
            }
        }

        if (values.items.len == 0) {
            std.debug.print("Error at line {d}: Matrix must have at least one value\n", .{self.line_number});
            return error.InvalidMatrix;
        }

        try self.current_task.?.addMatrixVariable(var_name, values.items);
    }

    /// Parse import: directive
    /// Format: import: path/to/file.zake
    /// Format: import: "path/to/file.zake"
    /// Format: import: path/to/dir (loads Zakefile from that directory)
    fn parseImportColon(self: *Parser, line: []const u8) !void {
        var path = std.mem.trim(u8, line[7..], " \t"); // Skip "import:"
        if (path.len == 0) {
            std.debug.print("Error at line {d}: Empty import path\n", .{self.line_number});
            return error.InvalidImport;
        }

        // Remove quotes if present
        if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
            path = path[1 .. path.len - 1];
        }

        try self.processImport(path);
    }

    /// Parse import "path" syntax
    fn parseImportQuoted(self: *Parser, line: []const u8) !void {
        var path = std.mem.trim(u8, line[7..], " \t"); // Skip "import "

        // Remove quotes if present
        if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') {
            path = path[1 .. path.len - 1];
        }

        if (path.len == 0) {
            std.debug.print("Error at line {d}: Empty import path\n", .{self.line_number});
            return error.InvalidImport;
        }

        try self.processImport(path);
    }

    /// Process import - shared logic for both syntaxes
    fn processImport(self: *Parser, path: []const u8) !void {
        // Resolve the path relative to base_dir
        const resolved_path = if (self.base_dir) |base| blk: {
            if (std.fs.path.isAbsolute(path)) {
                break :blk try self.allocator.dupe(u8, path);
            }
            break :blk try std.fs.path.join(self.allocator, &[_][]const u8{ base, path });
        } else blk: {
            break :blk try self.allocator.dupe(u8, path);
        };
        defer self.allocator.free(resolved_path);

        // Determine the actual file path
        var file_path: []const u8 = undefined;
        var owns_file_path = false;

        // Check if it's a directory (append Zakefile)
        if (std.fs.cwd().openDir(resolved_path, .{})) |dir| {
            var d = dir;
            d.close();
            file_path = try std.fs.path.join(self.allocator, &[_][]const u8{ resolved_path, "Zakefile" });
            owns_file_path = true;
        } else |_| {
            file_path = resolved_path;
        }
        defer if (owns_file_path) self.allocator.free(file_path);

        // Read the imported file
        const file_content = std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024) catch |err| {
            std.debug.print("Error at line {d}: Cannot read import '{s}': {any}\n", .{ self.line_number, file_path, err });
            return error.ImportNotFound;
        };
        defer self.allocator.free(file_content);

        // Get the directory of the imported file for nested imports
        const import_dir = std.fs.path.dirname(file_path) orelse ".";

        // Create a sub-parser for the imported file
        var sub_parser = Parser.init(self.allocator);
        defer sub_parser.deinit();
        sub_parser.base_dir = import_dir;

        // Parse the imported file
        var imported_registry = try sub_parser.parse(file_content);

        // Merge imported tasks into current registry
        for (imported_registry.tasks.items) |imported_task| {
            // Check for duplicate task names
            if (self.registry.findTask(imported_task.name)) |_| {
                std.debug.print("Warning: import '{s}' contains duplicate task '{s}', skipping\n", .{ file_path, imported_task.name });
                // Need to deinit the skipped task
                var task_copy = imported_task;
                task_copy.deinit();
                continue;
            }
            // Move task to our registry (transfer ownership)
            try self.registry.tasks.append(self.allocator, imported_task);
        }
        // Clear the imported registry's tasks to prevent double-free
        // (ownership has been transferred to self.registry)
        imported_registry.tasks.clearAndFree(self.allocator);

        // Merge imported global variables
        // Use addGlobalVar which properly duplicates keys/values
        // This ensures consistent ownership semantics when variables are later overwritten
        var var_iter = imported_registry.global_vars.iterator();
        while (var_iter.next()) |entry| {
            if (!self.registry.global_vars.contains(entry.key_ptr.*)) {
                // Add to registry (this duplicates the key/value)
                try self.registry.addGlobalVar(entry.key_ptr.*, entry.value_ptr.*);
            }
        }

        // Explicitly deinit imported_registry's global_vars (parse() returned ownership to us)
        // sub_parser.deinit() only cleans up sub_parser.registry, which is now empty
        var cleanup_iter = imported_registry.global_vars.iterator();
        while (cleanup_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        imported_registry.global_vars.deinit();
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
        var value = std.mem.trim(u8, line[pos + op_len ..], " \t");

        // Strip surrounding quotes if present
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }

        // Process $(VAR) references in the value
        const processed_value = try self.expandMakefileVars(value);
        defer if (processed_value.ptr != value.ptr) self.allocator.free(processed_value);

        // For conditional assignment (?=), only set if not already defined
        // Check both Zakefile vars AND environment variables
        if (is_conditional) {
            if (self.registry.global_vars.get(var_name) != null) {
                return true; // Already defined in Zakefile, skip
            }
            // Check environment variable
            var env_name_buf: [256]u8 = undefined;
            if (var_name.len < 256) {
                @memcpy(env_name_buf[0..var_name.len], var_name);
                env_name_buf[var_name.len] = 0;
                if (std.posix.getenv(env_name_buf[0..var_name.len :0]) != null) {
                    return true; // Already defined in environment, skip
                }
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

        // Find [type], [type?], or [type="default"]
        const type_start = std.mem.indexOf(u8, content[start_bracket + end_bracket ..], "[") orelse {
            std.debug.print("Error at line {d}: Argument missing [type]\n", .{self.line_number});
            return error.InvalidArgumentSyntax;
        };

        const type_end = std.mem.indexOf(u8, content[start_bracket + end_bracket + type_start ..], "]") orelse {
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

        const type_end = std.mem.indexOf(u8, content[search_start + type_start ..], "]") orelse {
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
    /// Prefixes: @ = silent, ? = ignore errors, @? or ?@ = both
    /// Multi-line: $ or @ alone on a line starts a multi-line block
    fn parseScriptLine(self: *Parser, trimmed: []const u8, original_line: []const u8) !void {
        var is_silent = false;
        var ignore_error = false;
        var content = trimmed;

        // Parse prefixes (can be @, ?, @?, ?@, $)
        while (content.len > 0) {
            if (content[0] == '@') {
                is_silent = true;
                content = content[1..];
            } else if (content[0] == '?') {
                ignore_error = true;
                content = content[1..];
            } else if (content[0] == '$') {
                content = content[1..];
                // Check if this is a multi-line marker ($ or @ alone, or just $)
                const remaining = std.mem.trim(u8, content, " \t");
                if (remaining.len == 0) {
                    // This is a multi-line block marker
                    self.state = .InMultilineScript;
                    self.multiline_silent = is_silent;
                    self.multiline_ignore_error = ignore_error;
                    self.multiline_marker = '$'; // Track which marker started this block
                    // Calculate the indent level for content lines
                    // The content should be indented more than the current line
                    self.multiline_indent = getIndentLevel(original_line) + 4; // Expect content indented by 4 more spaces
                    return;
                }
                // Not a multi-line marker, $ is explicit shell prefix - process the rest
                break;
            } else {
                break;
            }
        }

        // Check if @ alone indicates multi-line silent block
        if (is_silent and !ignore_error and content.len == 0) {
            // @ alone means silent multi-line block
            self.state = .InMultilineScript;
            self.multiline_silent = true;
            self.multiline_ignore_error = false;
            self.multiline_marker = '@'; // Track which marker started this block
            self.multiline_indent = getIndentLevel(original_line) + 4;
            return;
        }

        content = std.mem.trim(u8, content, " \t");

        // Don't add empty content lines
        if (content.len == 0) {
            return;
        }

        const script_line = try ScriptLine.init(self.allocator, content, is_silent, ignore_error);
        try self.current_task.?.addScriptLine(script_line);
    }
};

/// Check if a line is indented
fn isIndented(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

/// Get the indentation level of a line (number of leading spaces/tabs)
fn getIndentLevel(line: []const u8) usize {
    var indent: usize = 0;
    for (line) |c| {
        if (c == ' ') {
            indent += 1;
        } else if (c == '\t') {
            indent += 4; // Treat tabs as 4 spaces
        } else {
            break;
        }
    }
    return indent;
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
