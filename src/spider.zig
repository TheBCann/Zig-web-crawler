const std = @import("std");

// "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

// A struct to manage the chaos of multiple threads
const Spider = struct {
    allocator: std.mem.Allocator,

    // Shared Data (Protected by Mutex)
    mutex: std.Thread.Mutex = .{},
    queue: std.ArrayList([]const u8),
    visited: std.StringHashMap(void),

    // Status
    base_host: []const u8,
    // max_urls: usize = 100, // Safety brake!

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

        // if (self.visited.count() >= self.max_urls) return;
        if (self.visited.contains(url)) return;

        const url_owned = try self.allocator.dupe(u8, url);
        try self.visited.put(url_owned, {});

        try self.queue.append(self.allocator, try self.allocator.dupe(u8, url));
    }
};

// Global Mutex for stdout
var stdout_mutex = std.Thread.Mutex{};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Setup
    var args = std.process.args();
    _ = args.next();
    const seed = args.next() orelse {
        var buf: [1024]u8 = undefined;
        var fbs = std.Io.fixedBufferStream(&buf);
        fbs.writer().print("Usage: ./spider <url>\n", .{}) catch {};
        std.fs.File.stdout().writeAll(fbs.getWritten()) catch {};
        return;
    };

    var spider = try Spider.init(allocator, seed);
    defer spider.deinit();

    // 2. Spawn Workers
    var threads = std.ArrayList(std.Thread){};
    defer threads.deinit(allocator);

    const worker_count = 4;

    // Print Start Message
    {
        var buf: [1024]u8 = undefined;
        var fbs = std.Io.fixedBufferStream(&buf);
        fbs.writer().print("🕷️  Starting Spider on {s} with {d} threads...\n", .{ seed, worker_count }) catch {};
        std.fs.File.stdout().writeAll(fbs.getWritten()) catch {};
    }

    for (0..worker_count) |_| {
        const t = try std.Thread.spawn(.{}, worker, .{ allocator, &spider });
        try threads.append(allocator, t);
    }

    // 3. Wait
    for (threads.items) |t| {
        t.join();
    }

    // Print Finish Message
    {
        var buf: [1024]u8 = undefined;
        var fbs = std.Io.fixedBufferStream(&buf);
        fbs.writer().print("\n🏁 Crawl finished. Visited {d} pages.\n", .{spider.visited.count()}) catch {};
        std.fs.File.stdout().writeAll(fbs.getWritten()) catch {};
    }
}

fn worker(allocator: std.mem.Allocator, spider: *Spider) void {
    var buf: [4096]u8 = undefined;
    var fbs = std.Io.fixedBufferStream(&buf);
    const stdout = std.fs.File.stdout();

    var retries: usize = 0;

    while (retries < 10) {
        const target_url_opt = spider.getNextUrl();

        if (target_url_opt == null) {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            retries += 1;
            continue;
        }
        retries = 0;

        const target_url = target_url_opt.?;
        defer allocator.free(target_url);

        const uri = std.Uri.parse(target_url) catch continue;

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        var body = std.Io.Writer.Allocating.init(allocator);
        defer body.deinit();

        const bodywriter = &body.writer;

        const response = client.fetch(.{
            .method = .GET,
            .location = .{ .uri = uri },
            .response_writer = bodywriter,
            // FIX: Add User-Agent and keep compression disabled
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = USER_AGENT },
            },
        }) catch {
            fbs.reset();
            fbs.writer().print("❌ Error fetching {s}\n", .{target_url}) catch {};
            stdout_mutex.lock();
            stdout.writeAll(fbs.getWritten()) catch {};
            stdout_mutex.unlock();
            continue;
        };

        fbs.reset();
        fbs.writer().print("[{d}] {s}\n", .{ response.status, target_url }) catch {};

        stdout_mutex.lock();
        stdout.writeAll(fbs.getWritten()) catch {};
        stdout_mutex.unlock();

        if (response.status == .ok) {
            const html = body.written();
            var it = std.mem.splitScalar(u8, html, '>');

            while (it.next()) |chunk| {
                if (std.mem.indexOf(u8, chunk, "href=\"")) |found_index| {
                    const url_start = found_index + 6;
                    const remainder = chunk[url_start..];

                    if (std.mem.indexOf(u8, remainder, "\"")) |quote_end| {
                        const raw_url = remainder[0..quote_end];

                        // --- URL NORMALIZATION & FILTERING ---

                        // 1. Protocol Relative (//ads.google.com)
                        if (std.mem.startsWith(u8, raw_url, "//")) {
                            const full_url = std.fmt.allocPrint(allocator, "https:{s}", .{raw_url}) catch continue;
                            defer allocator.free(full_url);
                            spider.addUrl(full_url) catch {};
                        }
                        // 2. Root Relative (/about.html)
                        else if (std.mem.startsWith(u8, raw_url, "/")) {
                            const full_url = std.fmt.allocPrint(allocator, "https://{s}{s}", .{ spider.base_host, raw_url }) catch continue;
                            defer allocator.free(full_url);
                            spider.addUrl(full_url) catch {};
                        }
                        // 3. Absolute HTTP/S (https://google.com)
                        else if (std.mem.startsWith(u8, raw_url, "http")) {
                            const full_url = allocator.dupe(u8, raw_url) catch continue;
                            defer allocator.free(full_url);
                            spider.addUrl(full_url) catch {};
                        }
                    }
                }
            }
        }
    }
}
