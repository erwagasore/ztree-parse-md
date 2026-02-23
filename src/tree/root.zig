/// Tree builder — converts a flat list of Block descriptors into a ztree Node tree.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Block = @import("../block/root.zig");
const inlines = @import("../inlines/root.zig");

// Sub-modules
const list_mod = @import("list.zig");
const code_mod = @import("code.zig");
const table_mod = @import("table.zig");

// Re-exports
pub const buildList = list_mod.buildList;
pub const buildCodeBlock = code_mod.buildCodeBlock;
pub const buildTableNode = table_mod.buildTableNode;

/// The parse function type — passed in to break the circular dependency for blockquote recursion.
pub const ParseFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error!Node;

/// Build a ztree Node tree from a flat list of blocks.
pub fn buildTree(allocator: std.mem.Allocator, blocks: []const Block.Block, parseFn: ParseFn) std.mem.Allocator.Error!Node {
    if (blocks.len == 0) return .{ .fragment = &.{} };

    var nodes: std.ArrayList(Node) = .empty;
    var i: usize = 0;

    while (i < blocks.len) {
        const block = blocks[i];

        if (block.tag == .ul_item or block.tag == .ol_item) {
            const result = try buildList(allocator, blocks, i);
            try nodes.append(allocator, result.node);
            i = result.next;
        } else if (block.tag == .table) {
            try nodes.append(allocator, try buildTableNode(allocator, block.content));
            i += 1;
        } else if (block.tag == .blockquote) {
            const inner = try parseFn(allocator, block.content);
            try nodes.append(allocator, .{ .element = .{
                .tag = "blockquote",
                .attrs = &.{},
                .children = inner.fragment,
            } });
            i += 1;
        } else if (block.tag == .hr) {
            try nodes.append(allocator, .{ .element = .{
                .tag = "hr",
                .attrs = &.{},
                .children = &.{},
            } });
            i += 1;
        } else if (block.tag == .pre) {
            try nodes.append(allocator, try buildCodeBlock(allocator, block));
            i += 1;
        } else {
            const children = try inlines.parseInlines(allocator, block.content);
            try nodes.append(allocator, .{ .element = .{
                .tag = Block.tagName(block.tag),
                .attrs = &.{},
                .children = children,
            } });
            i += 1;
        }
    }

    return .{ .fragment = try nodes.toOwnedSlice(allocator) };
}

// Force sub-module tests to be included
comptime {
    _ = list_mod;
    _ = code_mod;
    _ = table_mod;
}
