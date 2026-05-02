/// ztree-parse-md — GFM Markdown parser for ztree.
///
/// Parses Markdown text into a ztree Node tree. Uses Bun's md4c-based
/// parser as the backend, with a SAX-to-tree adapter that builds ztree
/// nodes from the parser's enter/leave/text event stream.
const std = @import("std");
const ztree = @import("ztree");
const adapter = @import("adapter.zig");

pub const Node = ztree.Node;
pub const ParseError = adapter.ParseError;

/// Owned parsed Markdown document.
///
/// Use `parseOwned()` when you want the parser to manage the arena for you.
/// Call `deinit()` when the tree is no longer needed.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

/// Parse Markdown text into a ztree Node tree.
///
/// The returned tree is allocated with `arena`. Use an arena-like allocator;
/// individual node deallocation is not supported.
pub fn parse(arena: std.mem.Allocator, input: []const u8) ParseError!Node {
    return adapter.parse(arena, input);
}

/// Parse Markdown text into an owned arena-backed document.
pub fn parseOwned(backing_allocator: std.mem.Allocator, input: []const u8) ParseError!Document {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();

    return .{
        .root = try parse(arena.allocator(), input),
        .arena = arena,
    };
}

test "parseOwned returns arena-backed document" {
    var doc = try parseOwned(std.testing.allocator, "# Hello");
    defer doc.deinit();

    try std.testing.expectEqual(.element, std.meta.activeTag(doc.root));
    try std.testing.expectEqualStrings("h1", doc.root.element.tag);
}

test {
    _ = adapter;
}
