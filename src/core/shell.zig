/// Shell detection, wrapper text generation, and history file paths.
const std = @import("std");
const builtin = @import("builtin");

pub const Shell = enum {
    bash,
    zsh,
    fish,
    powershell,

    pub fn fromStr(s: []const u8) ?Shell {
        if (std.mem.eql(u8, s, "bash")) return .bash;
        if (std.mem.eql(u8, s, "zsh")) return .zsh;
        if (std.mem.eql(u8, s, "fish")) return .fish;
        if (std.mem.eql(u8, s, "powershell")) return .powershell;
        if (std.mem.eql(u8, s, "pwsh")) return .powershell;
        return null;
    }

    pub fn toStr(shell: Shell) []const u8 {
        return switch (shell) {
            .bash => "bash",
            .zsh => "zsh",
            .fish => "fish",
            .powershell => "powershell",
        };
    }
};

/// Detect the current shell from the environment.
/// On Windows, SHELL is not set; PowerShell is detected via PSModulePath.
/// Returns null if no known shell is detected.
pub fn detectShell(environ_map: *const std.process.Environ.Map) ?Shell {
    if (builtin.os.tag == .windows) {
        if (environ_map.get("PSModulePath") != null) return .powershell;
        return null;
    }
    const shell_var = environ_map.get("SHELL") orelse return null;
    const basename = std.fs.path.basename(shell_var);
    return Shell.fromStr(basename);
}

/// Returns true if a command scoped to `cmd_scope` can run in `current_shell`.
pub fn isCompatible(cmd_scope: []const u8, current_shell: Shell) bool {
    if (std.mem.eql(u8, cmd_scope, "universal")) return true;
    const shell_str = current_shell.toStr();
    return std.mem.eql(u8, cmd_scope, shell_str);
}

// ── Wrapper text ──────────────────────────────────────────────────────────────

pub const MARKER_BEGIN = "# mm-memento-begin";
pub const MARKER_END = "# mm-memento-end";

/// Generate the complete wrapper snippet for `shell` installing a function
/// named `fn_name` that delegates to the `memento` binary.
/// For bash/zsh/PowerShell the snippet includes marker comments so it can be
/// detected and replaced without shell-specific logic.
/// Caller owns the returned string.
pub fn wrapperSnippet(gpa: std.mem.Allocator, shell: Shell, fn_name: []const u8) ![]u8 {
    return switch (shell) {
        .bash, .zsh => std.fmt.allocPrint(gpa,
            \\
            \\# mm-memento-begin
            \\function {s}() {{
            \\    eval "$(command memento "$@")"
            \\}}
            \\# mm-memento-end
            \\
        , .{fn_name}),
        .powershell => std.fmt.allocPrint(gpa,
            "\n" ++ MARKER_BEGIN ++ "\n" ++
            "function {s} {{\n" ++
            "    Invoke-Expression (& (Get-Command memento -CommandType Application).Source @args)\n" ++
            "}}\n" ++
            MARKER_END ++ "\n",
            .{fn_name},
        ),
        // Fish uses a dedicated functions file; no markers needed.
        .fish => std.fmt.allocPrint(gpa,
            \\function {s}
            \\    eval (command memento $argv)
            \\end
            \\
        , .{fn_name}),
    };
}

/// Returns the absolute path to the fish wrapper file for the given function name.
/// Caller owns the returned string.
pub fn fishWrapperPath(gpa: std.mem.Allocator, home: []const u8, fn_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/.config/fish/functions/{s}.fish", .{ home, fn_name });
}

/// Returns the rc file path relative to HOME for bash/zsh/powershell.
pub fn rcFileRel(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => ".bashrc",
        .zsh => ".zshrc",
        .powershell => ".config/powershell/Microsoft.PowerShell_profile.ps1",
        .fish => unreachable, // fish uses a separate file
    };
}

// ── History file paths ────────────────────────────────────────────────────────

/// Returns the history file path relative to HOME (or as an absolute path from
/// the env var) for the given shell. Caller owns the result.
pub fn historyFilePath(
    gpa: std.mem.Allocator,
    shell: Shell,
    environ_map: *const std.process.Environ.Map,
    home: []const u8,
) !?[]u8 {
    return switch (shell) {
        .bash => blk: {
            if (environ_map.get("HISTFILE")) |hf| break :blk try gpa.dupe(u8, hf);
            break :blk try std.fs.path.join(gpa, &.{ home, ".bash_history" });
        },
        .zsh => blk: {
            if (environ_map.get("HISTFILE")) |hf| break :blk try gpa.dupe(u8, hf);
            break :blk try std.fs.path.join(gpa, &.{ home, ".zsh_history" });
        },
        .fish => try std.fs.path.join(gpa, &.{ home, ".local", "share", "fish", "fish_history" }),
        .powershell => null, // PSReadLine path varies; skip for now
    };
}
