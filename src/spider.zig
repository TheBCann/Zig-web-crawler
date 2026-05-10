const std = @import("std");
const Io = std.Io;
const crypto = std.crypto;
const Frontier = @import("frontier.zig").Frontier;
const FrontierEntry = @import("frontier.zig").Entry;
const RobotRules = @import("robots.zig").RobotRules;
const OutputSink = @import("output.zig").OutputSink;

pub const Config = struct {
    max_depth: u16 = 3,
    max_pages: usize = 100,
    worker_count: usize = 4,
    respect_robots: bool = true,
    json_output: bool = false,
};

pub const Spider = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: Config,

    mutex: Io.Mutex = Io.Mutex.init,
    frontier: Frontier,
    robot_rules: std.StringHashMap(RobotRules),
    crawled_count: usize = 0,
    blocked_by_robots: usize = 0,

    base_host: []const u8,
    client: std.http.Client,
    sink: OutputSink,
    running: *std.atomic.Value(bool),

    pub fn init(
        allocator: std.mem.Allocator,
        io: Io,
        seed_url: []const u8,
        config: Config,
        running: *std.atomic.Value(bool),
    ) !Spider {
        const uri = try std.Uri.parse(seed_url);
        if (uri.host == null) return error.InvalidUrl;

        const host = try allocator.dupe(u8, uri.host.?.percent_encoded);

        var client = std.http.Client{
            .allocator = allocator,
            .io = io,
            .read_buffer_size = 64 * 1024,
        };
        try client.ca_bundle.rescan(allocator, io, Io.Clock.now(.real, io));

        var self = Spider{
            .allocator = allocator,
            .io = io,
            .config = config,
            .frontier = Frontier.init(allocator),
            .robot_rules = std.StringHashMap(RobotRules).init(allocator),
            .base_host = host,
            .client = client,
            .sink = OutputSink.init(io),
            .running = running,
        };

        try self.addUrl(seed_url, 100, 0);
        return self;
    }

    pub fn deinit(self: *Spider) void {
        self.client.deinit();
        self.allocator.free(self.base_host);
        self.frontier.deinit(self.allocator);
        self.sink.deinit(self.allocator);

        var rules_it = self.robot_rules.iterator();
        while (rules_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            @constCast(entry.value_ptr).deinit();
        }
        self.robot_rules.deinit();
    }


    pub fn getNext(self: *Spider) ?FrontierEntry {
        if (!self.running.load(.seq_cst)) return null;

        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);

        if (self.crawled_count >= self.config.max_pages) return null;

        while (self.frontier.pop()) |entry| {
            if (entry.depth > self.config.max_depth) {
                self.allocator.free(entry.url);
                continue;
            }
            return entry;
        }
        return null;
    }

    pub fn addUrl(self: *Spider, url: []const u8, priority: u32, depth: u16) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        try self.frontier.addUrl(self.allocator, url, priority, depth);
    }

    pub fn isContentDuplicate(self: *Spider, sig: [32]u8) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        return self.frontier.isContentDuplicate(sig);
    }

    pub fn markContent(self: *Spider, sig: [32]u8) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        try self.frontier.markContent(sig);
    }

    pub fn incrementCrawled(self: *Spider) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.crawled_count += 1;
    }


    pub fn isAllowedByRobots(self: *Spider, host: []const u8, path: []const u8) bool {
        if (!self.config.respect_robots) return true;

        self.mutex.lock(self.io) catch return true;
        defer self.mutex.unlock(self.io);

        if (self.robot_rules.get(host)) |rules| {
            return rules.isAllowed(path);
        }
        return true;
    }

    pub fn getCrawlDelay(self: *Spider, host: []const u8) ?u64 {
        if (!self.config.respect_robots) return null;

        self.mutex.lock(self.io) catch return null;
        defer self.mutex.unlock(self.io);

        if (self.robot_rules.get(host)) |rules| {
            return rules.crawl_delay_ns;
        }
        return null;
    }

    pub fn setRobotRules(self: *Spider, host: []const u8, rules: RobotRules) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        const owned_host = try self.allocator.dupe(u8, host);
        errdefer self.allocator.free(owned_host);

        try self.robot_rules.put(owned_host, rules);
    }

    pub fn hasRobotRules(self: *Spider, host: []const u8) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        return self.robot_rules.contains(host);
    }

    pub fn incrementBlockedByRobots(self: *Spider) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        self.blocked_by_robots += 1;
    }


    pub const Stats = struct {
        crawled: usize,
        queued: usize,
        blocked: usize,
    };

    pub fn stats(self: *Spider) Stats {
        self.mutex.lock(self.io) catch return .{ .crawled = 0, .queued = 0, .blocked = 0 };
        defer self.mutex.unlock(self.io);
        return .{
            .crawled = self.crawled_count,
            .queued = self.frontier.count(),
            .blocked = self.blocked_by_robots,
        };
    }
};
