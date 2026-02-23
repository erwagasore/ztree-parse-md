/// Table line classifiers — separator and row detection.
const std = @import("std");

/// Check if a line is a GFM table separator (e.g. `| --- | :---: |`).
pub fn isTableSeparator(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    var has_dash = false;
    var has_pipe = false;
    for (trimmed) |c| {
        switch (c) {
            '-' => has_dash = true,
            '|' => has_pipe = true,
            ':', ' ' => {},
            else => return false,
        }
    }
    return has_dash and has_pipe;
}

/// Check if a line looks like a table row (contains a pipe character).
pub fn isTableRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "isTableSeparator — basic" {
    try testing.expect(isTableSeparator("| --- | --- |"));
    try testing.expect(isTableSeparator("|---|---|"));
    try testing.expect(isTableSeparator("| :--- | :---: | ---: |"));
    try testing.expect(!isTableSeparator("not a separator"));
    try testing.expect(!isTableSeparator("| abc | def |"));
    try testing.expect(!isTableSeparator("---"));
}
