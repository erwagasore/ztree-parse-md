/// HTML block detection — raw HTML blocks preserved as-is.
const std = @import("std");
const shared = @import("../utils.zig");

/// Check if a line starts an HTML block.
/// Returns true for lines starting with `<tag`, `</tag`, or `<!--`.
pub fn isHtmlBlockStart(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    if (trimmed.len < 2 or trimmed[0] != '<') return false;

    // HTML comment
    if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, "<!--")) return true;

    // Processing instruction <?
    if (trimmed.len >= 2 and trimmed[1] == '?') return true;

    // DOCTYPE
    if (trimmed.len >= 2 and trimmed[1] == '!' and trimmed.len >= 3 and std.ascii.isAlphabetic(trimmed[2])) return true;

    // CDATA
    if (std.mem.startsWith(u8, trimmed, "<![CDATA[")) return true;

    // Closing tag
    const tag_start: usize = if (trimmed[1] == '/') 2 else 1;
    if (tag_start >= trimmed.len) return false;

    // Tag name must start with letter
    if (!std.ascii.isAlphabetic(trimmed[tag_start])) return false;

    // Find end of tag name
    var name_end = tag_start;
    while (name_end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[name_end]) or trimmed[name_end] == '-')) {
        name_end += 1;
    }
    if (name_end == tag_start) return false;

    const name = trimmed[tag_start..name_end];

    // Only block-level HTML tags trigger HTML blocks
    return isBlockLevelTag(name);
}

fn isBlockLevelTag(name: []const u8) bool {
    const block_tags = [_][]const u8{
        "address", "article", "aside", "base", "basefont", "blockquote", "body",
        "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
        "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html",
        "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes",
        "ol", "optgroup", "option", "p", "param", "pre", "script", "section",
        "source", "style", "summary", "table", "tbody", "td", "template", "textarea",
        "tfoot", "th", "thead", "title", "tr", "track", "ul",
    };
    for (block_tags) |tag| {
        if (shared.eqlIgnoreCase(name, tag)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isHtmlBlockStart — div" {
    try testing.expect(isHtmlBlockStart("<div>"));
    try testing.expect(isHtmlBlockStart("<div class=\"foo\">"));
    try testing.expect(isHtmlBlockStart("</div>"));
}

test "isHtmlBlockStart — comment" {
    try testing.expect(isHtmlBlockStart("<!-- comment -->"));
    try testing.expect(isHtmlBlockStart("<!--"));
}

test "isHtmlBlockStart — common tags" {
    try testing.expect(isHtmlBlockStart("<section>"));
    try testing.expect(isHtmlBlockStart("<nav>"));
    try testing.expect(isHtmlBlockStart("<table>"));
    try testing.expect(isHtmlBlockStart("<pre>"));
    try testing.expect(isHtmlBlockStart("<script>"));
    try testing.expect(isHtmlBlockStart("<style>"));
}

test "isHtmlBlockStart — not inline tags" {
    try testing.expect(!isHtmlBlockStart("<em>"));
    try testing.expect(!isHtmlBlockStart("<strong>"));
    try testing.expect(!isHtmlBlockStart("<a href>"));
    try testing.expect(!isHtmlBlockStart("<span>"));
    try testing.expect(!isHtmlBlockStart("<img>"));
}

test "isHtmlBlockStart — not plain text" {
    try testing.expect(!isHtmlBlockStart("not html"));
    try testing.expect(!isHtmlBlockStart("< spaces"));
}
