/// Reference link definition — `[label]: url "optional title"`.

const std = @import("std");
const shared = @import("../utils.zig");

pub const RefDef = struct {
    label: []const u8,
    url: []const u8,
    title: ?[]const u8,
};

/// Classify a line as a reference link definition or return null.
/// Pattern: `[label]: url` or `[label]: url "title"` or `[label]: url 'title'`
pub fn classifyRefDef(line: []const u8) ?RefDef {
    if (line.len < 4) return null; // minimum: [x]:
    if (line[0] != '[') return null;

    // Find closing ]
    var pos: usize = 1;
    while (pos < line.len and line[pos] != ']') pos += 1;
    if (pos >= line.len or pos == 1) return null; // no ] or empty label
    const label = line[1..pos];

    // Must have : after ]
    pos += 1;
    if (pos >= line.len or line[pos] != ':') return null;
    pos += 1;

    // Skip optional whitespace
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) pos += 1;
    if (pos >= line.len) return .{ .label = label, .url = "", .title = null };

    const rest = line[pos..];

    // Parse URL and optional title
    const url_title = parseRefUrlTitle(rest);

    return .{
        .label = label,
        .url = url_title.url,
        .title = url_title.title,
    };
}

const UrlTitle = struct {
    url: []const u8,
    title: ?[]const u8,
};

fn parseRefUrlTitle(content: []const u8) UrlTitle {
    if (content.len == 0) return .{ .url = "", .title = null };

    // Check for angle-bracketed URL: <url>
    if (content[0] == '<') {
        if (std.mem.indexOfScalar(u8, content[1..], '>')) |close| {
            const url = content[1 .. 1 + close];
            const after = std.mem.trimStart(u8, content[2 + close ..], " \t");
            return .{ .url = url, .title = parseTitle(after) };
        }
    }

    // Plain URL — up to first space or end
    var url_end: usize = 0;
    while (url_end < content.len and content[url_end] != ' ' and content[url_end] != '\t') url_end += 1;
    const url = content[0..url_end];

    const after = std.mem.trimStart(u8, content[url_end..], " \t");
    return .{ .url = url, .title = parseTitle(after) };
}

fn parseTitle(content: []const u8) ?[]const u8 {
    if (content.len < 2) return null;
    const open = content[0];
    if (open != '"' and open != '\'' and open != '(') return null;
    const close: u8 = if (open == '(') ')' else open;
    if (content[content.len - 1] == close) {
        return content[1 .. content.len - 1];
    }
    return null;
}

/// Case-insensitive label lookup.
pub fn findRefDef(ref_defs: []const RefDef, label: []const u8) ?RefDef {
    for (ref_defs) |def| {
        if (shared.eqlIgnoreCase(def.label, label)) return def;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classifyRefDef — basic" {
    const r = classifyRefDef("[ref]: https://example.com").?;
    try testing.expectEqualStrings("ref", r.label);
    try testing.expectEqualStrings("https://example.com", r.url);
    try testing.expectEqual(null, r.title);
}

test "classifyRefDef — with double-quoted title" {
    const r = classifyRefDef("[ref]: https://example.com \"My Title\"").?;
    try testing.expectEqualStrings("ref", r.label);
    try testing.expectEqualStrings("https://example.com", r.url);
    try testing.expectEqualStrings("My Title", r.title.?);
}

test "classifyRefDef — with single-quoted title" {
    const r = classifyRefDef("[ref]: url 'Title'").?;
    try testing.expectEqualStrings("Title", r.title.?);
}

test "classifyRefDef — with paren title" {
    const r = classifyRefDef("[ref]: url (Title)").?;
    try testing.expectEqualStrings("Title", r.title.?);
}

test "classifyRefDef — angle-bracketed URL" {
    const r = classifyRefDef("[ref]: <https://example.com> \"Title\"").?;
    try testing.expectEqualStrings("https://example.com", r.url);
    try testing.expectEqualStrings("Title", r.title.?);
}

test "classifyRefDef — not a ref def" {
    try testing.expectEqual(null, classifyRefDef("not a ref"));
    try testing.expectEqual(null, classifyRefDef("[]: empty label"));
    try testing.expectEqual(null, classifyRefDef("[no-colon]"));
}

test "findRefDef — case insensitive" {
    const defs = [_]RefDef{
        .{ .label = "Foo", .url = "url1", .title = null },
        .{ .label = "bar", .url = "url2", .title = null },
    };
    const f = findRefDef(&defs, "foo").?;
    try testing.expectEqualStrings("url1", f.url);
    const b = findRefDef(&defs, "BAR").?;
    try testing.expectEqualStrings("url2", b.url);
    try testing.expectEqual(null, findRefDef(&defs, "baz"));
}
