const std = @import("std");
const Io = std.Io;
const spider_mod = @import("spider.zig");
const page_mod = @import("page.zig");
const robots_mod = @import("robots.zig");
const link_mod = @import("link.zig");

const Spider = spider_mod.Spider;
const RobotRules = robots_mod.RobotRules;
const Page = page_mod.Page;

const USER_AGENT = "Mozilla/5.0 (compatible; ZigSpider/1.0)";

pub fn run(io: Io, allocator: std.mem.Allocator, spider: *Spider) !void {
    var retries: usize = 0;
    var last_request_time: ?Io.Clock.Timestamp = null;

    // Shared client — connection pool reuses TLS sessions across all workers
    const client = &spider.client;

    while (retries < 10) {
        if (!spider.running.load(.seq_cst)) break;

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

        // ── Robots.txt ──────────────────────────────────────────

        if (spider.config.respect_robots and !spider.hasRobotRules(host)) {
            spider.sink.print("Fetching robots.txt for {s}\n", .{host});
            const rules = fetchRobotsTxt(allocator, client, io, host) catch RobotRules.init(allocator);
            spider.setRobotRules(host, rules) catch {};

            if (rules.crawl_delay_ns) |delay| {
                spider.sink.print("Crawl delay: {}ms\n", .{delay / std.time.ns_per_ms});
            }
            if (rules.disallowed.items.len > 0) {
                spider.sink.print("{d} disallowed paths\n", .{rules.disallowed.items.len});
            }
        }

        if (!spider.isAllowedByRobots(host, path)) {
            spider.sink.print("Blocked by robots.txt: {s}\n", .{entry.url});
            spider.incrementBlockedByRobots();
            continue;
        }

        // ── Crawl delay ─────────────────────────────────────────

        if (spider.getCrawlDelay(host)) |delay_ns| {
            if (last_request_time) |last| {
                const now = Io.Clock.Timestamp.now(io, .real);
                const elapsed = last.durationTo(now);
                const elapsed_ns = elapsed.raw.toNanoseconds();
                if (elapsed_ns < delay_ns) {
                    const sleep_time = delay_ns - elapsed_ns;
                    try io.sleep(Io.Duration.fromNanoseconds(sleep_time), .awake);
                }
            }
        }

        // ── Fetch ───────────────────────────────────────────────

        var page = Page.init(try allocator.dupe(u8, entry.url));
        page.depth = entry.depth;

        client.now = Io.Clock.now(.real, io);

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
            spider.sink.print("❌ {s}: {}\n", .{ entry.url, err });
            page.deinit(allocator);
            continue;
        };

        last_request_time = Io.Clock.Timestamp.now(io, .real);

        const status_code = @intFromEnum(response.status);
        spider.sink.printStatus(response.status, entry.url);

        if (response.status != .ok) {
            spider.sink.record(allocator, .{
                .url = entry.url,
                .status = status_code,
                .depth = entry.depth,
                .content_size = 0,
            });
            page.deinit(allocator);
            continue;
        }

        // ── Process response ────────────────────────────────────

        page.contents = try allocator.dupe(u8, body.written());
        page.computeSignature();

        const is_dup = if (page.signature) |sig| spider.isContentDuplicate(sig) else false;

        if (is_dup) {
            spider.sink.record(allocator, .{
                .url = entry.url,
                .status = status_code,
                .depth = entry.depth,
                .content_size = if (page.contents) |c| c.len else 0,
                .is_duplicate = true,
            });
            page.deinit(allocator);
            continue;
        }

        if (page.signature) |sig| {
            try spider.markContent(sig);
        }

        spider.incrementCrawled();

        spider.sink.record(allocator, .{
            .url = entry.url,
            .status = status_code,
            .depth = entry.depth,
            .content_size = if (page.contents) |c| c.len else 0,
        });

        // ── Extract and enqueue links ───────────────────────────

        if (page.contents) |html| {
            var links = link_mod.extractLinks(allocator, html, spider.base_host, entry.url) catch {
                page.deinit(allocator);
                continue;
            };
            defer {
                for (links.items) |l| allocator.free(l);
                links.deinit(allocator);
            }

            for (links.items) |l| {
                spider.addUrl(l, 50, entry.depth + 1) catch {};
            }
        }

        page.deinit(allocator);
    }
}

fn fetchRobotsTxt(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    io: Io,
    host: []const u8,
) !RobotRules {
    const robots_url = try std.fmt.allocPrint(allocator, "https://{s}/robots.txt", .{host});
    defer allocator.free(robots_url);

    const uri = try std.Uri.parse(robots_url);
    client.now = Io.Clock.now(.real, io);

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
        return RobotRules.init(allocator);
    }

    return RobotRules.parse(allocator, body.written(), USER_AGENT);
}
