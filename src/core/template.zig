/// Template placeholder detection and substitution.
///
/// Placeholders use the {name} syntax. Names must be alphanumeric + underscore.
/// Duplicates are deduplicated; order is first-occurrence.
const std = @import("std");

// ── Extraction ────────────────────────────────────────────────────────────────

/// Return deduplicated placeholder names from `command_str` in first-occurrence
/// order. E.g. "echo {a} {b} {a}" → ["a","b"].
/// Caller owns the returned slice and each name string (freed with gpa).
pub fn extractPlaceholders(gpa: std.mem.Allocator, command_str: []const u8) ![][]u8 {
    var names = std.ArrayList([]u8).empty;
    errdefer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }

    var i: usize = 0;
    while (i < command_str.len) : (i += 1) {
        if (command_str[i] != '{') continue;
        const start = i + 1;
        var end = start;
        while (end < command_str.len and command_str[end] != '}') : (end += 1) {}
        if (end >= command_str.len) break; // unclosed brace — ignore
        const name = command_str[start..end];
        if (name.len == 0) continue;
        if (!isValidName(name)) continue;
        // Skip duplicates.
        if (containsName(names.items, name)) {
            i = end;
            continue;
        }
        try names.append(gpa, try gpa.dupe(u8, name));
        i = end;
    }

    return names.toOwnedSlice(gpa);
}

fn isValidName(s: []const u8) bool {
    for (s) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn containsName(names: []const []u8, target: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, target)) return true;
    }
    return false;
}

// ── CSV encoding / decoding ───────────────────────────────────────────────────

/// Encode a slice of names as a comma-separated string.
/// Returns null if slice is empty. Caller owns the result.
pub fn encodeCsv(gpa: std.mem.Allocator, names: []const []const u8) !?[]u8 {
    if (names.len == 0) return null;
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(gpa);
    for (names, 0..) |n, i| {
        if (i > 0) try buf.append(gpa, ',');
        try buf.appendSlice(gpa, n);
    }
    return @as(?[]u8, try buf.toOwnedSlice(gpa));
}

/// Decode a comma-separated string into a slice of name slices.
/// The returned slices point into `csv` — do not free them individually.
/// Free only the outer slice with `gpa.free(slice)`.
pub fn decodeCsv(gpa: std.mem.Allocator, csv: []const u8) ![][]const u8 {
    if (csv.len == 0) return &.{};
    var parts = std.ArrayList([]const u8).empty;
    errdefer parts.deinit(gpa);
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        if (part.len > 0) try parts.append(gpa, part);
    }
    return parts.toOwnedSlice(gpa);
}

// ── Substitution ──────────────────────────────────────────────────────────────

/// Diagnostic info set by parseArgs on failure.
pub const ParseDiag = struct {
    missing_placeholder: ?[]const u8 = null, // name of the first missing placeholder
    unknown_flag: ?[]const u8 = null, // unrecognized --flag key
    unknown_flag_suggestion: ?[]const u8 = null, // case-insensitive match in placeholders
};

/// Parse `extra_args` (the tokens after the label) into per-placeholder values,
/// given the ordered list of `placeholders`.
///
/// Two forms accepted:
///   positional:  "mm kgp staging" → extra_args=["staging"]
///   named:       "mm kgp --ns staging" → extra_args=["--ns","staging"]
///
/// Named args win over positional when both are present for the same name.
/// On error, `diag` is populated with details for a useful message.
///
/// Caller owns the returned slice (but not the strings — they point into `extra_args`).
pub fn parseArgs(
    gpa: std.mem.Allocator,
    placeholders: []const []const u8,
    extra_args: []const []const u8,
    diag: *ParseDiag,
) ![][]const u8 {
    const values = try gpa.alloc([]const u8, placeholders.len);
    errdefer gpa.free(values);
    @memset(values, "");

    var positional = std.ArrayList([]const u8).empty;
    defer positional.deinit(gpa);

    // Collect named args.
    var i: usize = 0;
    while (i < extra_args.len) : (i += 1) {
        const arg = extra_args[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            const key = arg[2..];
            // Find the placeholder index.
            const idx = indexOfName(placeholders, key) orelse {
                // Unknown flag: check for case-insensitive match to give a good error.
                diag.unknown_flag = key;
                for (placeholders) |ph| {
                    if (std.ascii.eqlIgnoreCase(ph, key)) {
                        diag.unknown_flag_suggestion = ph;
                        break;
                    }
                }
                // Treat as positional so we can continue and find all errors.
                try positional.append(gpa, arg);
                continue;
            };
            i += 1;
            if (i >= extra_args.len) return error.MissingArgValue;
            values[idx] = extra_args[i];
        } else {
            try positional.append(gpa, arg);
        }
    }

    // Fill remaining slots from positionals.
    var pos_idx: usize = 0;
    for (values, 0..) |v, slot| {
        if (v.len == 0) {
            if (pos_idx >= positional.items.len) continue; // will be caught below
            values[slot] = positional.items[pos_idx];
            pos_idx += 1;
        }
    }

    // Check for unused extra positionals.
    if (pos_idx < positional.items.len) return error.TooManyArguments;

    // Check all placeholders are filled.
    for (values, 0..) |v, slot| {
        if (v.len == 0) {
            diag.missing_placeholder = placeholders[slot];
            return error.MissingPlaceholder;
        }
    }

    return values;
}

fn indexOfName(names: []const []const u8, target: []const u8) ?usize {
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, target)) return i;
    }
    return null;
}

/// Returns true if `value` contains no POSIX shell-special characters and
/// can be embedded in a command string without quoting.
fn isShellSafe(value: []const u8) bool {
    if (value.len == 0) return false; // empty string must be quoted as ''
    for (value) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9',
            '-', '_', '.', '/', ':', '@', '%', '+', '=',
            => {},
            else => return false,
        }
    }
    return true;
}

/// Append `value` to `out`, wrapping in single quotes if the value contains
/// shell-special characters (spaces, `$`, `"`, etc.).
/// Embedded single quotes are handled via the `'...''"'"'...'` idiom.
fn appendQuoted(gpa: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (isShellSafe(value)) {
        try out.appendSlice(gpa, value);
        return;
    }
    try out.append(gpa, '\'');
    for (value) |ch| {
        if (ch == '\'') {
            // End quote, emit literal single-quote, restart quote.
            try out.appendSlice(gpa, "'\"'\"'");
        } else {
            try out.append(gpa, ch);
        }
    }
    try out.append(gpa, '\'');
}

/// Substitute all `{name}` tokens in `tmpl` using the provided values
/// (parallel to `placeholders`). Values containing shell-special characters
/// are automatically single-quoted so the result is safe to eval.
/// Caller owns the returned string.
pub fn substitute(
    gpa: std.mem.Allocator,
    tmpl: []const u8,
    placeholders: []const []const u8,
    values: []const []const u8,
) ![]u8 {
    std.debug.assert(placeholders.len == values.len);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < tmpl.len) : (i += 1) {
        if (tmpl[i] != '{') {
            try out.append(gpa, tmpl[i]);
            continue;
        }
        const start = i + 1;
        var end = start;
        while (end < tmpl.len and tmpl[end] != '}') : (end += 1) {}
        if (end >= tmpl.len) {
            // Unclosed brace — emit literally.
            try out.append(gpa, '{');
            continue;
        }
        const name = tmpl[start..end];
        const idx = indexOfName(placeholders, name);
        if (idx) |k| {
            try appendQuoted(gpa, &out, values[k]);
        } else {
            // Unknown placeholder — emit literally.
            try out.append(gpa, '{');
            try out.appendSlice(gpa, name);
            try out.append(gpa, '}');
        }
        i = end;
    }

    return out.toOwnedSlice(gpa);
}
