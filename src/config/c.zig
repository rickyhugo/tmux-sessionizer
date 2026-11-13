// ABI declarations for the pinned vendor/tomlc17/tomlc17.h.
pub const TOML_STRING = 1;
pub const TOML_INT64 = 2;
pub const TOML_FP64 = 3;
pub const TOML_BOOLEAN = 4;
pub const TOML_DATE = 5;
pub const TOML_TIME = 6;
pub const TOML_DATETIME = 7;
pub const TOML_DATETIMETZ = 8;
pub const TOML_ARRAY = 9;
pub const TOML_TABLE = 10;
pub const toml_datum_t = extern struct {
    type: c_uint,
    flag: u32,
    lineno: c_int,
    colno: c_int,
    source: ?[*:0]const u8,
    u: extern union {
        s: [*:0]const u8,
        str: extern struct { ptr: [*]const u8, len: c_int },
        int64: i64,
        fp64: f64,
        boolean: bool,
        ts: extern struct { year: i16, month: i16, day: i16, hour: i16, minute: i16, second: i16, usec: i32, tz: i16 },
        arr: extern struct { size: i32, elem: [*]toml_datum_t },
        tab: extern struct { size: i32, key: [*][*]const u8, len: [*]c_int, value: [*]toml_datum_t },
    },
};
pub const toml_result_t = extern struct {
    ok: bool,
    toptab: toml_datum_t,
    errmsg: [200]u8,
    __internal: ?*anyopaque,
};
pub extern "c" fn toml_parse(src: [*]const u8, len: c_int) toml_result_t;
pub extern "c" fn toml_free(result: toml_result_t) void;
