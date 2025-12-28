const std = @import("std");

const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

var stdout_mutex = std.Thread.Mutex{};

const esc = "\x1B";
const csi = esc ++ "[";
const reset = csi ++ "0m";

const Color = enum(u8) {
    Default = 39,
    Red = 31,
    Green = 32,
    Yellow = 33,
    Blue = 34,
    Magenta = 35,
    Cyan = 36,
    White = 37,
};

const Spider = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList([]const u8),
    visited: std.StringHashMap(void),
    base_host: []const u8,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, seed_url: []const u8) !Spider {
        const uri = try std.Uri.parse(seed_url);
        if (uri.host == null) return error.InvalidUrl;

        const host = try allocator.dupe(u8, uri.host.?.percent_encoded);

        var self = Spider{
            .allocator = allocator,
            .queue = try std.ArrayList([]const u8).initCapacity(allocator, 100),
            .visited = std.StringHashMap(void).init(allocator),
            .base_host = host,
        };

        const seed_copy = try allocator.dupe(u8, seed_url);
        try self.queue.append(allocator, seed_copy);
        return self;
    }

    pub fn deinit(self: *Spider) void {
        self.allocator.free(self.base_host);
        var it = self.visited.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.visited.deinit();
        for (self.queue.items) |item| {
            self.allocator.free(item);
        }
        self.queue.deinit(self.allocator);
    }

    pub fn getNextUrl(self: *Spider) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.pop();
    }

    pub fn addUrl(self: *Spider, url: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.visited.contains(url)) return;

        const url_owned = try self.allocator.dupe(u8, url);
        try self.visited.put(url_owned, {});
        try self.queue.append(self.allocator, try self.allocator.dupe(u8, url));
    }
};

fn getStatusColor(status: std.http.Status) u8 {
    const code = @intFromEnum(status);
    return switch (code) {
        200...299 => @intFromEnum(Color.Green),
        300...399 => @intFromEnum(Color.Blue),
        400...499 => @intFromEnum(Color.Red),
        500...599 => @intFromEnum(Color.Yellow),
        else => @intFromEnum(Color.White),
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: std.Io.Threaded = .init(allocator);
    defer threaded.deinit();
    const io = threaded.io();

    var args = std.process.args();
    _ = args.next();
    const seed = args.next() orelse {
        safePrint("Usage: ./spider <url>\n", .{});
        return;
    };

    var spider = try Spider.init(allocator, seed);
    defer spider.deinit();

    const worker_count = 4;
    safePrint("🕷️  Starting Spider on {s} with {d} async tasks...\n", .{ seed, worker_count });

    var futures = std.ArrayList(std.Io.Future(anyerror!void)).empty;
    defer futures.deinit(allocator);

    for (0..worker_count) |_| {
        const fut = try io.concurrent(worker, .{ io, allocator, &spider });
        try futures.append(allocator, fut);
    }

    for (futures.items) |*fut| {
        try fut.await(io);
    }

    safePrint("\n🏁 Crawl finished. Visited {d} pages.\n", .{spider.visited.count()});
}

fn worker(io: std.Io, allocator: std.mem.Allocator, spider: *Spider) anyerror!void {
    var retries: usize = 0;

    while (retries < 10) {
        const target_url_opt = spider.getNextUrl();

        if (target_url_opt == null) {
            // Sleep for 100ms (100 * 1,000,000 nanoseconds)
            try io.sleep(std.Io.Duration.fromNanoseconds(100 * 1_000_000), .awake);
            retries += 1;
            continue;
        }
        retries = 0;

        const target_url = target_url_opt.?;
        defer allocator.free(target_url);

        const uri = std.Uri.parse(target_url) catch continue;

        // --- TIMESTAMP FIX START ---
        // 1. Get POSIX time (CLOCK_REALTIME for wall clock)

        // 2. Convert to nanoseconds using the Zig 0.16 field names (.sec, .nsec)

        var client = std.http.Client{ .allocator = allocator, .io = io };
        defer client.deinit();
        // --- TIMESTAMP FIX END ---

        var body = std.Io.Writer.Allocating.init(allocator);
        defer body.deinit();

        const body_interface = &body.writer;

        const response = client.fetch(.{
            .method = .GET,
            .location = .{ .uri = uri },
            .response_writer = body_interface,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = USER_AGENT },
            },
        }) catch {
            safePrint("❌ Error fetching {s}\n", .{target_url});
            continue;
        };

        const color_code = getStatusColor(response.status);
        safePrint(csi ++ "{d}m[{d}]" ++ reset ++ " {s}\n", .{ color_code, @intFromEnum(response.status), target_url });

        if (response.status == .ok) {
            const html = body.written();
            var it = std.mem.splitScalar(u8, html, '>');

            while (it.next()) |chunk| {
                if (std.mem.indexOf(u8, chunk, "href=\"")) |found_index| {
                    const url_start = found_index + 6;
                    const remainder = chunk[url_start..];

                    if (std.mem.indexOf(u8, remainder, "\"")) |quote_end| {
                        const raw_url = remainder[0..quote_end];
                        if (std.mem.startsWith(u8, raw_url, "//")) {
                            const full = std.fmt.allocPrint(allocator, "https:{s}", .{raw_url}) catch continue;
                            defer allocator.free(full);
                            spider.addUrl(full) catch {};
                        } else if (std.mem.startsWith(u8, raw_url, "/")) {
                            const full = std.fmt.allocPrint(allocator, "https://{s}{s}", .{ spider.base_host, raw_url }) catch continue;
                            defer allocator.free(full);
                            spider.addUrl(full) catch {};
                        } else if (std.mem.startsWith(u8, raw_url, "http")) {
                            spider.addUrl(raw_url) catch {};
                        }
                    }
                }
            }
        }
    }
}

fn safePrint(comptime fmt: []const u8, args: anytype) void {
    stdout_mutex.lock();
    defer stdout_mutex.unlock();

    var buf: [4096]u8 = undefined;
    var stdout_buffered = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_buffered.interface;

    stdout.print(fmt, args) catch {};
    stdout.flush() catch {};
}
