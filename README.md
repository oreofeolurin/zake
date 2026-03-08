# Zake

> A modern, language-agnostic task runner designed to replace `make`

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Built with Zig](https://img.shields.io/badge/Built%20with-Zig-orange.svg)](https://ziglang.org/)

## Why Zake?

Traditional `make` was designed for C compilation in the 1970s. Modern projects need a task runner that's:

- **Simple** - Intuitive syntax anyone can learn in 5 minutes
- **Capable** - Three variable systems, cross-platform shell execution, auto-generated help
- **Zero Dependencies** - Single static binary, no runtime required
- **Language Agnostic** - Works with Go, Rust, Python, TypeScript, or whatever you use
- **Self-Documenting** - Help text is part of the task definition

## Features

- ✅ **Declarative task syntax** - Define tasks with arguments, flags, and descriptions
- ✅ **Three variable systems** - `{{zake}}`, `${env}`, `$(shell)` with clear separation of concerns
- ✅ **Auto-generated CLI** - Subcommands, flags, and help text derived from your Zakefile
- ✅ **Cross-platform** - Works identically on Linux, macOS, and Windows
- ✅ **Colorized output** - ANSI-colored terminal output with command echoing
- ✅ **Optional arguments** - Define required and optional arguments for tasks
- ✅ **Flag support** - Long (`--env`) and short (`-e`) flags with default values
- ✅ **Subcommands** - Create `zake secrets view` from `secrets.view:` tasks
- ✅ **Task dependencies** - `requires: task1 task2` for execution order
- ✅ **Conditional execution** - `when: ${CI} == "true"` to skip tasks
- ✅ **Matrix execution** - Run tasks across multiple configurations
- ✅ **Standard library** - Cross-platform `zake::fs`, `zake::log`, `zake::path`, `zake::str`
- ✅ **Import system** - Modular Zakefiles with `import "path"`
- ✅ **Platform targeting** - `arch: linux|macos|windows` for OS-specific tasks
- ✅ **Recursive Discovery** - Runs from any subdirectory, automatically finding the Zakefile in parent directories

## Quick Start

### Installation

#### From Source (Zig 0.15.1+)

```bash
git clone https://github.com/oreofeolurin/zake.git
cd zake
zig build install-system
```

#### Homebrew (coming soon)

```bash
brew install zake
```

### Your First Zakefile

Create a file named `Zakefile` in your project root:

```makefile
## Build the project
build:
    script:
        echo "Building..."
        go build -o bin/app

## Run tests
test:
    script:
        go test ./...

## Deploy to environment
deploy:
    arg: <environment> [string] "Target environment (dev, staging, prod)"
    flag: --region|-r [string="us-east-1"] "AWS region"
    script:
        echo "Deploying to {{environment}} in {{region}}"
        ./deploy.sh {{environment}} {{region}}
```

### Run Your Tasks

```bash
# List all available tasks
zake

# Get help for a specific task
zake deploy --help

# Run tasks
zake build
zake test
zake deploy production --region=us-west-2
```

### Run From Anywhere

You can run `zake` from any subdirectory in your project. It will automatically walk up the directory tree until it finds a `Zakefile`.

## Example Zakefile

Here's a more complete example showcasing Zake's features:

```makefile
## Build the application
build:
    arg: <target> [string] "Build target (api, worker, web)"
    flag: --release|-r [string="false"] "Build in release mode"
    script:
        let timestamp = $(date +%s)
        let output = dist/{{target}}-{{timestamp}}

        echo "Building {{target}}..."

        @if [ "{{release}}" = "true" ]; then
            go build -ldflags="-s -w" -o {{output}}
        else
            go build -o {{output}}
        fi

        echo "Built: {{output}}"

## Run development server
dev:
    flag: --port|-p [string="3000"] "Port to listen on"
    script:
        echo "Starting server on port {{port}}"
        echo "User: ${USER}"
        go run main.go --port={{port}}

## Deploy to cloud
deploy:
    arg: <environment> [string] "Environment to deploy to"
    arg: <version> [string?] "Version to deploy (optional)"
    flag: --region|-r [string="us-east-1"] "Cloud region"
    script:
        @echo "Deploying to {{environment}}"
        @./scripts/deploy.sh {{environment}} {{version}} {{region}}
```

## Variable System

Zake provides three types of variables, each with a distinct syntax:

### Zake Variables `{{var}}`
Variables from task arguments, flags, and local definitions:

```makefile
deploy:
    arg: <env> [string] "Environment"
    flag: --region|-r [string="us-east-1"] "Region"
    script:
        echo "Deploying to {{env}} in {{region}}"
```

### Environment Variables `${VAR}`
Access system environment variables:

```makefile
info:
    script:
        echo "User: ${USER}"
        echo "Home: ${HOME}"
        echo "CI: ${CI}"
```

### Shell Command Substitution `$(command)`
Capture shell command output:

```makefile
version:
    script:
        let commit = $(git rev-parse --short HEAD)
        let branch = $(git branch --show-current)
        echo "Version: {{branch}}-{{commit}}"
```

## Task Definition

### Arguments

Define required or optional positional arguments:

```makefile
deploy:
    arg: <environment> [string] "Target environment"
    arg: <version> [string?] "Version (optional)"
    script:
        echo "Env: {{environment}}, Version: {{version}}"
```

Usage:
```bash
zake deploy production v2.1.0
zake deploy staging  # version is optional
```

### Flags

Define named flags with long and short forms:

```makefile
build:
    flag: --env|-e [string="dev"] "Environment"
    flag: --verbose|-v [string="false"] "Verbose output"
    script:
        echo "Building for {{env}}"
```

Usage:
```bash
zake build --env=production --verbose=true
zake build -e production -v true
zake build  # uses default values
```

### Silent Commands

Prefix commands with `@` to hide the command itself:

```makefile
secrets:
    script:
        @cat .env  # Only shows output, not the command
        echo "Done"  # Shows: $ echo "Done"
```

## Help System

Zake generates help text from your task definitions:

```bash
# Overview help
$ zake

USAGE:
  zake <task> [ARGUMENTS...] [FLAGS...]

AVAILABLE TASKS:
  build       Build the application
  test        Run tests
  deploy      Deploy to environment

Run 'zake <task> --help' for task-specific help.

# Task-specific help
$ zake deploy --help

Deploy to environment

USAGE:
  zake deploy [FLAGS] <environment> [version]

ARGUMENTS:
  <environment> [string]    Target environment
  [version] [string?]       Version (optional)

FLAGS:
  -r, --region [string]     Cloud region (default: "us-east-1")
```

## Cross-Platform Support

Zake picks the right shell for your platform:

- **Linux/macOS**: `sh -c`
- **Windows**: `cmd.exe /C`

No platform-specific configuration needed.

## Building from Source

### Prerequisites

- [Zig](https://ziglang.org/download/) 0.15.1 or later

### Build Commands

```bash
# Build the binary
zig build

# Run tests
zig build test

# Install to system PATH (/opt/homebrew/bin)
zig build install-system

# Install to custom directory
zig build install-system -Dinstall_dir=~/.local/bin

# Run directly
zig build run -- <task> [args...]
```

## Documentation

- [SPEC.md](SPEC.md) - Complete language specification
- [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guidelines

## Roadmap

### Phase 1 (✅ Complete)
- [x] Basic task execution
- [x] Arguments and flags
- [x] Three variable systems
- [x] Help generation
- [x] Cross-platform shell execution

### Phase 1.5 (✅ Complete)
- [x] Platform targeting (`arch: linux|macos|windows`)

### Phase 2 (✅ Complete)
- [x] `let` variables (task-local)
- [x] `run` keyword (invoke other tasks)
- [x] Subcommands (dots in task names)
- [x] Makefile-style variables (`VAR = value`)

### Phase 3 (✅ Complete)
- [x] Task dependencies (`requires:`)
- [x] Conditional execution (`when:`)
- [x] Alias support (`alias: name1 name2`)

### Phase 4 (✅ Complete)
- [x] Standard library (`zake::fs`, `zake::log`, `zake::path`, `zake::str`)
- [x] Matrix execution (`matrix: var=[val1, val2]`)
- [x] Task imports (`import "path"`)
- [x] Error suppression (`?` prefix)
- [x] Explicit shell (`$` prefix)

### Future
- [ ] Shell completion
- [ ] Watch mode
- [ ] Parallel matrix execution

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Inspired by [Make](https://www.gnu.org/software/make/), [Just](https://github.com/casey/just), and [Task](https://taskfile.dev/)
- Built with [Zig](https://ziglang.org/)

## Support

- 🐛 [Report a bug](https://github.com/oreofeolurin/zake/issues)
- 💡 [Request a feature](https://github.com/oreofeolurin/zake/issues)
- 💬 [Join discussions](https://github.com/oreofeolurin/zake/discussions)

---

**Made with ❤️ by the Razorbill team**


