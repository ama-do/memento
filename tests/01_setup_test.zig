/// Feature 01: Installation and Shell Integration Setup
///
/// Tests that `mm --init` / `mm -i` correctly writes shell wrapper functions,
/// detects existing installations, and supports explicit shell / config-file
/// overrides.
const std = @import("std");
const build_options = @import("build_options");
const helper = @import("helper");

const mm_exe = build_options.mm_exe;
const io = std.testing.io;

// ── Happy paths ───────────────────────────────────────────────────────────────

test "mm --init creates the fish wrapper function file" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Fish expects ~/.config/fish/functions/ to exist.
    try ctx.writeHomeFile(".config/fish/functions/.keep", "");

    const r = try ctx.runAs(&.{"--init"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Shell wrapper initialized for fish");

    // The wrapper file must exist.
    try std.testing.expect(try ctx.homeFileExists(".config/fish/functions/mm.fish"));

    // The file must contain the eval wrapper.
    const content = try ctx.readHomeFile(".config/fish/functions/mm.fish");
    defer gpa.free(content);
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "function mm"));
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "eval"));
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "command memento"));
}

test "mm -i short flag works the same as --init" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.writeHomeFile(".config/fish/functions/.keep", "");

    const r = try ctx.runAs(&.{"-i"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try std.testing.expect(try ctx.homeFileExists(".config/fish/functions/mm.fish"));
}

test "mm --init appends bash wrapper to ~/.bashrc with markers" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Pre-create an empty .bashrc.
    try ctx.writeHomeFile(".bashrc", "# existing content\n");

    const r = try ctx.runAs(&.{"--init"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Shell wrapper initialized for bash");
    try r.expectStderr("source ~/.bashrc");

    const bashrc = try ctx.readHomeFile(".bashrc");
    defer gpa.free(bashrc);
    try std.testing.expect(std.mem.containsAtLeast(u8, bashrc, 1, "# mm-memento-begin"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bashrc, 1, "# mm-memento-end"));
    try std.testing.expect(std.mem.containsAtLeast(u8, bashrc, 1, "function mm"));
    // Original content must be preserved.
    try std.testing.expect(std.mem.containsAtLeast(u8, bashrc, 1, "# existing content"));
}

test "mm --init appends zsh wrapper to ~/.zshrc with markers" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.writeHomeFile(".zshrc", "# zsh config\n");

    const r = try ctx.runAs(&.{"--init"}, "zsh");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Shell wrapper initialized for zsh");
    try r.expectStderr("source ~/.zshrc");

    const zshrc = try ctx.readHomeFile(".zshrc");
    defer gpa.free(zshrc);
    try std.testing.expect(std.mem.containsAtLeast(u8, zshrc, 1, "# mm-memento-begin"));
    try std.testing.expect(std.mem.containsAtLeast(u8, zshrc, 1, "function mm"));
}

test "mm --init initialises the SQLite database" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.writeHomeFile(".config/fish/functions/.keep", "");

    const r = try ctx.runAs(&.{"--init"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Database initialized");
}

// ── Already-installed detection ───────────────────────────────────────────────

test "mm --init skips re-installation when fish wrapper already exists" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Simulate a pre-existing wrapper.
    try ctx.writeHomeFile(".config/fish/functions/mm.fish", "function mm\n  eval (command mm $argv)\nend\n");

    const r = try ctx.runAs(&.{"--init"}, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Shell wrapper already initialized for fish");

    // Original content must be unchanged.
    const content = try ctx.readHomeFile(".config/fish/functions/mm.fish");
    defer gpa.free(content);
    try std.testing.expectEqualStrings("function mm\n  eval (command mm $argv)\nend\n", content);
}

test "mm --init skips re-installation when bash marker already present" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const existing =
        "# mm-memento-begin\n" ++
        "function mm() { eval \"$(command mm \"$@\")\"; }\n" ++
        "# mm-memento-end\n";
    try ctx.writeHomeFile(".bashrc", existing);

    const r = try ctx.runAs(&.{"--init"}, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Shell wrapper already initialized for bash");

    const bashrc = try ctx.readHomeFile(".bashrc");
    defer gpa.free(bashrc);
    // Only one copy of the marker should exist.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bashrc, "# mm-memento-begin"));
}

test "mm --init --force overwrites existing fish wrapper" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    try ctx.writeHomeFile(".config/fish/functions/mm.fish", "# old wrapper\n");

    const r = try ctx.runAs(&.{ "--init", "--force" }, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("Shell wrapper reinitialized for fish");

    const content = try ctx.readHomeFile(".config/fish/functions/mm.fish");
    defer gpa.free(content);
    // New content must not contain the old marker.
    try std.testing.expect(!std.mem.containsAtLeast(u8, content, 1, "# old wrapper"));
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "function mm"));
}

// ── Explicit shell / config-file overrides ────────────────────────────────────

test "mm --init --shell zsh installs zsh wrapper when detection fails" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Deliberately set SHELL to something unrecognised.
    try ctx.writeHomeFile(".zshrc", "");

    // Run with --shell override instead of relying on SHELL env.
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", ctx.home_path);
    try env.put("XDG_DATA_HOME", ctx.tmp_path);
    try env.put("SHELL", "/bin/unknown-shell");

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ mm_exe, "--init", "--shell", "zsh" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "initialized for zsh"));
}

test "mm --init --config-file writes wrapper to specified path for bash" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    // Write a non-default file that we'll point at.
    try ctx.writeHomeFile(".bash_profile", "# bash_profile\n");

    const custom_path = try std.fs.path.join(gpa, &.{ ctx.home_path, ".bash_profile" });
    defer gpa.free(custom_path);

    const r = try ctx.runAs(&.{ "--init", "--config-file", custom_path }, "bash");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("initialized for bash");

    const content = try ctx.readHomeFile(".bash_profile");
    defer gpa.free(content);
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "mm-memento-begin"));
}

test "mm --init --config-file writes fish wrapper to specified path" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    const custom_path = try std.fs.path.join(gpa, &.{ ctx.home_path, ".config", "fish", "config.fish" });
    defer gpa.free(custom_path);

    const r = try ctx.runAs(&.{ "--init", "--config-file", custom_path }, "fish");
    defer r.deinit(gpa);

    try r.ok();
    try r.expectStderr("initialized for fish");

    // The wrapper must have been written to the custom path, not the default.
    const content = try ctx.readHomeFile(".config/fish/config.fish");
    defer gpa.free(content);
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "function mm"));
    // Default functions file must NOT have been created.
    const default_exists = try ctx.homeFileExists(".config/fish/functions/mm.fish");
    try std.testing.expect(!default_exists);
}

test "mm --init fails with helpful message when shell cannot be detected" {
    const gpa = std.testing.allocator;
    var ctx = try helper.TestCtx.init(gpa, mm_exe);
    defer ctx.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", ctx.home_path);
    try env.put("XDG_DATA_HOME", ctx.tmp_path);
    // Intentionally omit SHELL.

    const result = try std.process.run(gpa, io, .{
        .argv = &.{ mm_exe, "--init" },
        .environ_map = &env,
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    const exit_code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    try std.testing.expect(exit_code != 0);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "Could not detect current shell"));
    try std.testing.expect(std.mem.containsAtLeast(u8, result.stderr, 1, "--shell"));
}
