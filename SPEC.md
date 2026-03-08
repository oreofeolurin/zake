# Zake Language Specification

**Version:** 1.0 (Unified)
**Status:** Canonical Reference
**Last Updated:** 2026-02-17

---

## 1. Introduction

### 1.1 Vision

**Zake** is a modern, language-agnostic task runner designed to replace traditional `make`. It combines the simplicity of a Makefile-like syntax with the power and user-friendliness of a modern command-line interface.

### 1.2 Core Principles

- **Zero Dependencies:** Single, statically-linked executable with no runtime dependencies
- **Declarative & Simple Syntax:** Flat, intuitive format requiring no prior programming knowledge
- **Intuitive CLI:** Auto-generated from the Zakefile with subcommands, flags, and rich help
- **Cross-Platform:** Works identically on Linux, macOS, and Windows
- **Language Agnostic:** Orchestrates shell commands, not tied to any programming ecosystem
- **Self-Documenting:** Help text is part of the task definition

### 1.3 Design Philosophy

Zake tasks are composed of two zones:

1. **Definition Zone** - Declarative interface (arguments, flags, dependencies)
2. **Action Zone** - Imperative implementation (shell commands and Zake operations)

This separation creates clarity: the "what" is separated from the "how."

---

## 2. The Zakefile

### 2.1 File Name and Location

The runner searches for a file named `Zakefile` (case-sensitive) in the current working directory.

### 2.2 Basic Structure

```makefile
# This is a comment

## This is help text for the next task
task-name:
    # Definition zone (optional)
    arg: <name> [string] "Description"
    flag: --env|-e [string="dev"] "Environment to use"

    # Action zone (required for executable tasks)
    script:
        echo "Hello from {{name}} in {{env}}"
        @./some-script.sh
```

### 2.3 Syntax Rules

1. **Comments:** Lines starting with `#` are comments (ignored)
2. **Help Text:** Lines starting with `##` provide help for the next task
3. **Task Definition:** Non-indented line ending with `:` defines a task
4. **Task Names:** Use lowercase, hyphens, or dots (e.g., `build`, `test-unit`, `secrets.add`)
5. **Dots Create Subcommands:** `secrets.view:` creates `zake secrets view` subcommand
6. **Indentation:** Use consistent indentation (tabs or spaces) for task body
7. **Blank Lines:** Allowed anywhere for readability

---

## 3. Variable System

Zake uses three distinct variable syntaxes to avoid ambiguity:

| Syntax | Type | Example | Description |
|--------|------|---------|-------------|
| `{{var}}` | Zake Variable | `{{name}}`, `{{env}}` | Task arguments, flags, `let` variables, global `vars` |
| `${VAR}` | Environment Variable | `${USER}`, `${CI}` | System environment variables |
| `$(command)` | Shell Substitution | `$(git rev-parse HEAD)` | Output of shell command |

### 3.1 Variable Scoping

- **Global vars** (from `vars:` directive) - Available to all tasks
- **Task-local vars** - Arguments, flags, and `let` variables - Scoped to current task only
- **Environment vars** - Inherited from system environment
- **Isolation** - Tasks invoked with `run` do NOT inherit parent's local variables

### 3.2 Examples

```makefile
vars:
    APP_NAME: "my-app"
    VERSION: "1.0.0"

build:
    arg: <target> [string] "Build target"
    flag: --env|-e [string="dev"] "Environment"
    script:
        let commit_hash = $(git rev-parse --short HEAD)
        let user = ${USER}

        echo "Building {{APP_NAME}} v{{VERSION}}"
        echo "Target: {{target}}, Env: {{env}}"
        echo "Commit: {{commit_hash}}, User: {{user}}"
```

---

## 4. Task Definition Zone

All keywords in this section must appear BEFORE the `script:` block.

### 4.1 Arguments

Define required or optional positional arguments.

**Syntax:**
```makefile
arg: <name> [type] "Description"
arg: <name> [type?] "Description"  # Optional (note the ?)
```

**Examples:**
```makefile
deploy:
    arg: <environment> [string] "Target environment (dev, staging, prod)"
    arg: <version> [string?] "Version to deploy (defaults to latest)"
    script:
        echo "Deploying to {{environment}}"
```

**Rules:**
- Arguments are positional and order matters
- Required arguments cannot follow optional ones
- Type is currently always `[string]` (future: `[int]`, `[bool]`, `[path]`)
- Optional arguments use `[string?]` syntax
- Unused optional arguments substitute to empty string

### 4.2 Flags

Define optional named flags with default values.

**Syntax:**
```makefile
flag: --long-name|-s [type="default"] "Description"
flag: --long-name|-s [type?] "Description"  # Optional (defaults to empty string)
```

**Examples:**
```makefile
build:
    flag: --env|-e [string="dev"] "Environment to build for"
    flag: --verbose|-v [string="false"] "Enable verbose output"
    flag: --region|-r [string?] "AWS region (optional)"
    script:
        echo "Building for {{env}}"
```

**Rules:**
- Flags are always optional (user doesn't have to provide them)
- Use `[type="default"]` to specify an explicit default value
- Use `[type?]` for optional flags that default to empty string
- Short form (single character) is optional
- Can appear in any order on command line
- Type is currently always `[string]`

### 4.3 Task Dependencies (Phase 3)

Specify prerequisite tasks that must complete successfully before this task runs.

**Syntax:**
```makefile
requires: task-name another-task
```

**Example:**
```makefile
test:
    script:
        go test ./...

lint:
    script:
        golangci-lint run

deploy:
    requires: test lint
    script:
        ./deploy.sh
```

**Rules:**
- Tasks are executed in dependency order (topological sort)
- Circular dependencies are detected and reported as errors
- Failed dependencies prevent dependent task from running
- Each dependency runs only once per invocation

### 4.4 Architecture-Specific Tasks (Phase 1.5)

Define platform-specific variants of a task using the `arch:` directive. When multiple tasks share the same name but have different `arch:` values, Zake automatically selects the best match for the current operating system.

**Syntax:**
```makefile
arch: linux|windows|macos|darwin|unix|any
```

**Supported Values:**
| Value | Description |
|-------|-------------|
| `linux` | Linux only |
| `windows` | Windows only |
| `macos` | macOS only |
| `darwin` | Alias for macos |
| `unix` | Linux, macOS, FreeBSD (anything non-Windows) |
| `any` | All platforms (default when no arch: specified) |

**Example:**
```makefile
## Build the project (default)
build:
    script:
        echo "Generic build"
        make build

## Build the project (macOS specific)
build:
    arch: macos
    script:
        echo "Building on macOS"
        xcodebuild -project MyApp.xcodeproj

## Build the project (Windows specific)
build:
    arch: windows
    script:
        echo "Building on Windows"
        msbuild MyApp.sln

## Build the project (Linux specific)
build:
    arch: linux
    script:
        echo "Building on Linux"
        cmake --build ./build
```

**Selection Priority:**
1. Exact OS match (e.g., `arch: macos` on macOS)
2. Category match (e.g., `arch: unix` on macOS)
3. Fallback to no `arch:` directive (default/any)

**Rules:**
- Multiple tasks can share the same name with different `arch:` values
- Each `arch:` variant can have its own description, arguments, and flags
- The `arch:` directive must appear in the definition zone (before `script:`)
- Tasks with arch variants show `[multi-arch]` in help output
- If no matching arch variant exists, the `any` variant is used

### 4.5 Conditional Execution (Phase 3)

Execute task only if condition is true.

**Syntax:**
```makefile
when: <expression>
```

**Example:**
```makefile
deploy:
    when: ${CI} == "true"
    script:
        ./deploy.sh

production-deploy:
    when: {{env}} == "production"
    flag: --env|-e [string="dev"] "Environment"
    script:
        echo "Deploying to production!"
```

**Expression Syntax:**
- Binary operators: `==`, `!=`
- Operands: Variables (`{{var}}`, `${VAR}`) or string literals (`"value"`)
- Future: `&&`, `||`, `!`, `>`, `<`, `>=`, `<=`

### 4.6 Task Aliases (Phase 4)

Define alternative names for invoking the task.

**Syntax:**
```makefile
alias: short-name another-name
```

**Example:**
```makefile
deploy-production:
    alias: deploy-prod dp
    script:
        ./deploy.sh production
```

**Usage:**
```bash
zake deploy-production  # Full name
zake deploy-prod        # Alias
zake dp                 # Alias
```

### 4.7 Matrix Execution (Phase 4)

Run the task multiple times with different combinations of values. Multiple matrix variables create a cross-product of all combinations.

**Syntax:**
```makefile
matrix: variable=[value1, value2, value3]
```

**Example:**
```makefile
build-all:
    matrix: target=[x86, arm, wasm]
    matrix: mode=[debug, release]
    echo "Building {{target}} in {{mode}} mode"
    zig build -Dtarget={{target}} -Doptimize={{mode}}
```

**Output (6 combinations):**
```
Running matrix: 6 combination(s) for 'build-all'
[1/6] build-all
Building x86 in debug mode
[2/6] build-all
Building arm in debug mode
...
```

**Rules:**
- Matrix variables are available as `{{variable}}` in the script
- Multiple matrix directives create combinations (cross-product)
- All iterations must succeed for task to succeed
- Executes sequentially

### 4.8 Import Directive (Phase 4)

Include tasks from other Zakefiles to organize large projects.

**Syntax:**
```makefile
import "path/to/file.zake"
import: path/to/file.zake
```

**Example:**
```makefile
# Main Zakefile
import "./lib/common.zake"
import "./lib/deploy.zake"

build:
    requires: setup  # 'setup' is defined in common.zake
    echo "Building..."
```

**Rules:**
- Import paths are relative to the Zakefile containing the import
- Duplicate task names are skipped with a warning
- Global variables from imported files are merged
- Nested imports are supported

---

## 5. Task Action Zone

### 5.1 The `script:` Block

The action zone is introduced by the `script:` keyword and contains the task's implementation.

**Syntax:**
```makefile
task-name:
    script:
        command1
        command2
        @command3  # Silent
```

**Rules:**
- The `script:` keyword is **mandatory** for tasks that perform actions
- All lines within the block are indented
- Empty lines are allowed for readability
- Blank scripts are valid (no-op tasks)

### 5.2 Shell Commands (Default)

By default, lines in the `script:` block are shell commands.

**Echoed Commands:**
```makefile
build:
    script:
        echo "Building..."
        go build -o bin/app
```

Output:
```
$ echo "Building..."
Building...
$ go build -o bin/app
[build output]
```

**Silent Commands (@ prefix):**
```makefile
build:
    script:
        @echo "Building..."
        @go build -o bin/app
```

Output:
```
Building...
[build output]
```

### 5.3 Multi-line Shell Scripts

For complex shell logic, use a continuation prefix:

**Echoed Multi-line:**
```makefile
script:
    $
        if [ -f "config.json" ]; then
            echo "Config found"
        else
            echo "Config missing"
        fi
```

**Silent Multi-line:**
```makefile
script:
    @
        for arch in amd64 arm64; do
            GOARCH=$arch go build -o bin/app-$arch
        done
```

**Optional End Marker:**

Multi-line blocks can optionally be terminated with a matching marker (`@` or `$`) for clarity:

```makefile
script:
    # Style 1: With explicit end marker (recommended for complex scripts)
    @
        if [ "{{exists}}" != "0" ]; then
            echo "Error: not found"
            exit 1
        fi
    @
    
    echo "Continuing after the block..."
    
    # Style 2: Indentation-based (default, block ends at de-indent)
    @
        echo "This block ends automatically"
        echo "when indentation decreases"
    
    echo "This line is outside the block"
```

**Rules:**
- End marker must be the same as the start marker (`@` ends `@`, `$` ends `$`)
- End marker must be on its own line, indented within the script block
- End marker is optional - blocks also end when indentation decreases
- Use explicit end markers when you have blank lines or want visual clarity

### 5.4 Zake Commands

Special keywords that invoke Zake functionality rather than shell commands.

#### 5.4.1 `let` - Local Variables (Phase 2)

Create task-local variables.

**Syntax:**
```makefile
let variable_name = value
let variable_name = $(shell command)
```

**Example:**
```makefile
build:
    script:
        let timestamp = $(date +%Y%m%d)
        let output = dist/app-{{timestamp}}.tar.gz

        mkdir -p dist
        tar -czf {{output}} bin/
        echo "Created {{output}}"
```

**Rules:**
- Variables are task-local, not passed to `run` tasks
- Can use shell substitution `$()`
- Can reference other Zake variables `{{var}}`
- Cannot be reassigned (immutable)
- Supports expression operators: `||` (logical OR), `??` (nullish coalescing)
- Can call stdlib functions: `zake::namespace.function(...)`

**Expression Operators:**
```makefile
# || - Returns first truthy (non-empty) value
let result = {{optional_value}} || "default"
let component = {{component}} || zake::path.last("2")

# ?? - Returns first non-null (non-empty) value (same as || in Zake)
let config = {{custom_config}} ?? "config.json"

# Chaining
let value = {{a}} || {{b}} || "fallback"
```

**With Stdlib Functions:**
```makefile
# Get current directory or use provided value
let dir = {{directory}} || zake::sys.pwd()

# Extract last N path components with fallback
let comp = {{component}} || zake::path.last("2")

# String manipulation
let upper_name = zake::str.upper({{name}})
let config_path = zake::path.join("config", {{env}})
```

#### 5.4.2 `run` - Invoke Other Tasks (Phase 2)

Execute another Zake task from within a script.

**Syntax:**
```makefile
run task-name
run task-name arg1 arg2
run task-name --flag=value
```

**Example:**
```makefile
build:
    arg: <target> [string] "Build target"
    script:
        echo "Building {{target}}"
        go build -o bin/{{target}} ./cmd/{{target}}

deploy:
    script:
        run build api
        run build worker
        @./deploy.sh
```

**Rules:**
- Tasks are executed synchronously (run waits for completion)
- Failed tasks abort the parent task
- No variable inheritance (must pass via args/flags)
- Detects infinite recursion

#### 5.4.3 `zake::run` and `zake::call` - Task Invocation (Phase 2)

Execute tasks and capture results programmatically.

**`zake::run(task, args...)` - Execute and Return Exit Code**

Executes a task and returns the exit code as a string.

**Syntax:**
```makefile
let exit_code = zake::run(task_name, arg1, arg2, ...)
```

**Example:**
```makefile
test-all:
    script:
        let task = _run_tests
        let result = zake::run(task, "unit")
        echo "Tests exited with code: {{result}}"
        
        # Can use in conditionals
        let success = {{result}} == "0" ? "passed" : "failed"
        echo "Tests {{success}}"
```

**`zake::call(task, args...)` - Execute and Capture Output**

Executes a task and captures its stdout output (from `@` silent commands).

**Syntax:**
```makefile
let output = zake::call(task_name, arg1, arg2, ...)
```

**Example:**
```makefile
_get_version:
    arg: <component> [string] "Component name"
    script:
        @cat version.txt

deploy:
    script:
        let version = zake::call(_get_version, "api")
        echo "Deploying version: {{version}}"
        docker push myapp:{{version}}
```

**Variable Resolution:**
Both `zake::run` and `zake::call` support:
- **Quoted strings** - `zake::call(_task, "literal value")`
- **Unquoted variables** - `zake::call(task_var, arg_var)` where variables are resolved
- **Global variables** - Tasks can access global variables defined in `vars:`
- **Caller's local variables** - Tasks inherit the caller's local `let` variables

**Example with Variables:**
```makefile
build:
    script:
        let task = _compile
        let target = x86
        let result = zake::call(task, target)  # Resolves to: zake::call(_compile, "x86")
        echo "Build output: {{result}}"
```

**Rules:**
- `zake::run` returns exit code as string ("0" for success)
- `zake::call` captures output from `@` prefixed (silent) commands only
- Global variables from `vars:` are passed to called tasks
- Caller's local variables are also passed to called tasks
- Positional arguments override inherited variables
- Both support recursive calls with depth limits

#### 5.4.4 `zake::exec` - Execute Shell Commands (Phase 2)

Execute a shell command and capture its output immediately.

**Syntax:**
```makefile
let output = zake::exec("shell command")
let output = zake::exec(variable_with_command)
```

**Example:**
```makefile
deploy:
    script:
        let current_dir = zake::exec("pwd")
        let commit = zake::exec("git rev-parse --short HEAD")
        let sum = zake::exec("expr 20 + 22")
        
        echo "Deploying from: {{current_dir}}"
        echo "Commit: {{commit}}"
        echo "Result: {{sum}}"
```

**With Variable Substitution:**
```makefile
build:
    arg: <target> [string] "Build target"
    script:
        let target_upper = zake::exec("echo {{target}} | tr 'a-z' 'A-Z'")
        echo "Building {{target_upper}}"
```

**Rules:**
- Executes the command in `/bin/sh -c` (or `cmd.exe /C` on Windows)
- Captures stdout and returns it as a string
- Trailing newlines are automatically trimmed
- Supports variable substitution in the command string
- Fails task if command exits with non-zero status
- Maximum output: 1MB

**Comparison:**
- `zake::exec("command")` - Immediate shell execution, captures output
- `zake::call(task, ...)` - Calls a Zake task, captures `@` output
- `$(command)` - Shell substitution during variable expansion (deferred)

#### 5.4.5 Standard Library (Phase 2)

Call built-in cross-platform functions with `zake::` prefix.

**Syntax:**
```makefile
zake::namespace.function("arg1", "arg2")
```

**Variable Resolution:**
Standard library functions support both quoted and unquoted arguments:
- **Quoted strings** - `zake::json.get("{\"name\":\"Alice\"}", "name")`
- **Unquoted variables** - `zake::json.get(json_data, key_name)` where variables are resolved

**Example:**
```makefile
process-data:
    script:
        let json_data = {"name":"Bob","age":"25"}
        let key = name
        
        # Both work:
        let name1 = zake::json.get(json_data, key)        # Unquoted variables
        let name2 = zake::json.get(json_data, "name")     # Quoted literal
        
        echo "Name: {{name1}}"
```

**Available Functions:**

**File System (`zake::fs`)**
```makefile
zake::fs.mkdir("dist")              # Create directory
zake::fs.remove("dist")             # Remove file or directory
zake::fs.copy("src", "dest")        # Copy file or directory
zake::fs.exists("file.txt")         # Check if exists (returns bool)
zake::fs.write("file.txt", "data")  # Write to file
zake::fs.read("file.txt")           # Read file contents
```

**Logging (`zake::log`)**
```makefile
zake::log.info("Building...")       # Blue info message
zake::log.success("Done!")          # Green success message
zake::log.warn("Deprecated")        # Yellow warning
zake::log.error("Failed")           # Red error message
```

**Path (`zake::path`)**
```makefile
let joined = zake::path.join("dist", "{{target}}.wasm")
let basename = zake::path.basename("/path/to/file.txt")  # -> file.txt
let dirname = zake::path.dirname("/path/to/file.txt")    # -> /path/to
let extension = zake::path.ext("/path/to/file.txt")      # -> .txt
let suffix = zake::path.last("2")                        # -> last 2 components from pwd
let suffix2 = zake::path.last("/a/b/c/d", "2")           # -> c/d
```

**String (`zake::str`)**
```makefile
let upper = zake::str.upper("hello")                 # -> HELLO
let lower = zake::str.lower("WORLD")                 # -> world
let replaced = zake::str.replace("a-b-c", "-", "_")  # -> a_b_c
let trimmed = zake::str.trim("  hello  ")            # -> hello
let has = zake::str.contains("hello world", "world") # -> true
```

**System (`zake::sys`)**
```makefile
let current_dir = zake::sys.pwd()                    # -> /Users/name/project

# Example: Auto-detect component from current directory
let comp = {{component}} || zake::path.last("2")     # Use arg or auto-detect from pwd
```

**Example:**
```makefile
build:
    arg: <target> [string] "Target to build"
    script:
        zake::log.info("Building {{target}}...")

        let output_dir = zake::path.join("dist", "{{target}}")
        zake::fs.mkdir("{{output_dir}}")

        go build -o {{output_dir}}/app ./cmd/{{target}}

        zake::log.success("Built {{target}}")
```

### 5.5 Error Suppression (Phase 2)

Prefix any command with `?` to ignore failures.

**Syntax:**
```makefile
?command-that-might-fail
```

**Example:**
```makefile
clean:
    script:
        ?zake::fs.remove("dist")
        ?rm -rf tmp/
        echo "Cleanup complete"
```

**Rules:**
- Without `?`, failed commands abort the task
- With `?`, execution continues regardless of exit code
- Can prefix shell commands, `run`, `let`, or `zake::` calls

### 5.6 Explicit Shell Prefix

If a shell command name conflicts with Zake keywords, use `$` prefix.

**Syntax:**
```makefile
$ shell-command args
```

**Example:**
```makefile
script:
    $ ./run  # Explicit shell command (not 'run task-name')
```

---

## 6. Global Directives

These appear at the top of the Zakefile, outside any task definition.

### 6.1 Global Variables (Phase 2)

Define read-only variables available to all tasks.

**Syntax:**
```makefile
vars:
    VARIABLE_NAME: "value"
    ANOTHER_VAR: "value"
```

**Example:**
```makefile
vars:
    APP_NAME: "my-app"
    VERSION: "1.0.0"
    BUILD_DIR: "dist"

build:
    script:
        echo "Building {{APP_NAME}} v{{VERSION}}"
        mkdir -p {{BUILD_DIR}}
```

**Rules:**
- Must appear before any task definitions
- Variables are immutable
- Available in all tasks as `{{VARIABLE_NAME}}`
- Cannot reference other variables in values

### 6.2 Imports (Phase 4)

Import tasks from other Zakefiles.

**Syntax:**
```makefile
import: "path/to/other.zake"
import: "./tasks/*.zake"  # Glob pattern
```

**Example:**
```makefile
import: "./tasks/docker.zake"
import: "./tasks/testing.zake"

deploy:
    requires: docker.build test.all
    script:
        ./deploy.sh
```

**Rules:**
- Imported files must have `.zake` extension
- Imported tasks keep their full names (no namespacing)
- Name conflicts result in an error
- Circular imports are detected and rejected
- Globs are expanded and processed alphabetically

---

## 7. Command-Line Interface

### 7.1 Task Execution

**Syntax:**
```bash
zake <task-name> [ARGUMENTS...] [FLAGS...]
```

**Examples:**
```bash
# Task with no arguments
zake build

# Task with positional arguments
zake deploy production v2.1.0

# Task with flags
zake build --env=production --verbose=true

# Task with both
zake deploy staging v2.0.0 --region=us-west-2

# Nested tasks (dots create subcommands)
zake secrets view
zake secrets add mykey myvalue --env=prod
```

### 7.2 Help System

**Overview Help:**
```bash
zake          # List all tasks
zake --help   # Same as above
zake -h       # Same as above
```

**Output:**
```
USAGE:
  zake <task> [ARGUMENTS...] [FLAGS...]

AVAILABLE TASKS:
  build              Compile the application
  test               Run all tests
  deploy             Deploy to environment
  secrets.view       View secrets for an environment
  secrets.add        Add or update a secret

Run 'zake <task> --help' for task-specific help.
```

**Task-Specific Help:**
```bash
zake deploy --help
zake deploy -h
```

**Output:**
```
Deploy to environment

USAGE:
  zake deploy [FLAGS] <environment> [version]

ARGUMENTS:
  <environment> [string]    Target environment (dev, staging, prod)
  [version] [string?]       Version to deploy (defaults to latest)

FLAGS:
  -r, --region [string]     AWS region (default: "us-east-1")
  -v, --verbose [string]    Enable verbose output (default: "false")
```

### 7.3 Special Flags (Phase 3+)

**Dry Run:**
```bash
zake deploy production --dry-run
```
Shows what would execute without running commands.

**Print Variables:**
```bash
zake deploy production --print-vars
```
Shows all variable values after substitution.

**Verbose:**
```bash
zake build --zake-verbose
```
Shows detailed execution trace (dependency resolution, task timing).

### 7.4 Shell Completion (Phase 4)

Generate completion scripts:
```bash
zake --completion bash > /etc/bash_completion.d/zake
zake --completion zsh > ~/.zsh/completion/_zake
zake --completion fish > ~/.config/fish/completions/zake.fish
```

---

## 8. Cross-Platform Shell Execution

### 8.1 Shell Selection

Zake automatically selects the appropriate shell based on the operating system:

| OS | Shell | Command Format |
|----|-------|----------------|
| Linux/macOS | `sh` | `sh -c "command"` |
| Windows | `cmd.exe` | `cmd.exe /C "command"` |

### 8.2 Portability Guidelines

For maximum portability, prefer:

1. **Zake standard library** over shell commands
2. **Simple commands** over complex shell syntax
3. **Explicit tool invocations** over shell builtins

**Portable:**
```makefile
clean:
    script:
        zake::fs.remove("dist")
        zake::log.info("Cleaned")
```

**Less Portable:**
```makefile
clean:
    script:
        rm -rf dist 2>/dev/null || true
        echo "Cleaned"
```

### 8.3 Platform-Specific Tasks

Use `when:` to create platform-specific tasks:

```makefile
build-linux:
    when: ${OS} == "linux"
    script:
        GOOS=linux go build

build-windows:
    when: ${OS} == "windows"
    script:
        GOOS=windows go build
```

---

## 9. Error Handling

### 9.1 Error Messages

Zake provides clear, actionable error messages:

**Zakefile not found:**
```
Error: Zakefile not found in current directory.

Run 'zake init' to create a new Zakefile.
```

**Task not found:**
```
Error: Task 'biuld' not found. Did you mean 'build'?

Run 'zake' to see available tasks.
```

**Missing required argument:**
```
Error: Missing required argument '<environment>' for task 'deploy'.

Usage: zake deploy <environment> [version]
```

**Unknown flag:**
```
Error: Unknown flag '--verbose' for task 'deploy'.

Available flags:
  --region, -r    AWS region
  --env, -e       Environment

Run 'zake deploy --help' for more information.
```

**Circular dependency:**
```
Error: Circular dependency detected: build -> test -> build

Task dependency chain:
  build requires: test
  test requires: build
```

**Failed task:**
```
Error: Task 'test' failed with exit code 1.

Command that failed:
  go test ./...

Run with '--zake-verbose' for detailed output.
```

### 9.2 Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Task execution failed |
| 2 | Zakefile syntax error |
| 3 | Task not found |
| 4 | Missing required argument |
| 5 | Circular dependency |
| 10 | Zakefile not found |

---

## 10. Complete Examples

### 10.1 Simple Project

```makefile
vars:
    APP_NAME: "hello-world"

## Build the application
build:
    script:
        go build -o bin/{{APP_NAME}}
        zake::log.success("Build complete")

## Run tests
test:
    script:
        go test ./...

## Clean build artifacts
clean:
    script:
        zake::fs.remove("bin")
        zake::log.info("Cleaned")
```

### 10.2 Multi-Environment Deployment

```makefile
vars:
    APP_NAME: "api-server"
    BUILD_DIR: "dist"

## Lint the codebase
lint:
    script:
        golangci-lint run

## Run all tests
test:
    script:
        @go test -v ./...

## Build the application
build:
    requires: test lint
    script:
        let timestamp = $(date +%s)
        let output = {{BUILD_DIR}}/{{APP_NAME}}-{{timestamp}}

        zake::log.info("Building {{APP_NAME}}...")
        zake::fs.mkdir("{{BUILD_DIR}}")

        go build -o {{output}} ./cmd/api

        zake::log.success("Built: {{output}}")

## Deploy to environment
deploy:
    requires: build
    arg: <environment> [string] "Target environment"
    flag: --region|-r [string="us-east-1"] "AWS region"
    when: {{environment}} == "staging" || {{environment}} == "production"
    script:
        zake::log.warn("Deploying to {{environment}} in {{region}}")

        @aws deploy push \
            --application-name {{APP_NAME}} \
            --s3-location s3://deploys/{{environment}}/latest.zip \
            --region {{region}}

        zake::log.success("Deployment complete")
```

### 10.3 Monorepo with Matrix Builds

```makefile
vars:
    VERSION: "1.0.0"

## Build a specific service
build-service:
    arg: <service> [string] "Service name"
    arg: <arch> [string?] "Target architecture"
    script:
        let arch_flag = {{arch}}
        let output = dist/{{service}}/bin

        zake::log.info("Building {{service}} for {{arch}}...")
        zake::fs.mkdir("{{output}}")

        GOARCH={{arch}} go build -o {{output}}/{{service}} ./services/{{service}}

## Build all services for all architectures
build-all:
    matrix: ["api", "worker", "importer"]
    script:
        run build-service {{item}} amd64
        run build-service {{item}} arm64

## Run service tests
test-service:
    arg: <service> [string] "Service to test"
    script:
        @go test ./services/{{service}}/...

## Run all tests
test-all:
    matrix: ["api", "worker", "importer"]
    script:
        run test-service {{item}}

## Deploy everything
deploy-all:
    requires: test-all build-all
    arg: <environment> [string] "Environment"
    script:
        zake::log.info("Deploying all services to {{environment}}")
        @./scripts/deploy-all.sh {{environment}}
```

### 10.4 Secrets Management

```makefile
## Initialize secrets vault
secrets.init:
    script:
        zake::log.info("Initializing secrets...")
        @./scripts/secrets.sh init
        zake::log.success("Secrets initialized")

## View secrets for environment
secrets.view:
    flag: --env|-e [string="dev"] "Environment"
    script:
        @./scripts/secrets.sh view {{env}}

## Add or update a secret
secrets.add:
    arg: <key> [string] "Secret name"
    arg: <value> [string?] "Secret value (or leave empty to prompt)"
    flag: --env|-e [string="dev"] "Environment"
    script:
        let value_arg = {{value}}

        @
            if [ -z "{{value_arg}}" ]; then
                ./scripts/secrets.sh add {{env}} {{key}}
            else
                ./scripts/secrets.sh add {{env}} {{key}} "{{value_arg}}"
            fi

        zake::log.success("Secret '{{key}}' updated in {{env}}")

## Remove a secret
secrets.remove:
    arg: <key> [string] "Secret name to remove"
    flag: --env|-e [string="dev"] "Environment"
    script:
        @./scripts/secrets.sh remove {{env}} {{key}}
        zake::log.info("Removed secret '{{key}}' from {{env}}")
```

---

## 11. Implementation Notes

### 11.1 Language and Dependencies

- **Implementation Language:** Zig
- **Dependencies:** None (Zig standard library only)
- **Build:** Single static binary
- **Target Platforms:** Linux (x64, ARM), macOS (Intel, Apple Silicon), Windows (x64)

### 11.2 Core Architecture

**Phase 1 - Parser:**
1. Locate and read `Zakefile`
2. Parse into AST (Abstract Syntax Tree)
3. Validate syntax and semantics
4. Build task registry

**Phase 2 - Resolver:**
1. Parse command-line arguments
2. Find requested task
3. Resolve dependencies (if `requires:`)
4. Check conditions (if `when:`)
5. Build execution plan

**Phase 3 - Executor:**
1. For each task in execution plan:
   - Collect argument/flag values
   - Build variable map
   - Substitute variables in script
   - Execute commands sequentially
   - Handle errors

### 11.3 Data Structures

```zig
const Task = struct {
    name: []const u8,
    description: ?[]const u8,
    arguments: ArrayList(Argument),
    flags: ArrayList(Flag),
    requires: ArrayList([]const u8),      // Phase 3
    when_condition: ?Condition,            // Phase 3
    aliases: ArrayList([]const u8),        // Phase 4
    matrix: ?ArrayList([]const u8),        // Phase 4
    script_lines: ArrayList(ScriptLine),
};

const Argument = struct {
    name: []const u8,
    is_optional: bool,
    description: ?[]const u8,
};

const Flag = struct {
    long_name: []const u8,
    short_name: ?u8,
    default_value: []const u8,
    description: ?[]const u8,
};

const ScriptLine = union(enum) {
    Shell: struct { command: []const u8, silent: bool },
    Let: struct { name: []const u8, value: []const u8 },
    Run: struct { task: []const u8, args: [][]const u8 },
    StdLib: struct { call: []const u8 },
};
```

### 11.4 Performance Targets

- Startup time: < 50ms
- Parse time (typical Zakefile): < 10ms
- Memory usage: < 10MB
- Binary size: < 2MB (compressed)

### 11.5 Testing Strategy

- **Unit tests:** All parsers, resolvers, and core logic
- **Integration tests:** End-to-end task execution
- **Cross-platform tests:** Linux, macOS, Windows
- **Error case tests:** All error messages
- **Performance tests:** Startup and parse time
- **Target coverage:** 90%+

---

## 12. Future Considerations

### 12.1 Roadmap Ideas

**Phase 5 - Caching:**
- Task output caching
- Skip tasks if inputs unchanged
- Content-addressable cache

**Phase 6 - Parallel Execution:**
- Parallel matrix iterations
- Parallel independent tasks
- Job pool management

**Phase 7 - Remote Execution:**
- Execute tasks on remote machines
- Distributed builds
- Cloud runners

**Phase 8 - Enhanced Type System:**
- `[int]`, `[bool]`, `[path]` types
- Type validation
- Type coercion

**Phase 9 - Plugins:**
- User-defined functions
- Plugin system
- WASM-based extensions

### 12.2 Non-Goals

These are explicitly **not** planned:

- Build artifact tracking (use dedicated build systems)
- Package management
- Language-specific features
- GUI interface
- Cloud service integrations (should be done via scripts)

---

## 13. Migration from Make

### 13.1 Syntax Comparison

| Make | Zake |
|------|------|
| `target: dependencies` | `task:\n    requires: dependencies` |
| `@command` | `@command` (same) |
| `$(shell cmd)` | `$(cmd)` |
| `$(VAR)` | `{{VAR}}` (Zake) or `${VAR}` (env) |
| `.PHONY: target` | Not needed (all tasks are phony) |
| `target: ; command` | Not supported (use `script:` block) |

### 13.2 Migration Example

**Makefile:**
```makefile
APP_NAME = my-app

.PHONY: build test deploy

build: test
	@echo "Building $(APP_NAME)"
	go build -o bin/$(APP_NAME)

test:
	go test ./...

deploy: build
	@./deploy.sh $(ENV)
```

**Zakefile:**
```makefile
vars:
    APP_NAME: "my-app"

test:
    script:
        go test ./...

build:
    requires: test
    script:
        @echo "Building {{APP_NAME}}"
        go build -o bin/{{APP_NAME}}

deploy:
    requires: build
    flag: --env|-e [string="dev"] "Environment"
    script:
        @./deploy.sh {{env}}
```

---

## 14. Frequently Asked Questions

**Q: Why not just use Make?**
A: Make has cryptic syntax, poor error messages, platform inconsistencies, and was designed for C compilation, not modern workflows.

**Q: How is this different from Just/Task/Mage?**
A: Zake combines the best aspects: Just's simplicity, Task's structured YAML approach (but simpler), and Make's familiarity.

**Q: Can I use Zake in CI/CD?**
A: Yes! That's a primary use case. Single binary, clear output, proper exit codes.

**Q: Do I need to learn Zig to use Zake?**
A: No! Zake is implemented in Zig, but users only write Zakefiles (simple declarative syntax).

**Q: Does it work with monorepos?**
A: Yes! Use `import:` to organize tasks across multiple files, and `matrix:` for repetitive builds.

**Q: Can I call Zake tasks from Zake tasks?**
A: Yes! Use `run task-name` in your script.

**Q: What about Windows?**
A: Zake uses `cmd.exe` on Windows automatically. The standard library abstracts platform differences.

---

## Appendix A: Grammar (EBNF)

```ebnf
Zakefile       = { GlobalDirective | Task } ;

GlobalDirective = VarsDirective | ImportDirective ;
VarsDirective   = "vars:" { INDENT Variable } ;
ImportDirective = "import:" STRING ;

Variable       = IDENTIFIER ":" STRING ;

Task           = [ HelpText ] TaskName ":" { TaskDirective | ScriptBlock } ;
TaskName       = IDENTIFIER ;
HelpText       = "##" TEXT ;

TaskDirective  = ArgDirective | FlagDirective | RequiresDirective
               | WhenDirective | AliasDirective | MatrixDirective ;

ArgDirective   = "arg:" "<" IDENTIFIER ">" "[" Type [ "?" ] "]" STRING ;
FlagDirective  = "flag:" "--" IDENTIFIER [ "|" "-" CHAR ] "[" Type ( "=" STRING | "?" ) "]" STRING ;
RequiresDirective = "requires:" { IDENTIFIER } ;
WhenDirective  = "when:" Expression ;
AliasDirective = "alias:" { IDENTIFIER } ;
MatrixDirective = "matrix:" "[" STRING { "," STRING } "]" ;

ScriptBlock    = "script:" { INDENT ScriptLine } ;
ScriptLine     = ShellCommand | LetStatement | RunStatement | StdLibCall ;

ShellCommand   = [ "@" | "$" | "?" ] TEXT ;
LetStatement   = "let" IDENTIFIER "=" Expression ;
RunStatement   = "run" IDENTIFIER { TEXT } ;
StdLibCall     = "zake::" IDENTIFIER "." IDENTIFIER "(" [ Args ] ")" ;

Type           = "string" ;  (* Future: int, bool, path *)

Expression     = Variable | EnvVar | ShellSub | STRING ;
Variable       = "{{" IDENTIFIER "}}" ;
EnvVar         = "${" IDENTIFIER "}" ;
ShellSub       = "$(" TEXT ")" ;
```

---

## Appendix B: Reserved Keywords

The following keywords are reserved and cannot be used as task names:

- `vars`
- `import`
- `arg`
- `flag`
- `requires`
- `when`
- `alias`
- `matrix`
- `script`
- `let`
- `run`

Task names starting with `zake::` are also reserved for the standard library.

---

## Appendix C: Color Scheme

Default terminal colors for output:

| Context | Color | ANSI Code |
|---------|-------|-----------|
| Task name | Cyan | `\x1b[36m` |
| Success | Green | `\x1b[32m` |
| Warning | Yellow | `\x1b[33m` |
| Error | Red | `\x1b[31m` |
| Info | Blue | `\x1b[34m` |
| Command echo | Gray | `\x1b[90m` |
| Reset | - | `\x1b[0m` |

---

**End of Specification**
