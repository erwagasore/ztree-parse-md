/// Block scanner — line-by-line classification into a flat list of Block descriptors.
const std = @import("std");

// Sub-modules
const heading = @import("heading.zig");
const fence = @import("fence.zig");
const list = @import("list.zig");
const line = @import("line.zig");
const blockquote = @import("blockquote.zig");
const tbl = @import("table.zig");
const footnote = @import("footnote.zig");
const refdef = @import("refdef.zig");
const html = @import("html.zig");
const shared = @import("../utils.zig");

// Re-exports for external use
pub const classifyHeading = heading.classifyHeading;
pub const classifySetextUnderline = heading.classifySetextUnderline;
pub const classifyFenceOpen = fence.classifyFenceOpen;
pub const isClosingFence = fence.isClosingFence;
pub const classifyListItem = list.classifyListItem;
pub const isBlankLine = line.isBlankLine;
pub const isThematicBreak = line.isThematicBreak;
pub const stripBlockquotePrefix = blockquote.stripBlockquotePrefix;
pub const isTableSeparator = tbl.isTableSeparator;
pub const isTableRow = tbl.isTableRow;
pub const classifyFootnoteDef = footnote.classifyFootnoteDef;
pub const classifyRefDef = refdef.classifyRefDef;
pub const RefDef = refdef.RefDef;
pub const findRefDef = refdef.findRefDef;
pub const isHtmlBlockStart = html.isHtmlBlockStart;
pub const joinLines = shared.joinLines;

pub const Tag = enum { h1, h2, h3, h4, h5, h6, p, pre, hr, blockquote, ul_item, ol_item, table, footnote_def, ref_def, html_block, blank };

pub const Block = struct {
    tag: Tag,
    content: []const u8,
    lang: []const u8 = "",
    indent: u8 = 0,
    checked: ?bool = null,
    loose: bool = false,
};

/// Flush any pending paragraph into the blocks list.
fn flushParagraph(blocks: *std.ArrayList(Block), allocator: std.mem.Allocator, input: []const u8, para_start: *?usize, para_end: usize) !void {
    if (para_start.*) |start| {
        try blocks.append(allocator, .{ .tag = .p, .content = input[start..para_end] });
        para_start.* = null;
    }
}

/// Scan input line-by-line and produce a flat list of Block descriptors.
pub fn parseBlocks(allocator: std.mem.Allocator, input: []const u8) ![]const Block {
    var blocks: std.ArrayList(Block) = .empty;

    var para_start: ?usize = null;
    var para_end: usize = 0;

    // Fence state
    var in_fence = false;
    var fence_backtick_count: usize = 0;
    var fence_lang: []const u8 = "";
    var fence_content_start: usize = 0;

    // Blockquote state
    var bq_lines: std.ArrayList([]const u8) = .empty;

    // Table state
    var in_table = false;
    var table_start: usize = 0;
    var table_end: usize = 0;

    var pos: usize = 0;
    while (pos < input.len) {
        const line_start = pos;
        const line_end = shared.nextLineEnd(input, pos);
        const raw_line = input[line_start..line_end];
        pos = shared.nextLineStart(input, line_end);

        if (in_fence) {
            if (isClosingFence(raw_line, fence_backtick_count)) {
                const content = if (fence_content_start < line_start)
                    input[fence_content_start..line_start]
                else
                    "";
                try blocks.append(allocator, .{ .tag = .pre, .content = content, .lang = fence_lang });
                in_fence = false;
            }
            continue;
        }

        // Blockquote line — collect stripped lines
        if (stripBlockquotePrefix(raw_line)) |stripped| {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            try bq_lines.append(allocator, stripped);
            continue;
        }

        // Not a blockquote line — flush any accumulated blockquote
        if (bq_lines.items.len > 0) {
            const inner = try joinLines(allocator, bq_lines.items);
            try blocks.append(allocator, .{ .tag = .blockquote, .content = inner });
            bq_lines.clearRetainingCapacity();
        }

        if (isBlankLine(raw_line)) {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            // Emit blank marker so tree builder can detect loose lists
            try blocks.append(allocator, .{ .tag = .blank, .content = "" });
            continue;
        }

        // Setext heading underline — only valid when there's a pending paragraph
        // Must check before thematic break so `---` under text becomes h2, not hr
        if (para_start != null) {
            if (classifySetextUnderline(raw_line)) |setext_tag| {
                const start = para_start.?;
                // Only single-line paragraph becomes a setext heading
                // (multi-line would be ambiguous)
                const para_content = input[start..para_end];
                if (std.mem.indexOfScalar(u8, para_content, '\n') == null) {
                    try blocks.append(allocator, .{ .tag = setext_tag, .content = para_content });
                    para_start = null;
                    continue;
                }
            }
        }

        if (isThematicBreak(raw_line)) {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            try blocks.append(allocator, .{ .tag = .hr, .content = "" });
            continue;
        }

        if (classifyListItem(raw_line)) |item| {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            try blocks.append(allocator, .{
                .tag = item.tag,
                .content = item.content,
                .indent = item.indent,
                .checked = item.checked,
            });

            // Look ahead for multi-paragraph list items:
            // blank line followed by indented continuation (indent >= marker + 2)
            const continuation_indent = item.indent + 2;
            while (pos < input.len) {
                const look_end = shared.nextLineEnd(input, pos);
                const look_line = input[pos..look_end];

                if (isBlankLine(look_line)) {
                    const after_blank = shared.nextLineStart(input, look_end);
                    // Check if next line is indented continuation
                    if (after_blank >= input.len) break;
                    const cont_end = shared.nextLineEnd(input, after_blank);
                    const cont_line = input[after_blank..cont_end];

                    // Count leading spaces
                    var spaces: usize = 0;
                    while (spaces < cont_line.len and cont_line[spaces] == ' ') spaces += 1;

                    if (spaces >= continuation_indent and !isBlankLine(cont_line) and classifyListItem(cont_line) == null) {
                        // This is a continuation paragraph — mark previous item as loose
                        // and append content
                        const prev = &blocks.items[blocks.items.len - 1];
                        prev.loose = true;
                        const cont_content = cont_line[continuation_indent..];
                        // Join with previous content using \n\n separator
                        const joined = try std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ prev.content, cont_content });
                        prev.content = joined;
                        pos = shared.nextLineStart(input, cont_end);
                    } else {
                        break; // Not continuation — don't consume blank line
                    }
                } else {
                    break;
                }
            }
            continue;
        }

        if (classifyFenceOpen(raw_line)) |f| {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            in_fence = true;
            fence_backtick_count = f.backtick_count;
            fence_lang = f.lang;
            fence_content_start = pos;
            continue;
        }

        if (classifyFootnoteDef(raw_line)) |f| {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            try blocks.append(allocator, .{ .tag = .footnote_def, .content = f.content, .lang = f.id });
            continue;
        }

        if (classifyRefDef(raw_line) != null) {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            // Store raw line so tree builder can re-parse label/url/title
            try blocks.append(allocator, .{ .tag = .ref_def, .content = raw_line });
            continue;
        }

        if (classifyHeading(raw_line)) |h| {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            try blocks.append(allocator, .{ .tag = h.tag, .content = h.content });
            continue;
        }

        // HTML block — starts with block-level tag, ends at blank line
        if (isHtmlBlockStart(raw_line)) {
            try flushParagraph(&blocks, allocator, input, &para_start, para_end);
            const html_start = line_start;
            var html_end = line_end;
            // Collect lines until blank line or end of input
            while (pos < input.len) {
                const next_end = shared.nextLineEnd(input, pos);
                const next_line = input[pos..next_end];
                pos = shared.nextLineStart(input, next_end);
                if (isBlankLine(next_line)) break;
                html_end = next_end;
            }
            try blocks.append(allocator, .{ .tag = .html_block, .content = input[html_start..html_end] });
            continue;
        }

        // Indented code block — 4+ spaces, only when no paragraph is being accumulated
        if (para_start == null and !in_table and isIndentedCodeLine(raw_line)) {
            const result = try collectIndentedCode(allocator, input, raw_line, pos);
            try blocks.append(allocator, .{ .tag = .pre, .content = result.content });
            pos = result.new_pos;
            continue;
        }

        // Table body rows — continue collecting while in table mode
        if (in_table) {
            if (isTableRow(raw_line)) {
                table_end = line_end;
                continue;
            } else {
                try blocks.append(allocator, .{ .tag = .table, .content = input[table_start..table_end] });
                in_table = false;
            }
        }

        // Table separator — check if previous paragraph line is a header
        if (!in_table and isTableSeparator(raw_line)) {
            if (para_start) |start| {
                const header_content = input[start..para_end];
                if (std.mem.indexOfScalar(u8, header_content, '\n') == null and std.mem.indexOfScalar(u8, header_content, '|') != null) {
                    table_start = start;
                    table_end = line_end;
                    in_table = true;
                    para_start = null;
                    continue;
                }
            }
        }

        // Paragraph line
        if (para_start == null) {
            para_start = line_start;
        }
        para_end = line_end;
    }

    // Flush trailing blockquote
    if (bq_lines.items.len > 0) {
        const inner = try joinLines(allocator, bq_lines.items);
        try blocks.append(allocator, .{ .tag = .blockquote, .content = inner });
    }

    // Flush trailing table
    if (in_table) {
        try blocks.append(allocator, .{ .tag = .table, .content = input[table_start..table_end] });
    }

    // Flush trailing paragraph
    try flushParagraph(&blocks, allocator, input, &para_start, para_end);

    // Unclosed fence — content runs to end of input
    if (in_fence) {
        const content = if (fence_content_start < input.len)
            input[fence_content_start..]
        else
            "";
        try blocks.append(allocator, .{ .tag = .pre, .content = content, .lang = fence_lang });
    }

    return try blocks.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Extracted block collectors
// ---------------------------------------------------------------------------

fn isIndentedCodeLine(raw: []const u8) bool {
    return raw.len >= 4 and raw[0] == ' ' and raw[1] == ' ' and raw[2] == ' ' and raw[3] == ' ';
}

const CollectResult = struct {
    content: []const u8,
    new_pos: usize,
};

/// Collect consecutive indented (4+ space) lines into a code block.
fn collectIndentedCode(allocator: std.mem.Allocator, input: []const u8, first_line: []const u8, start_pos: usize) !CollectResult {
    var code_lines: std.ArrayList([]const u8) = .empty;
    try code_lines.append(allocator, first_line[4..]);

    var pos = start_pos;
    while (pos < input.len) {
        const next_end = shared.nextLineEnd(input, pos);
        const next_line = input[pos..next_end];

        if (isIndentedCodeLine(next_line)) {
            try code_lines.append(allocator, next_line[4..]);
            pos = shared.nextLineStart(input, next_end);
        } else if (isBlankLine(next_line)) {
            try code_lines.append(allocator, "");
            pos = shared.nextLineStart(input, next_end);
        } else {
            break;
        }
    }

    // Trim trailing blank lines
    while (code_lines.items.len > 0 and code_lines.items[code_lines.items.len - 1].len == 0) {
        _ = code_lines.pop();
    }

    return .{
        .content = try shared.joinLines(allocator, code_lines.items),
        .new_pos = pos,
    };
}

/// Map a block tag to its HTML element name.
pub fn tagName(tag: Tag) []const u8 {
    return switch (tag) {
        .h1 => "h1",
        .h2 => "h2",
        .h3 => "h3",
        .h4 => "h4",
        .h5 => "h5",
        .h6 => "h6",
        .p => "p",
        .pre => "pre",
        .hr => "hr",
        .blockquote => "blockquote",
        .ul_item, .ol_item => "li",
        .table => "table",
        .footnote_def => "li",
        .ref_def => "",
        .html_block => "",
        .blank => "",
    };
}

// Force sub-module tests to be included
comptime {
    _ = heading;
    _ = fence;
    _ = list;
    _ = line;
    _ = blockquote;
    _ = tbl;
    _ = footnote;
    _ = refdef;
    _ = html;
}
