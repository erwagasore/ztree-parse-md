// bun.zig — stdlib shim for Bun-specific APIs used by bun-md.
//
// Bun's markdown parser (src/md/) imports @import("bun") for a handful of
// runtime helpers. This module provides stdlib equivalents so the parser
// can build without the Bun runtime.
const std = @import("std");

// ─── Error types ───────────────────────────────────────────────────────────

/// In Bun this propagates JavaScript exceptions. The parser's allocator calls
/// also produce OutOfMemory through `try`, so it must be in the set.
pub const JSError = error{ JSError, JSTerminated, OutOfMemory };

/// Returned by the stack-overflow guard.
pub const StackOverflow = error{StackOverflow};

// ─── Stack overflow guard ──────────────────────────────────────────────────

/// Bun's StackCheck inspects the real stack pointer. For standalone use a
/// simple depth counter is sufficient — the parser's recursion depth is
/// bounded by document nesting.
pub const StackCheck = struct {
    depth: u32 = 0,
    const max_depth: u32 = 10_000;

    pub fn init() StackCheck {
        return .{};
    }

    pub fn isSafeToRecurse(self: *StackCheck) bool {
        if (self.depth >= max_depth) return false;
        self.depth += 1;
        return true;
    }
};

pub fn throwStackOverflow() error{StackOverflow} {
    return error.StackOverflow;
}

// ─── Containers ────────────────────────────────────────────────────────────

pub const bit_set = struct {
    pub fn StaticBitSet(comptime size: u16) type {
        return std.StaticBitSet(size);
    }
};

pub fn StringHashMapUnmanaged(comptime V: type) type {
    return std.StringHashMapUnmanaged(V);
}

// ─── String utilities ──────────────────────────────────────────────────────

pub const strings = struct {
    /// Number of bytes in a UTF-8 sequence given its first byte.
    pub fn codepointSize(comptime _: type, first_byte: u8) u3 {
        return std.unicode.utf8ByteSequenceLength(first_byte) catch 1;
    }

    /// Decode a UTF-8 sequence, returning `replacement` on invalid input.
    pub fn decodeWTF8RuneT(buf: *const [4]u8, seq_len: u3, comptime _: type, replacement: u21) u21 {
        return std.unicode.utf8Decode(buf[0..seq_len]) catch replacement;
    }

    /// Encode a codepoint as UTF-8, returning the sequence length.
    pub fn encodeWTF8RuneT(buf: *[4]u8, comptime _: type, codepoint: u21) u3 {
        const len = std.unicode.utf8Encode(codepoint, buf) catch return 0;
        return @intCast(len);
    }

    /// Case-insensitive ASCII comparison (slices may differ in length).
    pub fn eqlCaseInsensitiveASCIIICheckLength(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    /// Case-insensitive ASCII comparison (caller guarantees equal length).
    pub fn eqlCaseInsensitiveASCIIIgnoreLength(a: []const u8, b: []const u8) bool {
        return std.ascii.eqlIgnoreCase(a, b);
    }

    /// Find first occurrence of any needle character in haystack.
    pub fn indexOfAny(haystack: []const u8, needles: anytype) ?usize {
        return std.mem.indexOfAny(u8, haystack, needles);
    }

    /// Find first occurrence of `needle` in `haystack` starting at `start`.
    pub fn indexOfCharPos(haystack: []const u8, needle: u8, start: usize) ?usize {
        return std.mem.indexOfScalarPos(u8, haystack, start, needle);
    }
};
