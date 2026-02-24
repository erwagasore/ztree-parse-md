/// ztree-parse-md — GFM Markdown parser for ztree.
///
/// Parses Markdown text into a ztree Node tree. Uses Bun's md4c-based
/// parser as the backend, with a SAX-to-tree adapter that builds ztree
/// nodes from the parser's enter/leave/text event stream.
const std = @import("std");
const ztree = @import("ztree");
const md = @import("bun-md");
const adapter = @import("adapter.zig");

/// Parse Markdown text into a ztree Node tree.
///
/// The returned tree is allocated with `allocator`. Call `arena.deinit()`
/// (if using an arena) to free everything at once.
pub fn parse(allocator: std.mem.Allocator, input: []const u8) error{ OutOfMemory, StackOverflow }!ztree.Node {
    return adapter.parse(allocator, input);
}

test {
    _ = adapter;
}
