const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const ctype = @import("ctype.zig");
const nodes = @import("nodes.zig");
const htmlentities = @import("htmlentities");

pub fn isLineEndChar(ch: u8) bool {
    return switch (ch) {
        '\n', '\r' => true,
        else => false,
    };
}

pub fn isSpaceOrTab(ch: u8) bool {
    return switch (ch) {
        ' ', '\t' => true,
        else => false,
    };
}

pub fn isBlank(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '\n', '\r' => return true,
            ' ', '\t' => {},
            else => return false,
        }
    }
    return true;
}

test "isBlank" {
    testing.expect(isBlank(""));
    testing.expect(isBlank("\nx"));
    testing.expect(isBlank("    \t\t  \r"));
    testing.expect(!isBlank("e"));
    testing.expect(!isBlank("   \t    e "));
}

pub fn ltrim(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and ctype.isspace(s[i])) : (i += 1) {}
    return s[i..];
}

test "ltrim" {
    testing.expectEqualStrings("abc", ltrim("abc"));
    testing.expectEqualStrings("abc", ltrim("   abc"));
    testing.expectEqualStrings("abc", ltrim("      \n\n \t\r abc"));
    testing.expectEqualStrings("abc \n zz \n   ", ltrim("\nabc \n zz \n   "));
}

pub fn rtrim(s: []const u8) []const u8 {
    var len = s.len;
    while (len > 0 and ctype.isspace(s[len - 1])) : (len -= 1) {}
    return s[0..len];
}

test "rtrim" {
    testing.expectEqualStrings("abc", rtrim("abc"));
    testing.expectEqualStrings("abc", rtrim("abc   "));
    testing.expectEqualStrings("abc", rtrim("abc      \n\n \t\r "));
    testing.expectEqualStrings("  \nabc \n zz", rtrim("  \nabc \n zz \n"));
}

pub fn trim(s: []const u8) []const u8 {
    return rtrim(ltrim(s));
}

pub fn chopTrailingHashtags(s: []const u8) []const u8 {
    var r = rtrim(s);
    if (r.len == 0) return r;

    const orig_n = r.len - 1;
    var n = orig_n;
    while (r[n] == '#') : (n -= 1) {
        if (n == 0) return r;
    }

    if (n != orig_n and isSpaceOrTab(r[n])) {
        return rtrim(r[0..n]);
    } else {
        return r;
    }
}

test "chopTrailingHashtags" {
    testing.expectEqualStrings("xyz", chopTrailingHashtags("xyz"));
    testing.expectEqualStrings("xyz#", chopTrailingHashtags("xyz#"));
    testing.expectEqualStrings("xyz###", chopTrailingHashtags("xyz###"));
    testing.expectEqualStrings("xyz###", chopTrailingHashtags("xyz###  "));
    testing.expectEqualStrings("xyz###", chopTrailingHashtags("xyz###  #"));
    testing.expectEqualStrings("xyz", chopTrailingHashtags("xyz  "));
    testing.expectEqualStrings("xyz", chopTrailingHashtags("xyz  ##"));
    testing.expectEqualStrings("xyz", chopTrailingHashtags("xyz  ##"));
}

pub fn normalizeCode(allocator: *mem.Allocator, s: []const u8) ![]u8 {
    var code = try std.ArrayList(u8).initCapacity(allocator, s.len);

    var i: usize = 0;
    var contains_nonspace = false;

    while (i < s.len) {
        switch (s[i]) {
            '\r' => {
                if (i + 1 == s.len or s[i + 1] != '\n') {
                    try code.append(' ');
                }
            },
            '\n' => {
                try code.append(' ');
            },
            else => try code.append(s[i]),
        }
        if (s[i] != ' ') {
            contains_nonspace = true;
        }
        i += 1;
    }

    if (contains_nonspace and code.items.len != 0 and code.span()[0] == ' ' and code.span()[code.items.len - 1] == ' ') {
        _ = code.orderedRemove(0);
        _ = code.pop();
    }

    return code.toOwnedSlice();
}

const Case = struct {
    in: []const u8,
    out: []const u8,
};

test "normalizeCode" {
    const cases = [_]Case{
        .{ .in = "qwe", .out = "qwe" },
        .{ .in = " qwe ", .out = "qwe" },
        .{ .in = "  qwe  ", .out = " qwe " },
        .{ .in = " abc\rdef'\r\ndef ", .out = "abc def' def" },
    };

    for (cases) |case| {
        const result = try normalizeCode(std.testing.allocator, case.in);
        defer std.testing.allocator.free(result);
        testing.expectEqualStrings(case.out, result);
    }
}

pub fn removeTrailingBlankLines(line: *std.ArrayList(u8)) void {
    var i = line.items.len - 1;
    while (true) : (i -= 1) {
        const c = line.items[i];

        if (c != ' ' and c != '\t' and !isLineEndChar(c)) {
            break;
        }

        if (i == 0) {
            line.items.len = 0;
            return;
        }
    }

    while (i < line.items.len) : (i += 1) {
        if (!isLineEndChar(line.items[i])) continue;
        line.items.len = i;
        break;
    }
}

test "removeTrailingBlankLines" {
    const cases = [_]Case{
        .{ .in = "\n\n   \r\t\n ", .out = "" },
        .{ .in = "yep\nok\n\n  ", .out = "yep\nok" },
        .{ .in = "yep  ", .out = "yep  " },
    };

    var line = std.ArrayList(u8).init(std.testing.allocator);
    defer line.deinit();
    for (cases) |case| {
        line.items.len = 0;
        try line.appendSlice(case.in);
        removeTrailingBlankLines(&line);
        testing.expectEqualStrings(case.out, line.span());
    }
}

const ENTITY_MIN_LENGTH: u8 = 2;
const ENTITY_MAX_LENGTH: u8 = 32;

pub fn unescapeInto(text: []const u8, out: *std.ArrayList(u8)) !?usize {
    if (text.len >= 3 and text[0] == '#') {
        var codepoint: u32 = 0;
        var i: usize = 0;

        const num_digits = block: {
            if (ctype.isdigit(text[1])) {
                i = 1;
                while (i < text.len and ctype.isdigit(text[i])) {
                    codepoint = (codepoint * 10) + (@as(u32, text[i]) - '0');
                    codepoint = std.math.min(codepoint, 0x11_0000);
                    i += 1;
                }
                break :block i - 1;
            } else if (text[1] == 'x' or text[1] == 'X') {
                i = 2;
                while (i < text.len and ctype.isxdigit(text[i])) {
                    codepoint = (codepoint * 16) + (@as(u32, text[i]) | 32) % 39 - 9;
                    codepoint = std.math.min(codepoint, 0x11_0000);
                    i += 1;
                }
                break :block i - 2;
            }
            break :block 0;
        };

        if (num_digits >= 1 and num_digits <= 8 and i < text.len and text[i] == ';') {
            if (codepoint == 0 or (codepoint >= 0xd800 and codepoint <= 0xdfff) or codepoint >= 0x110000) {
                codepoint = 0xFFFD;
            }
            var sequence = [4]u8{ 0, 0, 0, 0 };
            // utf8Encode throws:
            // - Utf8CannotEncodeSurrogateHalf, which we guard against that by
            //   rewriting 0xd800..0xe0000 to 0xfffd.
            // - CodepointTooLarge, which we guard against by rewriting 0x110000+
            //   to 0xfffd.
            const len = std.unicode.utf8Encode(@truncate(u21, codepoint), &sequence) catch unreachable;
            try out.appendSlice(sequence[0..len]);
            return i + 1;
        }
    }

    const size = std.math.min(text.len, ENTITY_MAX_LENGTH);
    var i = ENTITY_MIN_LENGTH;
    while (i < size) : (i += 1) {
        if (text[i] == ' ')
            return null;
        if (text[i] == ';') {
            var key = [_]u8{'&'} ++ [_]u8{';'} ** (ENTITY_MAX_LENGTH + 1);
            mem.copy(u8, key[1..], text[0..i]);

            if (htmlentities.lookup(key[0 .. i + 2])) |item| {
                try out.appendSlice(item.characters);
                return i + 1;
            }
        }
    }

    return null;
}

fn unescapeHtmlInto(html: []const u8, out: *std.ArrayList(u8)) !void {
    var size = html.len;
    var i: usize = 0;

    while (i < size) {
        const org = i;

        while (i < size and html[i] != '&') : (i += 1) {}

        if (i > org) {
            if (org == 0 and i >= size) {
                try out.appendSlice(html);
                return;
            }

            try out.appendSlice(html[org..i]);
        }

        if (i >= size)
            return;

        i += 1;

        if (try unescapeInto(html[i..], out)) |unescaped_size| {
            i += unescaped_size;
        } else {
            try out.append('&');
        }
    }
}

pub fn unescapeHtml(allocator: *mem.Allocator, html: []const u8) ![]u8 {
    var al = std.ArrayList(u8).init(allocator);
    try unescapeHtmlInto(html, &al);
    return al.toOwnedSlice();
}

test "unescapeHtml" {
    const cases = [_]Case{
        .{ .in = "&#116;&#101;&#115;&#116;", .out = "test" },
        .{ .in = "&#12486;&#12473;&#12488;", .out = "テスト" },
        .{ .in = "&#x74;&#x65;&#X73;&#X74;", .out = "test" },
        .{ .in = "&#x30c6;&#x30b9;&#X30c8;", .out = "テスト" },

        // "Although HTML5 does accept some entity references without a trailing semicolon
        // (such as &copy), these are not recognized here, because it makes the grammar too
        // ambiguous:"
        .{ .in = "&hellip;&eacute&Eacute;&rrarr;&oS;", .out = "…&eacuteÉ⇉Ⓢ" },
    };

    for (cases) |case| {
        const result = try unescapeHtml(std.testing.allocator, case.in);
        defer std.testing.allocator.free(result);
        testing.expectEqualStrings(case.out, result);
    }
}

pub fn cleanAutolink(allocator: *mem.Allocator, url: []const u8, kind: nodes.AutolinkType) ![]u8 {
    var trimmed = trim(url);
    if (trimmed.len == 0)
        return allocator.dupe(u8, trimmed);

    var buf = try std.ArrayList(u8).initCapacity(allocator, trimmed.len);
    if (kind == .Email)
        try buf.appendSlice("mailto:");

    try unescapeHtmlInto(trimmed, &buf);
    return buf.toOwnedSlice();
}

test "cleanAutolink" {
    var email = try cleanAutolink(std.testing.allocator, "  hello&#x40;world.example ", .Email);
    defer std.testing.allocator.free(email);
    testing.expectEqualStrings("mailto:hello@world.example", email);

    var uri = try cleanAutolink(std.testing.allocator, "  www&#46;com ", .URI);
    defer std.testing.allocator.free(uri);
    testing.expectEqualStrings("www.com", uri);
}

pub fn unescape(allocator: *mem.Allocator, s: []const u8) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, s.len);
    var r: usize = 0;

    while (r < s.len) : (r += 1) {
        if (s[r] == '\\' and r + 1 < s.len and ctype.ispunct(s[r + 1]))
            r += 1;
        try buffer.append(s[r]);
    }
    return buffer.toOwnedSlice();
}
