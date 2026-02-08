const std = @import("std");
const Io = std.Io;
<<<<<<< HEAD
=======
const process = std.process;
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
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
<<<<<<< HEAD
};
pub const RobotRules = struct {
    disallowed: std.ArrayList([]const u8),
    allowed: std.ArrayList([]const u8),
    crawl_delay_ns: ?u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RobotRules {
        return .{
            .disallowed = .empty,
            .allowed = .empty,
            .crawl_delay_ns = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RobotRules) void {
        for (self.disallowed.items) |path| {
            self.allocator.free(path);
        }
        self.disallowed.deinit(self.allocator);

        for (self.allowed.items) |path| {
            self.allocator.free(path);
        }
        self.allowed.deinit(self.allocator);
    }

    pub fn parse(allocator: std.mem.Allocator, content: []const u8, user_agent: []const u8) !RobotRules {
        var rules = RobotRules.init(allocator);
        errdefer rules.deinit();

        var dominated_by_ua: enum { none, wildcard, specific } = .none;
        var current_ua_matches = false;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            // Trim whitespace and handle \r
            var line = std.mem.trim(u8, raw_line, " \t\r");

            // Skip comments and empty lines
            if (line.len == 0 or line[0] == '#') continue;

            // Remove inline comments
            if (std.mem.indexOf(u8, line, "#")) |idx| {
                line = std.mem.trim(u8, line[0..idx], " \t");
            }

            // Parse directive
            if (std.mem.indexOf(u8, line, ":")) |colon| {
                const key = std.mem.trim(u8, line[0..colon], " \t");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

                if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
                    // Check if this user-agent block applies to user
                    const is_wildcard = std.mem.eql(u8, value, "*");
                    const is_specific = std.mem.indexOfPos(u8, user_agent, 0, value) != null or
                        std.mem.indexOfPos(u8, value, 0, user_agent) != null;

                    if (is_specific and dominated_by_ua != .specific) {
                        // Speicifc match takes precdence, clear old rules
                        if (dominated_by_ua == .wildcard) {
                            for (rules.disallowed.items) |path| rules.allocator.free(path);
                            rules.disallowed.clearRetainingCapacity();
                            rules.crawl_delay_ns = null;
                        }
                        dominated_by_ua = .specific;
                        current_ua_matches = true;
                    } else if (is_wildcard and dominated_by_ua == .none) {
                        dominated_by_ua = .wildcard;
                        current_ua_matches = true;
                    } else if (is_specific and dominated_by_ua == .specific) {
                        current_ua_matches = true;
                    } else {
                        current_ua_matches = false;
                    }
                } else if (current_ua_matches) {
                    if (std.ascii.eqlIgnoreCase(key, "disallow")) {
                        if (value.len > 0) {
                            const path = try allocator.dupe(u8, value);
                            try rules.disallowed.append(allocator, path);
                        }
                    } else if (std.ascii.eqlIgnoreCase(key, "allow")) {
                        if (value.len > 0) {
                            const path = try allocator.dupe(u8, value);
                            try rules.allowed.append(allocator, path);
                        }
                    } else if (std.ascii.eqlIgnoreCase(key, "crawl-delay")) {
                        if (std.fmt.parseFloat(f64, value)) |seconds| {
                            rules.crawl_delay_ns = @intFromFloat(seconds * std.time.ns_per_s);
                        } else |_| {}
                    }
                }
            }
        }

        return rules;
    }

    pub fn isAllowed(self: *const RobotRules, path: []const u8) bool {
        // Check allows first
        for (self.allowed.items) |pattern| {
            if (std.mem.startsWith(u8, path, pattern)) return true;
        }

        // Check disallows
        for (self.disallowed.items) |pattern| {
            if (std.mem.startsWith(u8, path, pattern)) return false;
        }

        return true;
    }
=======
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
};

// =============================================================================
// Frontier Entry (for priority queue)
// =============================================================================
const FrontierEntry = struct {
<<<<<<< HEAD
    url: []const u8,
=======
    url: []const u8, // borrowed — owned by Spider.visited
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
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
<<<<<<< HEAD
    mutex: std.Thread.Mutex = .{},
    frontier: std.PriorityQueue(FrontierEntry, void, comparePriority),
    visited: std.StringHashMap(void),
    signatures: std.AutoHashMap([32]u8, void),
    robot_rules: std.StringHashMap(RobotRules),
    base_host: []const u8,
    max_depth: u16,
    max_pages: usize,
    respect_robots: bool,
=======

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
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
    ca_bundle: crypto.Certificate.Bundle,

    // Stats
    crawled_count: usize = 0,
<<<<<<< HEAD
    blocked_by_robots: usize = 0,
=======
    shutdown: bool = false,
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)

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
<<<<<<< HEAD
            .robot_rules = std.StringHashMap(RobotRules).init(allocator),
            .base_host = host,
            .max_depth = config.max_depth,
            .max_pages = config.max_pages,
            .respect_robots = config.respect_robots,
            .ca_bundle = bundle,
        };

        try self.addUrl(seed_url, 100, 0); // High priority for seed
=======
            .base_host = host,
            .max_depth = config.max_depth,
            .max_pages = config.max_pages,
            .ca_bundle = bundle,
        };

        try self.addUrl(seed_url, 100, 0);
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
        return self;
    }

    pub fn deinit(self: *Spider) void {
        self.ca_bundle.deinit(self.allocator);
        self.allocator.free(self.base_host);

<<<<<<< HEAD
        // Free visited URLs
=======
        // visited owns all URL strings — free them here
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
        var it = self.visited.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.visited.deinit();

<<<<<<< HEAD
        // Free remaining frontier URLs
        while (self.frontier.removeOrNull()) |entry| {
            self.allocator.free(entry.url);
        }
        self.frontier.deinit();

        self.signatures.deinit();

        // Free robot rules
        var rules_it = self.robot_rules.iterator();
        while (rules_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            @constCast(entry.value_ptr).deinit();
        }
        self.robot_rules.deinit();
    }

    pub const Config = struct {
        max_depth: u16 = 3,
        max_pages: usize = 100,
        worker_count: usize = 4,
        respect_robots: bool = true,
    };

    /// Thread-safe: get next URL to crawl
    pub fn getNext(self: *Spider) ?FrontierEntry {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.crawled_count >= self.max_pages) return null;

        while (self.frontier.removeOrNull()) |entry| {
            if (entry.depth > self.max_depth) {
                self.allocator.free(entry.url);
                continue;
            }
            return entry;
        }
        return null;
    }

    /// Thread-safe: add URL to frontier
    pub fn addUrl(self: *Spider, url: []const u8, priority: u32, depth: u16) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

=======
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

>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
        if (self.visited.contains(url)) return;

        const owned = try self.allocator.dupe(u8, url);
        errdefer self.allocator.free(owned);

        try self.visited.put(owned, {});
        try self.frontier.add(.{
<<<<<<< HEAD
            .url = try self.allocator.dupe(u8, url),
            .priority = priority,
            .depth = depth,
        });
=======
            .url = owned, // borrowed from visited
            .priority = priority,
            .depth = depth,
        });

        self.cond.signal();
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
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

<<<<<<< HEAD
    /// Thread-safe: increment crawl count
=======
    /// Thread-safe: increment crawl count, broadcast shutdown if max reached
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
    pub fn incrementCrawled(self: *Spider) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.crawled_count += 1;
<<<<<<< HEAD
    }

    pub fn incrementBlockedByRobots(self: *Spider) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.blocked_by_robots += 1;
    }

    // Check if URL is allowed by robots.txt (must be called with mutex unlocked)
    pub fn isAllowedByRobots(self: *Spider, host: []const u8, path: []const u8) bool {
        if (!self.respect_robots) return true;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.robot_rules.get(host)) |rules| {
            return rules.isAllowed(path);
        }
        // No rules fetched yet = allowed (rules fetched separately)
        return true;
    }

    pub fn getCrawlDelay(self: *Spider, host: []const u8) ?u64 {
        if (!self.respect_robots) return null;

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.robot_rules.get(host)) |rules| {
            return rules.crawl_delay_ns;
        }
        return null;
    }

    /// Store robot rules for a host
    pub fn setRobotRules(self: *Spider, host: []const u8, rules: RobotRules) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);

        try self.robot_rules.put(owned_host, rules);
    }

    pub fn hasRobotRules(self: *Spider, host: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.robot_rules.contains(host);
    }

    pub fn stats(self: *Spider) struct { crawled: usize, queued: usize, blocked: usize } {
=======
        if (self.crawled_count >= self.max_pages) {
            self.shutdown = true;
            self.cond.broadcast(); // wake all waiting workers
        }
    }

    pub fn stats(self: *Spider) struct { crawled: usize, queued: usize } {
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .crawled = self.crawled_count,
            .queued = self.frontier.count(),
<<<<<<< HEAD
            .blocked = self.blocked_by_robots,
=======
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
        };
    }
};

// =============================================================================
// Worker
// =============================================================================
<<<<<<< HEAD
fn fetchRobotsTxt(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    io: Io,
    host: []const u8,
) !RobotRules {
    const robots_url = try std.fmt.allocPrint(allocator, "https://{s}/robots.txt", .{host});
    defer allocator.free(robots_url);

    const uri = try std.Uri.parse(robots_url);
    client.now = try Io.Clock.now(.real, io);

    var body = Io.Writer.Allocating.init(allocator);
    defer body.deinit();

    const response = try client.fetch(.{
        .method = .GET,
        .location = .{ .uri = uri },
        .response_writer = &body.writer,
        .headers = .{
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = USER_AGENT },
        },
    });

    if (response.status != .ok) {
        // No robots.txt or error = allow everything
        return RobotRules.init(allocator);
    }

    return RobotRules.parse(allocator, body.written(), USER_AGENT);
}

fn worker(io: Io, allocator: std.mem.Allocator, spider: *Spider) !void {
    var retries: usize = 0;
    var last_request_time: ?std.time.Instant = null;

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

    while (retries < 10) {
        const entry = spider.getNext() orelse {
            try io.sleep(Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
            retries += 1;
            continue;
        };

        retries = 0;
        defer allocator.free(entry.url);

        const uri = std.Uri.parse(entry.url) catch continue;
        const host = if (uri.host) |h| h.percent_encoded else continue;
        const path = uri.path.percent_encoded;

        if (spider.respect_robots and !spider.hasRobotRules(host)) {
            safePrint(io, "Fetching robots.txt for {s}\n", .{host});
            const rules = fetchRobotsTxt(allocator, &client, io, host) catch RobotRules.init(allocator);
            spider.setRobotRules(host, rules) catch {};

            if (rules.crawl_delay_ns) |delay| {
                safePrint(io, "Crawl delay: {}ms\n", .{delay / std.time.ns_per_ms});
            }
            if (rules.disallowed.items.len > 0) {
                safePrint(io, "{d} disallowed paths\n", .{rules.disallowed.items.len});
            }
        }

        // Check if allowed by robots.txt
        if (!spider.isAllowedByRobots(host, path)) {
            safePrint(io, "Blocked by robots.txt: {s}\n", .{entry.url});
            spider.incrementBlockedByRobots();
            continue;
        }

        // Respect crawl delay
        if (spider.getCrawlDelay(host)) |delay_ns| {
            if (last_request_time) |last| {
                if (std.time.Instant.now()) |now| {
                    const elapsed: u64 = std.time.Instant.since(now, last);
                    if (elapsed < delay_ns) {
                        const sleep_time = delay_ns - elapsed;
                        try io.sleep(Io.Duration.fromNanoseconds(sleep_time), .awake);
                    }
                } else |_| {}
            }
        }

        var page = Page.init(try allocator.dupe(u8, entry.url));
        page.depth = entry.depth;

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

        last_request_time = std.time.Instant.now() catch null;

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
                // safePrint(io, "♻️  Duplicate content: {s}\n", .{entry.url});
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
    // Skip non-http
    if (std.mem.startsWith(u8, href, "javascript:") or
        std.mem.startsWith(u8, href, "mailto:") or
        std.mem.startsWith(u8, href, "#"))
        return error.Skip;

    if (std.mem.startsWith(u8, href, "http"))
        return try allocator.dupe(u8, href);

    if (std.mem.startsWith(u8, href, "//"))
        return try std.fmt.allocPrint(allocator, "https:{s}", .{href});

    if (std.mem.startsWith(u8, href, "/"))
        return try std.fmt.allocPrint(allocator, "https://{s}{s}", .{ base_host, href });

    // Relative
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
// Utilities
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
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded: Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
=======
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
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)

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
<<<<<<< HEAD
        .worker_count = 4,
        .respect_robots = true,
=======
        .worker_count = 16,
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)
    };

    var spider = try Spider.init(allocator, io, seed, config);
    defer spider.deinit();

<<<<<<< HEAD
    safePrint(io, "  Starting on {s} (depth={}, max={}, robots={})\n", .{
        seed,
        config.max_depth,
        config.max_pages,
        config.respect_robots,
    });
=======
    safePrint(io, "🕷️  Starting on {s} (depth={}, max={})\n", .{ seed, config.max_depth, config.max_pages });
>>>>>>> b82804a (refactor: fix ownership model, add cond var, bump workers to 16)

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
