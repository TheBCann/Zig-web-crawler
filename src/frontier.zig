const std = @import("std");

pub const Entry = struct {
    url: []const u8,
    priority: u32,
    depth: u16,
};

fn comparePriority(_: void, a: Entry, b: Entry) std.math.Order {
    return std.math.order(b.priority, a.priority);
}

pub const Frontier = struct {
    queue: std.PriorityQueue(Entry, void, comparePriority),
    visited: std.StringHashMap(void),
    signatures: std.AutoHashMap([32]u8, void),

    pub fn init(allocator: std.mem.Allocator) Frontier {
        return .{
            .queue = .initContext({}),
            .visited = std.StringHashMap(void).init(allocator),
            .signatures = std.AutoHashMap([32]u8, void).init(allocator),
        };
    }

    pub fn deinit(self: *Frontier, allocator: std.mem.Allocator) void {
        var it = self.visited.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        self.visited.deinit();

        while (self.queue.pop()) |entry| allocator.free(entry.url);
        self.queue.deinit(allocator);

        self.signatures.deinit();
    }

    pub fn addUrl(self: *Frontier, allocator: std.mem.Allocator, url: []const u8, priority: u32, depth: u16) !void {
        if (self.visited.contains(url)) return;

        const owned = try allocator.dupe(u8, url);
        errdefer allocator.free(owned);

        try self.visited.put(owned, {});
        try self.queue.push(allocator, .{
            .url = try allocator.dupe(u8, url),
            .priority = priority,
            .depth = depth,
        });
    }

    pub fn pop(self: *Frontier) ?Entry {
        return self.queue.pop();
    }

    pub fn count(self: *const Frontier) usize {
        return self.queue.count();
    }

    pub fn isContentDuplicate(self: *const Frontier, sig: [32]u8) bool {
        return self.signatures.contains(sig);
    }

    pub fn markContent(self: *Frontier, sig: [32]u8) !void {
        try self.signatures.put(sig, {});
    }
};
