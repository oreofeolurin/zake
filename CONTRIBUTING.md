# Contributing to Zake

Thank you for your interest in contributing to Zake! This document provides guidelines and information for contributors.

## Code of Conduct

By participating in this project, you agree to abide by our Code of Conduct:

- Be respectful and inclusive
- Welcome newcomers and help them learn
- Focus on what is best for the community
- Show empathy towards other community members

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear title** - Describe the issue concisely
- **Steps to reproduce** - Detailed steps to recreate the problem
- **Expected behavior** - What you expected to happen
- **Actual behavior** - What actually happened
- **Environment** - OS, Zig version, Zake version
- **Zakefile** - A minimal example that demonstrates the issue

Example:

```markdown
## Bug: Variable substitution fails with nested braces

**Steps to reproduce:**
1. Create a Zakefile with: `echo "{{var{{nested}}}}"`
2. Run: `zake test`

**Expected:** Should substitute variables
**Actual:** Error: "Unclosed variable"

**Environment:**
- OS: macOS 14.0
- Zig: 0.15.2
- Zake: main branch (commit abc123)
```

### Suggesting Features

Feature requests are welcome! Please include:

- **Use case** - Why is this feature needed?
- **Proposed solution** - How should it work?
- **Alternatives** - What other approaches did you consider?
- **Examples** - Show how it would be used in a Zakefile

### Pull Requests

1. **Fork the repository** and create a branch from `main`
2. **Follow the coding style** (see below)
3. **Add tests** for new functionality
4. **Update documentation** if needed
5. **Ensure tests pass** with `zig build test`
6. **Write clear commit messages** (see below)
7. **Submit your PR** with a clear description

## Development Setup

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.1 or later
- Git
- A text editor or IDE with Zig support

### Getting Started

```bash
# Clone your fork
git clone https://github.com/oreofeolurin/zake.git
cd zake

# Build the project
zig build

# Run tests
zig build test

# Run zake with your changes
zig build run -- <task>

# Install locally for testing
zig build install-system -Dinstall_dir=~/.local/bin
```

### Project Structure

```
zake/
├── src/
│   ├── main.zig       # CLI entry point and argument parsing
│   ├── task.zig       # Task data structures
│   ├── parser.zig     # Zakefile parser
│   ├── executor.zig   # Variable substitution and shell execution
│   ├── help.zig       # Help text generation
│   ├── stdlib.zig     # Standard library (zake::fs, zake::log, etc.)
│   ├── util.zig       # Utilities (colors, shell detection)
│   └── test/          # Test files
├── examples/          # Example Zakefiles
├── build.zig          # Build configuration
├── build.zig.zon      # Package manifest
├── Zakefile           # Project tasks
├── SPEC.md            # Language specification
└── README.md          # User documentation
```

## Coding Style

### Zig Style Guide

Follow the [Zig Style Guide](https://ziglang.org/documentation/master/#Style-Guide):

- **4 spaces** for indentation (no tabs)
- **snake_case** for functions and variables
- **PascalCase** for types
- **SCREAMING_SNAKE_CASE** for constants
- **Document public APIs** with doc comments (`///`)

Example:

```zig
/// Parse a Zakefile and return a TaskRegistry
pub fn parse(allocator: Allocator, content: []const u8) !TaskRegistry {
    var parser = Parser.init(allocator);
    defer parser.deinit();
    return try parser.parse(content);
}
```

### Error Handling

- Use Zig's error handling (`try`, `catch`, `errdefer`)
- Provide helpful error messages with context
- Use the `util.printError()` function for user-facing errors

Example:

```zig
const task = registry.findTask(task_name) orelse {
    util.printError("Task '{s}' not found.", .{task_name});
    return error.TaskNotFound;
};
```

### Memory Management

- Always use an `Allocator` (passed as parameter)
- Free all allocated memory (use `defer` and `errdefer`)
- Avoid memory leaks (test with `-Doptimize=Debug`)

Example:

```zig
pub fn substituteVariables(allocator: Allocator, template: []const u8, vars: VarMap) ![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // ... build result ...

    return result.toOwnedSlice(allocator);
}
```

## Testing

### Writing Tests

Add tests for all new functionality:

```zig
test "variable substitution replaces {{var}}" {
    const allocator = std.testing.allocator;

    var vars = VarMap.init(allocator);
    defer vars.deinit();

    try vars.put("name", "World");

    const result = try substituteVariables(allocator, "Hello {{name}}", vars);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("Hello World", result);
}
```

### Running Tests

```bash
# Run all tests
zig build test

# Run in debug mode (catches memory leaks)
zig build test -Doptimize=Debug
```

### Manual Testing

Create test Zakefiles in a temporary directory:

```bash
mkdir /tmp/zake-test
cd /tmp/zake-test

cat > Zakefile << 'EOF'
## Test task
test:
    arg: <name> [string] "Your name"
    script:
        echo "Hello {{name}}"
EOF

# Test your changes
~/Projects/zake/zig-out/bin/zake test World
```

## Commit Messages

Write clear, descriptive commit messages:

### Format

```
<type>: <subject>

<body>

<footer>
```

### Types

- `feat:` - New feature
- `fix:` - Bug fix
- `docs:` - Documentation changes
- `test:` - Adding or updating tests
- `refactor:` - Code refactoring
- `perf:` - Performance improvements
- `chore:` - Maintenance tasks

### Examples

```
feat: add support for matrix builds

Implements the matrix: directive that allows tasks to run
multiple times with different values. The special {{item}}
variable contains the current iteration value.

Closes #42
```

```
fix: handle empty optional arguments correctly

Optional arguments were being set to undefined instead of
empty string when not provided.

Fixes #38
```

## Documentation

Update documentation when:

- Adding new features → Update README.md and SPEC.md
- Changing behavior → Update SPEC.md
- Adding configuration → Update README.md
- Fixing bugs → Consider adding examples to prevent regression

## Release Process

(For maintainers)

1. Update version in README.md and changelog
2. Create a git tag: `git tag v0.1.0`
3. Push tag: `git push origin v0.1.0`
4. Create GitHub release with binaries for:
   - Linux (x64, ARM)
   - macOS (Intel, Apple Silicon)
   - Windows (x64)

## Questions?

- Check existing [Issues](https://github.com/oreofeolurin/zake/issues)
- Start a [Discussion](https://github.com/oreofeolurin/zake/discussions)
- Read the [SPEC.md](SPEC.md) for language details

## Recognition

Contributors will be recognized in:

- README.md (Contributors section)
- Release notes
- Project documentation

Thank you for contributing to Zake! 🎉
