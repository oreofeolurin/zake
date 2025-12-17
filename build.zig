const std = @import("std");

pub fn build(b: *std.Build) void {
    // Target and optimization options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "zake",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Install the executable
    b.installArtifact(exe);

    // Create 'run' step for easy testing
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing arguments to the run command
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the zake CLI");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Install to system PATH
    // Default: /opt/homebrew/bin (Homebrew's bin directory, already in PATH on macOS)
    // Override: zig build install-system -Dinstall_dir=~/.local/bin
    const install_dir_option = b.option([]const u8, "install_dir", "Directory to install zake binary");
    const default_install_dir = "/opt/homebrew/bin";
    const install_dir = install_dir_option orelse default_install_dir;

    const system_install_step = b.step("install-system", "Install zake to system PATH directory");

    // Create install directory and copy binary
    const install_cmd = b.addSystemCommand(&.{ "sh", "-c" });
    const build_root_str = b.pathFromRoot("zig-out/bin/zake");
    const install_script = std.fmt.allocPrint(b.allocator,
        \\mkdir -p "{s}" && cp "{s}" "{s}/zake" && chmod +x "{s}/zake" && echo "✓ Installed zake to {s}/zake"
    , .{ install_dir, build_root_str, install_dir, install_dir, install_dir }) catch unreachable;
    install_cmd.addArg(install_script);
    install_cmd.step.dependOn(b.getInstallStep());
    system_install_step.dependOn(&install_cmd.step);
}
