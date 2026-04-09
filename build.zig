const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Main executable ──────────────────────────────────────────────────────

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Compile the SQLite amalgamation directly into the binary.
    // No system sqlite3 package required.
    exe_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=0",       // single-threaded; no mutex overhead
            "-DSQLITE_DEFAULT_MEMSTATUS=0", // disable memory usage tracking
            "-DSQLITE_OMIT_LOAD_EXTENSION", // no dlopen/extension loading
        },
    });
    exe_mod.addIncludePath(b.path("vendor/sqlite3"));

    // MM_DB env-var override is compiled in only for Debug builds.
    // Release binaries ignore it entirely — the code path is dead-eliminated.
    const is_debug = optimize == .Debug;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "enable_mm_db_override", is_debug);
    // Keep this in sync with the version field in build.zig.zon.
    build_opts.addOption([]const u8, "version", "0.1.0");
    exe_mod.addOptions("build_options", build_opts);

    const exe = b.addExecutable(.{
        .name = "memento",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run mm");
    run_step.dependOn(&run_cmd.step);

    // ── Dev run ──────────────────────────────────────────────────────────────
    //
    // `zig build dev` is identical to `zig build run` but points MM_DB at a
    // throwaway database in the build cache so it never touches the production
    // store.  Useful when dogfooding changes during development.
    //
    //   zig build dev -- -a build 'cargo build --release'
    //   zig build dev -- -l
    //   zig build dev -- build
    //
    const dev_cmd = b.addRunArtifact(exe);
    dev_cmd.step.dependOn(b.getInstallStep());
    dev_cmd.setEnvironmentVariable("MM_DB", b.cache_root.join(b.allocator, &.{"mm-dev.sqlite"}) catch "mm-dev.sqlite");
    if (b.args) |args| dev_cmd.addArgs(args);
    const dev_step = b.step("dev", "Run mm against an isolated dev database");
    dev_step.dependOn(&dev_cmd.step);

    // ── Integration tests ────────────────────────────────────────────────────
    //
    // Each feature file maps to a test module. All test modules share
    // build_options (which carries the path to the installed mm binary) and
    // a helper module with common test utilities.
    //
    // Tests depend on mm being installed first so the binary exists when the
    // tests spawn it as a subprocess.

    const test_step = b.step("test", "Run all integration tests");

    const helper_mod = b.createModule(.{
        .root_source_file = b.path("tests/helper.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build options: bake the installed binary path into every test module.
    const opts = b.addOptions();
    opts.addOption([]const u8, "mm_exe", b.getInstallPath(.bin, "memento"));

    const feature_tests = [_][]const u8{
        "tests/01_setup_test.zig",
        "tests/02_add_test.zig",
        "tests/03_list_test.zig",
        "tests/04_execute_test.zig",
        "tests/05_templates_test.zig",
        "tests/06_edit_delete_test.zig",
        "tests/07_history_test.zig",
    };

    inline for (feature_tests) |test_file| {
        const mod = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        mod.addOptions("build_options", opts);
        mod.addImport("helper", helper_mod);

        const t = b.addTest(.{ .root_module = mod });
        t.step.dependOn(b.getInstallStep());

        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ── Fuzz tests ───────────────────────────────────────────────────────────
    //
    // Seed / regression run (completes):     zig build fuzz
    // Continuous fuzzing (runs until crash):  zig build fuzz -- --fuzz
    // Replay a specific crash file:           zig build fuzz -- path/to/crash
    //
    // Source modules are registered by name so fuzz_test.zig can @import
    // them without crossing module-root boundaries.
    {
        const fuzz_step = b.step("fuzz", "Run fuzz tests (append -- --fuzz for continuous mode)");

        // Each module's root file brings its sibling @imports along
        // automatically (they resolve relative to the source file location).
        const cli_mod = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
        });
        const template_mod = b.createModule(.{
            .root_source_file = b.path("src/core/template.zig"),
            .target = target,
            .optimize = optimize,
        });
        const history_mod = b.createModule(.{
            .root_source_file = b.path("src/core/history.zig"),
            .target = target,
            .optimize = optimize,
        });

        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path("tests/fuzz_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        fuzz_mod.addImport("cli",      cli_mod);
        fuzz_mod.addImport("template", template_mod);
        fuzz_mod.addImport("history",  history_mod);

        const fuzz_t = b.addTest(.{ .root_module = fuzz_mod });
        const run_fuzz = b.addRunArtifact(fuzz_t);
        if (b.args) |args| run_fuzz.addArgs(args);
        fuzz_step.dependOn(&run_fuzz.step);
    }

    // TUI tests require libc for PTY operations (fork, execve, grantpt, etc.)
    // PTY APIs are POSIX-only; skip on Windows targets.
    if (target.result.os.tag != .windows) {
        const mod = b.createModule(.{
            .root_source_file = b.path("tests/08_tui_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        mod.addOptions("build_options", opts);
        mod.addImport("helper", helper_mod);

        const t = b.addTest(.{ .root_module = mod });
        t.step.dependOn(b.getInstallStep());

        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }
}
