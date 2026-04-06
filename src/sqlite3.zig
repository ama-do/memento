/// Minimal C FFI declarations for libsqlite3.
/// Nothing here allocates or does logic — it's a direct mapping of the C API.
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const sqlite3_destructor_type = ?*const fn (?*anyopaque) callconv(.c) void;

pub const SQLITE_OK = @as(c_int, 0);
pub const SQLITE_ROW = @as(c_int, 100);
pub const SQLITE_DONE = @as(c_int, 101);
pub const SQLITE_OPEN_READWRITE = @as(c_int, 0x00000002);
pub const SQLITE_OPEN_CREATE = @as(c_int, 0x00000004);
pub const SQLITE_NULL = @as(c_int, 5);

/// Tell SQLite to make its own copy of the string before bind returns.
pub const SQLITE_TRANSIENT: sqlite3_destructor_type =
    @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

pub extern fn sqlite3_open_v2(
    filename: [*:0]const u8,
    ppDb: **sqlite3,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) c_int;

pub extern fn sqlite3_close(db: *sqlite3) c_int;

pub extern fn sqlite3_exec(
    db: *sqlite3,
    sql: [*:0]const u8,
    callback: ?*anyopaque,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;

pub extern fn sqlite3_prepare_v2(
    db: *sqlite3,
    sql: [*:0]const u8,
    nByte: c_int,
    ppStmt: **sqlite3_stmt,
    pzTail: ?*?[*:0]const u8,
) c_int;

pub extern fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;

pub extern fn sqlite3_bind_text(
    stmt: *sqlite3_stmt,
    col: c_int,
    text: [*]const u8,
    n: c_int,
    destructor: sqlite3_destructor_type,
) c_int;

pub extern fn sqlite3_bind_int64(stmt: *sqlite3_stmt, col: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_null(stmt: *sqlite3_stmt, col: c_int) c_int;

pub extern fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_int64(stmt: *sqlite3_stmt, iCol: c_int) i64;
pub extern fn sqlite3_column_type(stmt: *sqlite3_stmt, iCol: c_int) c_int;
pub extern fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;

pub extern fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
pub extern fn sqlite3_last_insert_rowid(db: *sqlite3) i64;
pub extern fn sqlite3_changes(db: *sqlite3) c_int;
pub extern fn sqlite3_free(ptr: *anyopaque) void;
