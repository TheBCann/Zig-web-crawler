const std = @import("std");
const crypto = std.crypto;

pub const Page = struct {
    url: []const u8,
    contents: ?[]u8,
    signature: ?[32]u8,
    depth: u16,

    pub fn init(url: []const u8) Page {
        return .{
            .url = url,
            .contents = null,
            .signature = null,
            .depth = 0,
        };
    }

    pub fn deinit(self: *Page, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.contents) |c| allocator.free(c);
    }

    pub fn computeSignature(self: *Page) void {
        if (self.contents) |c| {
            var hasher = crypto.hash.sha2.Sha256.init(.{});
            hasher.update(c);
            self.signature = hasher.finalResult();
        }
    }
};
