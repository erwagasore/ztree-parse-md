/// Emphasis handling — `*em*`, `**strong**`, `***em+strong***`.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const inlines = @import("root.zig");

pub const EmphasisResult = struct {
    node: Node,
    end: usize,
};

/// Try to build an emphasis node from a delimiter run (* or _). Returns null if no matching close found.
pub fn handleEmphasis(allocator: std.mem.Allocator, content: []const u8, delim_start: usize, delim_count: usize, delimiter: u8) std.mem.Allocator.Error!?EmphasisResult {
    const after_delims = delim_start + delim_count;

    // Don't open emphasis if followed by space or at end of content
    if (after_delims >= content.len or content[after_delims] == ' ') return null;

    if (delim_count == 3) {
        // ***text*** → em(strong(text))
        if (findExactRun(content, after_delims, delimiter, 3)) |close| {
            const inner = try inlines.parseInlines(allocator, content[after_delims..close]);
            const strong_children = try allocator.alloc(Node, 1);
            strong_children[0] = .{ .element = .{ .tag = "strong", .attrs = &.{}, .children = inner } };
            return .{
                .node = .{ .element = .{ .tag = "em", .attrs = &.{}, .children = strong_children } },
                .end = close + 3,
            };
        }
    }

    if (delim_count >= 2) {
        // **text** → strong(text)
        if (findExactRun(content, after_delims, delimiter, 2)) |close| {
            const inner = try inlines.parseInlines(allocator, content[after_delims..close]);
            return .{
                .node = .{ .element = .{ .tag = "strong", .attrs = &.{}, .children = inner } },
                .end = close + 2,
            };
        }
    }

    if (delim_count >= 1) {
        // *text* → em(text)
        if (findExactRun(content, after_delims, delimiter, 1)) |close| {
            const inner = try inlines.parseInlines(allocator, content[after_delims..close]);
            return .{
                .node = .{ .element = .{ .tag = "em", .attrs = &.{}, .children = inner } },
                .end = close + 1,
            };
        }
    }

    return null;
}

/// Find a delimiter run of exactly `count` length, starting search at `start`.
/// Skips runs preceded by a space (not valid closers).
pub fn findExactRun(content: []const u8, start: usize, delimiter: u8, count: usize) ?usize {
    var pos = start;
    while (pos < content.len) {
        if (content[pos] == delimiter) {
            const run_start = pos;
            while (pos < content.len and content[pos] == delimiter) pos += 1;
            if (pos - run_start == count) {
                // Skip if preceded by space
                if (run_start > 0 and content[run_start - 1] == ' ') continue;
                return run_start;
            }
        } else {
            pos += 1;
        }
    }
    return null;
}
