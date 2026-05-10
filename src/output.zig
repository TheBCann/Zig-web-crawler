const std = @import("std");
const Io = std.Io;

pub const Result = struct {
    url: []const u8,
    status: u16,
    depth: u16,
    content_size: usize,
    is_duplicate: bool = false,
};

pub const OutputSink = struct {
    io: Io,
    mutex: Io.Mutex = Io.Mutex.init,
    results: std.ArrayList(Result) = .empty,

    pub fn init(io: Io) OutputSink {
        return .{ .io = io };
    }

    pub fn deinit(self: *OutputSink, allocator: std.mem.Allocator) void {
        for (self.results.items) |r| {
            allocator.free(r.url);
        }
        self.results.deinit(allocator);
    }


    pub fn print(self: *OutputSink, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        var buf: [4096]u8 = undefined;
        var w = Io.File.stdout().writer(self.io, &buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
    }

    pub fn printStatus(self: *OutputSink, status: std.http.Status, url: []const u8) void {
        const code = @intFromEnum(status);
        const color: u8 = switch (code) {
            200...299 => 32,
            300...399 => 34,
            400...499 => 31,
            else => 33,
        };
        self.print("\x1b[{d}m[{d}]\x1b[0m {s}\n", .{ color, code, url });
    }


    pub fn record(self: *OutputSink, allocator: std.mem.Allocator, result: Result) void {
        const duped_url = allocator.dupe(u8, result.url) catch return;

        var stored_result = result;
        stored_result.url = duped_url;

        self.mutex.lock(self.io) catch {
            allocator.free(duped_url);
            return;
        };
        defer self.mutex.unlock(self.io);

        self.results.append(allocator, stored_result) catch {
            allocator.free(duped_url);
        };
    }


    pub fn toJson(self: *OutputSink, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "[\n");

        for (self.results.items, 0..) |r, i| {
            try out.print(allocator,
                \\  {{
                \\    "url": "{s}",
                \\    "status": {d},
                \\    "depth": {d},
                \\    "content_size": {d},
                \\    "is_duplicate": {s}
                \\  }}
            , .{
                r.url,
                r.status,
                r.depth,
                r.content_size,
                if (r.is_duplicate) "true" else "false",
            });
            if (i < self.results.items.len - 1) {
                try out.appendSlice(allocator, ",\n");
            } else {
                try out.appendSlice(allocator, "\n");
            }
        }

        try out.appendSlice(allocator, "]\n");
        return out.toOwnedSlice(allocator);
    }

    pub fn printJson(self: *OutputSink, allocator: std.mem.Allocator) void {
        const json = self.toJson(allocator) catch return;
        defer allocator.free(json);

        var buf: [4096]u8 = undefined;
        var w = Io.File.stdout().writer(self.io, &buf);
        w.interface.print("{s}", .{json}) catch {};
        w.interface.flush() catch {};
    }
};
