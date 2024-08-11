//! Builds of the Zig compiler are distributed partly in source form. That
//! source lives here. These APIs are provided as-is and have absolutely no API
//! guarantees whatsoever.

pub const ErrorBundle = @import("zig/ErrorBundle.zig");
pub const Server = @import("zig/Server.zig");
pub const Client = @import("zig/Client.zig");
pub const Token = tokenizer.Token;
pub const Tokenizer = tokenizer.Tokenizer;
pub const string_literal = @import("zig/string_literal.zig");
pub const number_literal = @import("zig/number_literal.zig");
pub const primitives = @import("zig/primitives.zig");
pub const isPrimitive = primitives.isPrimitive;
pub const Ast = @import("zig/Ast.zig");
pub const AstGen = @import("zig/AstGen.zig");
pub const Zir = @import("zig/Zir.zig");
pub const system = @import("zig/system.zig");
pub const CrossTarget = @compileError("deprecated; use std.Target.Query");
pub const BuiltinFn = @import("zig/BuiltinFn.zig");
pub const AstRlAnnotate = @import("zig/AstRlAnnotate.zig");
pub const LibCInstallation = @import("zig/LibCInstallation.zig");
pub const WindowsSdk = @import("zig/WindowsSdk.zig");
pub const LibCDirs = @import("zig/LibCDirs.zig");
pub const target = @import("zig/target.zig");

// Character literal parsing
pub const ParsedCharLiteral = string_literal.ParsedCharLiteral;
pub const parseCharLiteral = string_literal.parseCharLiteral;
pub const parseNumberLiteral = number_literal.parseNumberLiteral;

// Files needed by translate-c.
pub const c_builtins = @import("zig/c_builtins.zig");
pub const c_translation = @import("zig/c_translation.zig");

pub const SrcHasher = std.crypto.hash.Blake3;
pub const SrcHash = [16]u8;

pub const Color = enum {
    /// Determine whether stderr is a terminal or not automatically.
    auto,
    /// Assume stderr is not a terminal.
    off,
    /// Assume stderr is a terminal.
    on,

    pub fn get_tty_conf(color: Color) std.io.tty.Config {
        return switch (color) {
            .auto => std.io.tty.detectConfig(std.io.getStdErr()),
            .on => .escape_codes,
            .off => .no_color,
        };
    }

    pub fn renderOptions(color: Color) std.zig.ErrorBundle.RenderOptions {
        const ttyconf = get_tty_conf(color);
        return .{
            .ttyconf = ttyconf,
            .include_source_line = ttyconf != .no_color,
            .include_reference_trace = ttyconf != .no_color,
        };
    }
};

/// There are many assumptions in the entire codebase that Zig source files can
/// be byte-indexed with a u32 integer.
pub const max_src_size = std.math.maxInt(u32);

pub fn hashSrc(src: []const u8) SrcHash {
    var out: SrcHash = undefined;
    SrcHasher.hash(src, &out, .{});
    return out;
}

pub fn srcHashEql(a: SrcHash, b: SrcHash) bool {
    return @as(u128, @bitCast(a)) == @as(u128, @bitCast(b));
}

pub fn hashName(parent_hash: SrcHash, sep: []const u8, name: []const u8) SrcHash {
    var out: SrcHash = undefined;
    var hasher = SrcHasher.init(.{});
    hasher.update(&parent_hash);
    hasher.update(sep);
    hasher.update(name);
    hasher.final(&out);
    return out;
}

pub const Loc = struct {
    line: usize,
    column: usize,
    /// Does not include the trailing newline.
    source_line: []const u8,

    pub fn eql(a: Loc, b: Loc) bool {
        return a.line == b.line and a.column == b.column and std.mem.eql(u8, a.source_line, b.source_line);
    }
};

pub fn findLineColumn(source: []const u8, byte_offset: usize) Loc {
    var line: usize = 0;
    var column: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < byte_offset) : (i += 1) {
        switch (source[i]) {
            '\n' => {
                line += 1;
                column = 0;
                line_start = i + 1;
            },
            else => {
                column += 1;
            },
        }
    }
    while (i < source.len and source[i] != '\n') {
        i += 1;
    }
    return .{
        .line = line,
        .column = column,
        .source_line = source[line_start..i],
    };
}

pub fn lineDelta(source: []const u8, start: usize, end: usize) isize {
    var line: isize = 0;
    if (end >= start) {
        for (source[start..end]) |byte| switch (byte) {
            '\n' => line += 1,
            else => continue,
        };
    } else {
        for (source[end..start]) |byte| switch (byte) {
            '\n' => line -= 1,
            else => continue,
        };
    }
    return line;
}

pub const BinNameOptions = struct {
    root_name: []const u8,
    target: std.Target,
    output_mode: std.builtin.OutputMode,
    link_mode: ?std.builtin.LinkMode = null,
    version: ?std.SemanticVersion = null,
};

/// Returns the standard file system basename of a binary generated by the Zig compiler.
pub fn binNameAlloc(allocator: Allocator, options: BinNameOptions) error{OutOfMemory}![]u8 {
    const root_name = options.root_name;
    const t = options.target;
    switch (t.ofmt) {
        .coff => switch (options.output_mode) {
            .Exe => return std.fmt.allocPrint(allocator, "{s}{s}", .{ root_name, t.exeFileExt() }),
            .Lib => {
                const suffix = switch (options.link_mode orelse .static) {
                    .static => ".lib",
                    .dynamic => ".dll",
                };
                return std.fmt.allocPrint(allocator, "{s}{s}", .{ root_name, suffix });
            },
            .Obj => return std.fmt.allocPrint(allocator, "{s}.obj", .{root_name}),
        },
        .elf, .goff, .xcoff => switch (options.output_mode) {
            .Exe => return allocator.dupe(u8, root_name),
            .Lib => {
                switch (options.link_mode orelse .static) {
                    .static => return std.fmt.allocPrint(allocator, "{s}{s}.a", .{
                        t.libPrefix(), root_name,
                    }),
                    .dynamic => {
                        if (options.version) |ver| {
                            return std.fmt.allocPrint(allocator, "{s}{s}.so.{d}.{d}.{d}", .{
                                t.libPrefix(), root_name, ver.major, ver.minor, ver.patch,
                            });
                        } else {
                            return std.fmt.allocPrint(allocator, "{s}{s}.so", .{
                                t.libPrefix(), root_name,
                            });
                        }
                    },
                }
            },
            .Obj => return std.fmt.allocPrint(allocator, "{s}.o", .{root_name}),
        },
        .macho => switch (options.output_mode) {
            .Exe => return allocator.dupe(u8, root_name),
            .Lib => {
                switch (options.link_mode orelse .static) {
                    .static => return std.fmt.allocPrint(allocator, "{s}{s}.a", .{
                        t.libPrefix(), root_name,
                    }),
                    .dynamic => {
                        if (options.version) |ver| {
                            return std.fmt.allocPrint(allocator, "{s}{s}.{d}.{d}.{d}.dylib", .{
                                t.libPrefix(), root_name, ver.major, ver.minor, ver.patch,
                            });
                        } else {
                            return std.fmt.allocPrint(allocator, "{s}{s}.dylib", .{
                                t.libPrefix(), root_name,
                            });
                        }
                    },
                }
            },
            .Obj => return std.fmt.allocPrint(allocator, "{s}.o", .{root_name}),
        },
        .wasm => switch (options.output_mode) {
            .Exe => return std.fmt.allocPrint(allocator, "{s}{s}", .{ root_name, t.exeFileExt() }),
            .Lib => {
                switch (options.link_mode orelse .static) {
                    .static => return std.fmt.allocPrint(allocator, "{s}{s}.a", .{
                        t.libPrefix(), root_name,
                    }),
                    .dynamic => return std.fmt.allocPrint(allocator, "{s}.wasm", .{root_name}),
                }
            },
            .Obj => return std.fmt.allocPrint(allocator, "{s}.o", .{root_name}),
        },
        .c => return std.fmt.allocPrint(allocator, "{s}.c", .{root_name}),
        .spirv => return std.fmt.allocPrint(allocator, "{s}.spv", .{root_name}),
        .hex => return std.fmt.allocPrint(allocator, "{s}.ihex", .{root_name}),
        .raw => return std.fmt.allocPrint(allocator, "{s}.bin", .{root_name}),
        .plan9 => switch (options.output_mode) {
            .Exe => return allocator.dupe(u8, root_name),
            .Obj => return std.fmt.allocPrint(allocator, "{s}{s}", .{
                root_name, t.ofmt.fileExt(t.cpu.arch),
            }),
            .Lib => return std.fmt.allocPrint(allocator, "{s}{s}.a", .{
                t.libPrefix(), root_name,
            }),
        },
        .nvptx => return std.fmt.allocPrint(allocator, "{s}.ptx", .{root_name}),
        .dxcontainer => return std.fmt.allocPrint(allocator, "{s}.dxil", .{root_name}),
    }
}

pub const BuildId = union(enum) {
    none,
    fast,
    uuid,
    sha1,
    md5,
    hexstring: HexString,

    pub fn eql(a: BuildId, b: BuildId) bool {
        const Tag = @typeInfo(BuildId).Union.tag_type.?;
        const a_tag: Tag = a;
        const b_tag: Tag = b;
        if (a_tag != b_tag) return false;
        return switch (a) {
            .none, .fast, .uuid, .sha1, .md5 => true,
            .hexstring => |a_hexstring| std.mem.eql(u8, a_hexstring.toSlice(), b.hexstring.toSlice()),
        };
    }

    pub const HexString = struct {
        bytes: [32]u8,
        len: u8,

        /// Result is byte values, *not* hex-encoded.
        pub fn toSlice(hs: *const HexString) []const u8 {
            return hs.bytes[0..hs.len];
        }
    };

    /// Input is byte values, *not* hex-encoded.
    /// Asserts `bytes` fits inside `HexString`
    pub fn initHexString(bytes: []const u8) BuildId {
        var result: BuildId = .{ .hexstring = .{
            .bytes = undefined,
            .len = @intCast(bytes.len),
        } };
        @memcpy(result.hexstring.bytes[0..bytes.len], bytes);
        return result;
    }

    /// Converts UTF-8 text to a `BuildId`.
    pub fn parse(text: []const u8) !BuildId {
        if (std.mem.eql(u8, text, "none")) {
            return .none;
        } else if (std.mem.eql(u8, text, "fast")) {
            return .fast;
        } else if (std.mem.eql(u8, text, "uuid")) {
            return .uuid;
        } else if (std.mem.eql(u8, text, "sha1") or std.mem.eql(u8, text, "tree")) {
            return .sha1;
        } else if (std.mem.eql(u8, text, "md5")) {
            return .md5;
        } else if (std.mem.startsWith(u8, text, "0x")) {
            var result: BuildId = .{ .hexstring = undefined };
            const slice = try std.fmt.hexToBytes(&result.hexstring.bytes, text[2..]);
            result.hexstring.len = @as(u8, @intCast(slice.len));
            return result;
        }
        return error.InvalidBuildIdStyle;
    }

    test parse {
        try std.testing.expectEqual(BuildId.md5, try parse("md5"));
        try std.testing.expectEqual(BuildId.none, try parse("none"));
        try std.testing.expectEqual(BuildId.fast, try parse("fast"));
        try std.testing.expectEqual(BuildId.uuid, try parse("uuid"));
        try std.testing.expectEqual(BuildId.sha1, try parse("sha1"));
        try std.testing.expectEqual(BuildId.sha1, try parse("tree"));

        try std.testing.expect(BuildId.initHexString("").eql(try parse("0x")));
        try std.testing.expect(BuildId.initHexString("\x12\x34\x56").eql(try parse("0x123456")));
        try std.testing.expectError(error.InvalidLength, parse("0x12-34"));
        try std.testing.expectError(error.InvalidCharacter, parse("0xfoobbb"));
        try std.testing.expectError(error.InvalidBuildIdStyle, parse("yaddaxxx"));
    }
};

/// Renders a `std.Target.Cpu` value into a textual representation that can be parsed
/// via the `-mcpu` flag passed to the Zig compiler.
/// Appends the result to `buffer`.
pub fn serializeCpu(buffer: *std.ArrayList(u8), cpu: std.Target.Cpu) Allocator.Error!void {
    const all_features = cpu.arch.allFeaturesList();
    var populated_cpu_features = cpu.model.features;
    populated_cpu_features.populateDependencies(all_features);

    try buffer.appendSlice(cpu.model.name);

    if (populated_cpu_features.eql(cpu.features)) {
        // The CPU name alone is sufficient.
        return;
    }

    for (all_features, 0..) |feature, i_usize| {
        const i: std.Target.Cpu.Feature.Set.Index = @intCast(i_usize);
        const in_cpu_set = populated_cpu_features.isEnabled(i);
        const in_actual_set = cpu.features.isEnabled(i);
        try buffer.ensureUnusedCapacity(feature.name.len + 1);
        if (in_cpu_set and !in_actual_set) {
            buffer.appendAssumeCapacity('-');
            buffer.appendSliceAssumeCapacity(feature.name);
        } else if (!in_cpu_set and in_actual_set) {
            buffer.appendAssumeCapacity('+');
            buffer.appendSliceAssumeCapacity(feature.name);
        }
    }
}

pub fn serializeCpuAlloc(ally: Allocator, cpu: std.Target.Cpu) Allocator.Error![]u8 {
    var buffer = std.ArrayList(u8).init(ally);
    try serializeCpu(&buffer, cpu);
    return buffer.toOwnedSlice();
}

const std = @import("std.zig");
const tokenizer = @import("zig/tokenizer.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Return a Formatter for a Zig identifier, escaping it with `@""` syntax if needed.
///
/// - An empty `{}` format specifier escapes invalid identifiers, identifiers that shadow primitives
///   and the reserved `_` identifier.
/// - Add `p` to the specifier to render identifiers that shadow primitives unescaped.
/// - Add `_` to the specifier to render the reserved `_` identifier unescaped.
/// - `p` and `_` can be combined, e.g. `{p_}`.
///
pub fn fmtId(bytes: []const u8) std.fmt.Formatter(formatId) {
    return .{ .data = bytes };
}

test fmtId {
    const expectFmt = std.testing.expectFmt;
    try expectFmt("@\"while\"", "{}", .{fmtId("while")});
    try expectFmt("@\"while\"", "{p}", .{fmtId("while")});
    try expectFmt("@\"while\"", "{_}", .{fmtId("while")});
    try expectFmt("@\"while\"", "{p_}", .{fmtId("while")});
    try expectFmt("@\"while\"", "{_p}", .{fmtId("while")});

    try expectFmt("hello", "{}", .{fmtId("hello")});
    try expectFmt("hello", "{p}", .{fmtId("hello")});
    try expectFmt("hello", "{_}", .{fmtId("hello")});
    try expectFmt("hello", "{p_}", .{fmtId("hello")});
    try expectFmt("hello", "{_p}", .{fmtId("hello")});

    try expectFmt("@\"type\"", "{}", .{fmtId("type")});
    try expectFmt("type", "{p}", .{fmtId("type")});
    try expectFmt("@\"type\"", "{_}", .{fmtId("type")});
    try expectFmt("type", "{p_}", .{fmtId("type")});
    try expectFmt("type", "{_p}", .{fmtId("type")});

    try expectFmt("@\"_\"", "{}", .{fmtId("_")});
    try expectFmt("@\"_\"", "{p}", .{fmtId("_")});
    try expectFmt("_", "{_}", .{fmtId("_")});
    try expectFmt("_", "{p_}", .{fmtId("_")});
    try expectFmt("_", "{_p}", .{fmtId("_")});

    try expectFmt("@\"i123\"", "{}", .{fmtId("i123")});
    try expectFmt("i123", "{p}", .{fmtId("i123")});
    try expectFmt("@\"4four\"", "{}", .{fmtId("4four")});
    try expectFmt("_underscore", "{}", .{fmtId("_underscore")});
    try expectFmt("@\"11\\\"23\"", "{}", .{fmtId("11\"23")});
    try expectFmt("@\"11\\x0f23\"", "{}", .{fmtId("11\x0F23")});

    // These are technically not currently legal in Zig.
    try expectFmt("@\"\"", "{}", .{fmtId("")});
    try expectFmt("@\"\\x00\"", "{}", .{fmtId("\x00")});
}

/// Print the string as a Zig identifier, escaping it with `@""` syntax if needed.
fn formatId(
    bytes: []const u8,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    const allow_primitive, const allow_underscore = comptime parse_fmt: {
        var allow_primitive = false;
        var allow_underscore = false;
        for (fmt) |char| {
            switch (char) {
                'p' => if (!allow_primitive) {
                    allow_primitive = true;
                    continue;
                },
                '_' => if (!allow_underscore) {
                    allow_underscore = true;
                    continue;
                },
                else => {},
            }
            @compileError("expected {}, {p}, {_}, {p_} or {_p}, found {" ++ fmt ++ "}");
        }
        break :parse_fmt .{ allow_primitive, allow_underscore };
    };

    if (isValidId(bytes) and
        (allow_primitive or !std.zig.isPrimitive(bytes)) and
        (allow_underscore or !isUnderscore(bytes)))
    {
        return writer.writeAll(bytes);
    }
    try writer.writeAll("@\"");
    try stringEscape(bytes, "", options, writer);
    try writer.writeByte('"');
}

/// Return a Formatter for Zig Escapes of a double quoted string.
/// The format specifier must be one of:
///  * `{}` treats contents as a double-quoted string.
///  * `{'}` treats contents as a single-quoted string.
pub fn fmtEscapes(bytes: []const u8) std.fmt.Formatter(stringEscape) {
    return .{ .data = bytes };
}

test fmtEscapes {
    const expectFmt = std.testing.expectFmt;
    try expectFmt("\\x0f", "{}", .{fmtEscapes("\x0f")});
    try expectFmt(
        \\" \\ hi \x07 \x11 " derp \'"
    , "\"{'}\"", .{fmtEscapes(" \\ hi \x07 \x11 \" derp '")});
    try expectFmt(
        \\" \\ hi \x07 \x11 \" derp '"
    , "\"{}\"", .{fmtEscapes(" \\ hi \x07 \x11 \" derp '")});
}

/// Print the string as escaped contents of a double quoted or single-quoted string.
/// Format `{}` treats contents as a double-quoted string.
/// Format `{'}` treats contents as a single-quoted string.
pub fn stringEscape(
    bytes: []const u8,
    comptime f: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = options;
    for (bytes) |byte| switch (byte) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '\\' => try writer.writeAll("\\\\"),
        '"' => {
            if (f.len == 1 and f[0] == '\'') {
                try writer.writeByte('"');
            } else if (f.len == 0) {
                try writer.writeAll("\\\"");
            } else {
                @compileError("expected {} or {'}, found {" ++ f ++ "}");
            }
        },
        '\'' => {
            if (f.len == 1 and f[0] == '\'') {
                try writer.writeAll("\\'");
            } else if (f.len == 0) {
                try writer.writeByte('\'');
            } else {
                @compileError("expected {} or {'}, found {" ++ f ++ "}");
            }
        },
        ' ', '!', '#'...'&', '('...'[', ']'...'~' => try writer.writeByte(byte),
        // Use hex escapes for rest any unprintable characters.
        else => {
            try writer.writeAll("\\x");
            try std.fmt.formatInt(byte, 16, .lower, .{ .width = 2, .fill = '0' }, writer);
        },
    };
}

pub fn isValidId(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes, 0..) |c, i| {
        switch (c) {
            '_', 'a'...'z', 'A'...'Z' => {},
            '0'...'9' => if (i == 0) return false,
            else => return false,
        }
    }
    return std.zig.Token.getKeyword(bytes) == null;
}

test isValidId {
    try std.testing.expect(!isValidId(""));
    try std.testing.expect(isValidId("foobar"));
    try std.testing.expect(!isValidId("a b c"));
    try std.testing.expect(!isValidId("3d"));
    try std.testing.expect(!isValidId("enum"));
    try std.testing.expect(isValidId("i386"));
}

pub fn isUnderscore(bytes: []const u8) bool {
    return bytes.len == 1 and bytes[0] == '_';
}

test isUnderscore {
    try std.testing.expect(isUnderscore("_"));
    try std.testing.expect(!isUnderscore("__"));
    try std.testing.expect(!isUnderscore("_foo"));
    try std.testing.expect(isUnderscore("\x5f"));
    try std.testing.expect(!isUnderscore("\\x5f"));
}

pub fn readSourceFileToEndAlloc(
    allocator: Allocator,
    input: std.fs.File,
    size_hint: ?usize,
) ![:0]u8 {
    const source_code = input.readToEndAllocOptions(
        allocator,
        max_src_size,
        size_hint,
        @alignOf(u16),
        0,
    ) catch |err| switch (err) {
        error.ConnectionResetByPeer => unreachable,
        error.ConnectionTimedOut => unreachable,
        error.NotOpenForReading => unreachable,
        else => |e| return e,
    };
    errdefer allocator.free(source_code);

    // Detect unsupported file types with their Byte Order Mark
    const unsupported_boms = [_][]const u8{
        "\xff\xfe\x00\x00", // UTF-32 little endian
        "\xfe\xff\x00\x00", // UTF-32 big endian
        "\xfe\xff", // UTF-16 big endian
    };
    for (unsupported_boms) |bom| {
        if (std.mem.startsWith(u8, source_code, bom)) {
            return error.UnsupportedEncoding;
        }
    }

    // If the file starts with a UTF-16 little endian BOM, translate it to UTF-8
    if (std.mem.startsWith(u8, source_code, "\xff\xfe")) {
        const source_code_utf16_le = std.mem.bytesAsSlice(u16, source_code);
        const source_code_utf8 = std.unicode.utf16LeToUtf8AllocZ(allocator, source_code_utf16_le) catch |err| switch (err) {
            error.DanglingSurrogateHalf => error.UnsupportedEncoding,
            error.ExpectedSecondSurrogateHalf => error.UnsupportedEncoding,
            error.UnexpectedSecondSurrogateHalf => error.UnsupportedEncoding,
            else => |e| return e,
        };

        allocator.free(source_code);
        return source_code_utf8;
    }

    return source_code;
}

pub fn printAstErrorsToStderr(gpa: Allocator, tree: Ast, path: []const u8, color: Color) !void {
    var wip_errors: std.zig.ErrorBundle.Wip = undefined;
    try wip_errors.init(gpa);
    defer wip_errors.deinit();

    try putAstErrorsIntoBundle(gpa, tree, path, &wip_errors);

    var error_bundle = try wip_errors.toOwnedBundle("");
    defer error_bundle.deinit(gpa);
    error_bundle.renderToStdErr(color.renderOptions());
}

pub fn putAstErrorsIntoBundle(
    gpa: Allocator,
    tree: Ast,
    path: []const u8,
    wip_errors: *std.zig.ErrorBundle.Wip,
) Allocator.Error!void {
    var zir = try AstGen.generate(gpa, tree);
    defer zir.deinit(gpa);

    try wip_errors.addZirErrorMessages(zir, tree, tree.source, path);
}

pub fn resolveTargetQueryOrFatal(target_query: std.Target.Query) std.Target {
    return std.zig.system.resolveTargetQuery(target_query) catch |err|
        fatal("unable to resolve target: {s}", .{@errorName(err)});
}

pub fn parseTargetQueryOrReportFatalError(
    allocator: Allocator,
    opts: std.Target.Query.ParseOptions,
) std.Target.Query {
    var opts_with_diags = opts;
    var diags: std.Target.Query.ParseOptions.Diagnostics = .{};
    if (opts_with_diags.diagnostics == null) {
        opts_with_diags.diagnostics = &diags;
    }
    return std.Target.Query.parse(opts_with_diags) catch |err| switch (err) {
        error.UnknownCpuModel => {
            help: {
                var help_text = std.ArrayList(u8).init(allocator);
                defer help_text.deinit();
                for (diags.arch.?.allCpuModels()) |cpu| {
                    help_text.writer().print(" {s}\n", .{cpu.name}) catch break :help;
                }
                std.log.info("available CPUs for architecture '{s}':\n{s}", .{
                    @tagName(diags.arch.?), help_text.items,
                });
            }
            fatal("unknown CPU: '{s}'", .{diags.cpu_name.?});
        },
        error.UnknownCpuFeature => {
            help: {
                var help_text = std.ArrayList(u8).init(allocator);
                defer help_text.deinit();
                for (diags.arch.?.allFeaturesList()) |feature| {
                    help_text.writer().print(" {s}: {s}\n", .{ feature.name, feature.description }) catch break :help;
                }
                std.log.info("available CPU features for architecture '{s}':\n{s}", .{
                    @tagName(diags.arch.?), help_text.items,
                });
            }
            fatal("unknown CPU feature: '{s}'", .{diags.unknown_feature_name.?});
        },
        error.UnknownObjectFormat => {
            help: {
                var help_text = std.ArrayList(u8).init(allocator);
                defer help_text.deinit();
                inline for (@typeInfo(std.Target.ObjectFormat).Enum.fields) |field| {
                    help_text.writer().print(" {s}\n", .{field.name}) catch break :help;
                }
                std.log.info("available object formats:\n{s}", .{help_text.items});
            }
            fatal("unknown object format: '{s}'", .{opts.object_format.?});
        },
        else => |e| fatal("unable to parse target query '{s}': {s}", .{
            opts.arch_os_abi, @errorName(e),
        }),
    };
}

/// Deprecated; see `std.process.fatal`.
pub const fatal = std.process.fatal;

/// Collects all the environment variables that Zig could possibly inspect, so
/// that we can do reflection on this and print them with `zig env`.
pub const EnvVar = enum {
    ZIG_GLOBAL_CACHE_DIR,
    ZIG_LOCAL_CACHE_DIR,
    ZIG_LIB_DIR,
    ZIG_LIBC,
    ZIG_BUILD_RUNNER,
    ZIG_VERBOSE_LINK,
    ZIG_VERBOSE_CC,
    ZIG_BTRFS_WORKAROUND,
    ZIG_DEBUG_CMD,
    CC,
    NO_COLOR,
    CLICOLOR_FORCE,
    XDG_CACHE_HOME,
    HOME,

    pub fn isSet(comptime ev: EnvVar) bool {
        return std.process.hasEnvVarConstant(@tagName(ev));
    }

    pub fn get(ev: EnvVar, arena: std.mem.Allocator) !?[]u8 {
        if (std.process.getEnvVarOwned(arena, @tagName(ev))) |value| {
            return value;
        } else |err| switch (err) {
            error.EnvironmentVariableNotFound => return null,
            else => |e| return e,
        }
    }

    pub fn getPosix(comptime ev: EnvVar) ?[:0]const u8 {
        return std.posix.getenvZ(@tagName(ev));
    }
};

test {
    _ = Ast;
    _ = AstRlAnnotate;
    _ = BuiltinFn;
    _ = Client;
    _ = ErrorBundle;
    _ = LibCDirs;
    _ = LibCInstallation;
    _ = Server;
    _ = WindowsSdk;
    _ = number_literal;
    _ = primitives;
    _ = string_literal;
    _ = system;
    _ = target;
    _ = c_translation;
}
