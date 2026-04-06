/// TUI entry points.
///
/// openCommands — launched by main when `mm` is invoked with no args on a TTY.
/// openHistory  — launched by main when `mm -H` is invoked with no args on a TTY.
///
/// Both functions return the command string to eval (gpa-owned), or null if the
/// user quit without selecting anything. The caller writes the result to stdout.
/// Pressing Tab in either view switches to the other; the toggle loop lives here.
const std = @import("std");
const core = @import("../core/mod.zig");
const commands = @import("commands.zig");
const history = @import("history.zig");

pub fn openCommands(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
) !?[]u8 {
    return runWithToggle(io, gpa, db, env, .commands);
}

pub fn openHistory(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
) !?[]u8 {
    return runWithToggle(io, gpa, db, env, .history);
}

const View = enum { commands, history };

fn runWithToggle(
    io: std.Io,
    gpa: std.mem.Allocator,
    db: *core.Db,
    env: *const std.process.Environ.Map,
    start: View,
) !?[]u8 {
    var view = start;
    while (true) {
        var want_switch = false;
        const cmd = switch (view) {
            .commands => try commands.Browser.run(gpa, db, env, &want_switch),
            .history  => try history.Browser.run(gpa, io, db, env, &want_switch),
        };
        if (!want_switch) return cmd;
        view = switch (view) {
            .commands => .history,
            .history  => .commands,
        };
    }
}
