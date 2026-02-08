const std = @import("std");
const Io = std.Io;
const process = std.process;
const crypto = std.crypto;

const USER_AGENT = "Mozilla/5.0 (compatible; ZigSpider/1.0)";

var stdout_mutex = std.Thread.Mutex{};

// =============================================================================
// Page
// =============================================================================
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

// =============================================================================
// Frontier Entry (for priority queue)
// =============================================================================
const FrontierEntry = struct {
    url: []const u8, // borrowed — owned by Spider.visited
    priority: u32,
    depth: u16,
};

fn comparePriority(_: void, a: FrontierEntry, b: FrontierEntry) std.math.Order {
    return std.math.order(b.priority, a.priority); // max-heap
}

// =============================================================================
// Spider (thread-safe crawler state)
// =============================================================================
pub const Spider = struct {
    allocator: std.mem.Allocator,
    io: Io,

    // Thread-safe state
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    frontier: std.PriorityQueue(FrontierEntry, void, comparePriority),
    visited: std.StringHashMap(void),   // owns all URL strings
    signatures: std.AutoHashMap([32]u8, void),

    // Config
    base_host: []const u8,
    max_depth: u16,
    max_pages: usize,

    // TLS
    ca_bundle: crypto.Certificate.Bundle,

    // Stats
    crawled_count: usize = 0,
    shutdown: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        seed_url: []const u8,
        config: Config,
    ) !Spider {
        const uri = try std.Uri.parse(seed_url);
        if (uri.host == null) return error.InvalidUrl;

        var bundle = crypto.Certificate.Bundle{};
        try bundle.rescan(allocator, io, try Io.Clock.now(.real, io));

        const host = try allocator.dupe(u8, uri.host.?.percent_encoded);

        var self = Spider{
            .allocator = allocator,
            .io = io,
            .frontier = std.PriorityQueue(FrontierEntry, void, comparePriority).init(allocator, {}),
            .visited = std.StringHashMap(void).init(allocator),
            .signatures = std.AutoHashMap([32]u8, void).init(allocator),
            .base_host = host,
            .max_depth = config.max_depth,
            .max_pages = config.max_pages,
            .ca_bundle = bundle,
        };

        try self.addUrl(seed_url, 100, 0);
        return self;
    }

    pub fn deinit(self: *Spider) void {
        self.ca_bundle.deinit(self.allocator);
        self.allocator.free(self.base_host);

        // visited owns all URL strings — free them here
        var it = self.visited.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.visited.deinit();

        // frontier URLs are borrowed from visited — just discard entries
        self.frontier.deinit();

        self.signatures.deinit();
    }

    pub const Config = struct {
        max_depth: u16 = 3,
        max_pages: usize = 100,
        worker_count: usize = 4,
    };

    /// Thread-safe: get next URL to crawl, blocking if frontier is empty.
    /// Returns null only when shutdown (max_pages reached or no work after retries).
    /// Caller must NOT free entry.url — visited owns it.
    pub fn getNextBlocking(self: *Spider) ?FrontierEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var empty_wakes: usize = 0;
        while (empty_wakes < 5) {
            if (self.shutdown) return null;

            // Try to pull from frontier
            while (self.frontier.removeOrNull()) |entry| {
                if (entry.depth > self.max_depth) continue;
                return entry;
            }

            // Frontier empty — wait for addUrl signal or shutdown broadcast
            self.cond.wait(&self.mutex);
            empty_wakes += 1;
        }

        return null; // woke up 5 times with nothing — assume done
    }

    /// Thread-safe: add URL to frontier.
    /// visited takes ownership of the duped string; frontier borrows it.
    pub fn addUrl(self: *Spider, url: []const u8, priority: u32, depth: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.visited.contains(url)) return;

        const owned = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned);

        try self.visited.put(owned, {});
        try self.frontier.add(.{
            .url = owned, // borrowed from visited
            .priority = priority,
            .depth = depth,
        });

        self.cond.signal();
    }

    /// Thread-safe: check if content already seen (by signature)
    pub fn isContentDuplicate(self: *Spider, sig: [32]u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.signatures.contains(sig);
    }

    /// Thread-safe: mark content as seen
    pub fn markContent(self: *Spider, sig: [32]u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.signatures.put(sig, {});
    }

    /// Thread-safe: increment crawl count, broadcast shutdown if max reached
    pub fn incrementCrawled(self: *Spider) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.crawled_count += 1;
        if (self.crawled_count >= self.max_pages) {
            self.shutdown = true;
            self.cond.broadcast(); // wake all waiting workers
        }
    }

    pub fn stats(self: *Spider) struct { crawled: usize, queued: usize } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .crawled = self.crawled_count,
            .queued = self.frontier.count(),
        };
    }
};

// =============================================================================
// Worker
// =============================================================================
fn worker(io: Io, allocator: std.mem.Allocator, spider: *Spider) !void {
    var client = std.http.Client{
        .allocator = allocator,
        .io = io,
        .read_buffer_size = 64 * 1024,
    };
    client.ca_bundle = spider.ca_bundle;
    defer {
        client.ca_bundle = .{};
        client.deinit();
    }

    while (true) {
        const entry = spider.getNextBlocking() orelse break;

        // entry.url is borrowed from visited — do NOT free it
        var page = Page.init(try allocator.dupe(u8, entry.url));
        page.depth = entry.depth;

        // Fetch
        const uri = std.Uri.parse(entry.url) catch {
            page.deinit(allocator);
            continue;
        };
        client.now = try Io.Clock.now(.real, io);

        var body = Io.Writer.Allocating.init(allocator);
        defer body.deinit();

        const response = client.fetch(.{
            .method = .GET,
            .location = .{ .uri = uri },
            .response_writer = &body.writer,
            .headers = .{
                .accept_encoding = .{ .override = "identity" },
                .user_agent = .{ .override = USER_AGENT },
            },
        }) catch |err| {
            safePrint(io, "❌ {s}: {}\n", .{ entry.url, err });
            page.deinit(allocator);
            continue;
        };

        printStatus(io, response.status, entry.url);

        if (response.status != .ok) {
            page.deinit(allocator);
            continue;
        }

        page.contents = try allocator.dupe(u8, body.written());
        page.computeSignature();

        // Check for duplicate content
        if (page.signature) |sig| {
            if (spider.isContentDuplicate(sig)) {
                page.deinit(allocator);
                continue;
            }
            try spider.markContent(sig);
        }

        spider.incrementCrawled();

        // Extract and queue links
        if (page.contents) |html| {
            extractAndQueueLinks(allocator, spider, html, entry.url, entry.depth + 1);
        }

        page.deinit(allocator);
    }
}

// =============================================================================
// Link Extraction
// =============================================================================
fn isValidHref(href: []const u8) bool {
    if (href.len == 0) return false;
    if (std.mem.endsWith(u8, href, ".")) return false;

    for (href) |c| {
        switch (c) {
            '`', '\'', '(', ')', ',', '\n', '\r', ' ' => return false,
            else => {},
        }
    }

    return true;
}

fn extractAndQueueLinks(
    allocator: std.mem.Allocator,
    spider: *Spider,
    html: []const u8,
    base_url: []const u8,
    depth: u16,
) void {
    var it = std.mem.splitScalar(u8, html, '>');
    while (it.next()) |chunk| {
        if (std.mem.indexOf(u8, chunk, "href=\"")) |found| {
            const remainder = chunk[found + 6 ..];
            if (std.mem.indexOf(u8, remainder, "\"")) |end| {
                const href = remainder[0..end];

                if (!isValidHref(href)) continue;

                const resolved = resolveUrl(allocator, spider.base_host, base_url, href) catch continue;
                defer allocator.free(resolved);

                // Only follow same-host links
                const uri = std.Uri.parse(resolved) catch continue;
                if (uri.host) |h| {
                    if (!std.mem.eql(u8, h.percent_encoded, spider.base_host)) continue;
                }

                spider.addUrl(resolved, 50, depth) catch {};
            }
        }
    }
}

fn resolveUrl(
    allocator: std.mem.Allocator,
    base_host: []const u8,
    base_url: []const u8,
    href: []const u8,
) ![]const u8 {
    // Skip non-http schemes and template strings
    if (std.mem.startsWith(u8, href, "javascript:") or
        std.mem.startsWith(u8, href, "mailto:") or
        std.mem.startsWith(u8, href, "data:") or
        std.mem.startsWith(u8, href, "#") or
        std.mem.indexOf(u8, href, "{{") != null or
        std.mem.indexOf(u8, href, "${") != null)
        return error.Skip;

    if (std.mem.startsWith(u8, href, "http"))
        return try allocator.dupe(u8, href);

    if (std.mem.startsWith(u8, href, "//"))
        return try std.fmt.allocPrint(allocator, "https:{s}", .{href});

    if (std.mem.startsWith(u8, href, "/"))
        return try std.fmt.allocPrint(allocator, "https://{s}{s}", .{ base_host, href });

    // Relative path
    const uri = try std.Uri.parse(base_url);
    const path = uri.path.percent_encoded;
    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse 0;
    return try std.fmt.allocPrint(allocator, "https://{s}{s}/{s}", .{
        base_host,
        path[0..last_slash],
        href,
    });
}

// =============================================================================
// Output Utilities
// =============================================================================
fn printStatus(io: Io, status: std.http.Status, url: []const u8) void {
    const code = @intFromEnum(status);
    const color: u8 = switch (code) {
        200...299 => 32, // green
        300...399 => 34, // blue
        400...499 => 31, // red
        else => 33, // yellow
    };
    safePrint(io, "\x1b[{d}m[{d}]\x1b[0m {s}\n", .{ color, code, url });
}

fn safePrint(io: Io, comptime fmt: []const u8, args: anytype) void {
    stdout_mutex.lock();
    defer stdout_mutex.unlock();

    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

// =============================================================================
// Main
// =============================================================================
pub fn main(init: process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // CLI args
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.next();
    const seed = args.next() orelse {
        safePrint(io, "Usage: spider <url>\n", .{});
        return;
    };

    const config = Spider.Config{
        .max_depth = 3,
        .max_pages = 1000,
        .worker_count = 16,
    };

    var spider = try Spider.init(allocator, io, seed, config);
    defer spider.deinit();

    safePrint(io, "🕷️  Starting on {s} (depth={}, max={})\n", .{ seed, config.max_depth, config.max_pages });

    // Spawn workers
    const worker_args = .{ io, allocator, &spider };
    const FutureType = @TypeOf(try io.concurrent(worker, worker_args));

    var futures: std.ArrayList(FutureType) = .empty;
    defer futures.deinit(allocator);

    for (0..config.worker_count) |_| {
        const fut = try io.concurrent(worker, worker_args);
        try futures.append(allocator, fut);
    }

    for (futures.items) |*fut| {
        try fut.await(io);
    }

    const s = spider.stats();
    safePrint(io, "\n🏁 Done. Crawled {} pages.\n", .{s.crawled});
}
