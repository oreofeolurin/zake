# Changelog

All notable changes to Zake will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Standard library: `zake::fs`, `zake::log`, `zake::path`, `zake::str`, `zake::sys`
- Matrix execution (`matrix: var=[val1, val2]`)
- Task imports (`import "path/to/file.zake"`)
- Error suppression with `?` prefix
- Explicit shell prefix `$` for keyword conflicts
- Task dependencies (`requires: task1 task2`)
- Conditional execution (`when: expression`)
- Task aliases (`alias: short-name`)
- `let` variables (task-local, immutable)
- `run` keyword for invoking tasks from scripts
- `zake::run`, `zake::call`, `zake::exec` for programmatic task invocation
- Subcommands via dot notation (`secrets.view:` → `zake secrets view`)
- Platform targeting with `arch: linux|macos|windows|unix`
- Global variables via `vars:` directive
- Expression operators (`||`, `??`) in `let` statements

## [0.1.0] - 2025-11-16

### Added
- Core Zakefile parser
- Task definition with `script:` blocks
- Task arguments (required and optional with `[type?]`)
- Task flags with long (`--name`) and short (`-n`) forms
- Three variable systems: `{{zake}}`, `${env}`, `$(shell)`
- Auto-generated help (overview and per-task `--help`)
- Cross-platform shell execution (`sh` on Unix, `cmd.exe` on Windows)
- Silent command execution with `@` prefix
- Colorized terminal output
- System installation via `zig build install-system`

[Unreleased]: https://github.com/oreofeolurin/zake/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/oreofeolurin/zake/releases/tag/v0.1.0
