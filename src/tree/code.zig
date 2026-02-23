/// Code block tree builder — `pre > code` with optional language class.
const std = @import("std");
const ztree = @import("ztree");
const Node = ztree.Node;
const Block = @import("../block/root.zig");

/// Build a `pre > code` node from a fenced code block.
pub fn buildCodeBlock(allocator: std.mem.Allocator, block: Block.Block) !Node {
    const code_children = try allocator.alloc(Node, 1);
    code_children[0] = .{ .text = block.content };

    const code_attrs: []const ztree.Attr = if (block.lang.len > 0) blk: {
        const prefix = "language-";
        const class_value = try allocator.alloc(u8, prefix.len + block.lang.len);
        @memcpy(class_value[0..prefix.len], prefix);
        @memcpy(class_value[prefix.len..], block.lang);
        const attrs = try allocator.alloc(ztree.Attr, 1);
        attrs[0] = .{ .key = "class", .value = class_value };
        break :blk attrs;
    } else &.{};

    const pre_children = try allocator.alloc(Node, 1);
    pre_children[0] = .{ .element = .{
        .tag = "code",
        .attrs = code_attrs,
        .children = code_children,
    } };

    return .{ .element = .{
        .tag = "pre",
        .attrs = &.{},
        .children = pre_children,
    } };
}
