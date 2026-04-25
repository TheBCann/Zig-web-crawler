const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const spider_mod = @import("spider.zig");
const worker_mod = @import("worker.zig");

const Spider = spider_mod.Spider;
const Config = spider_mod.Config;

var keep_running = std.atomic.Value(bool).init(true);

fn handleSigInt(sig: posix.SIG) callconv(.c) void {
    _ = sig;
    keep_running.store(false, .seq_cst);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    // ── Parse args (arena — lives forever, no cleanup) ───────────

    const args = try init.minimal.args.toSlice(arena);
    const opts = parseArgs(args) orelse {
        printUsage(io);
        return;
    };

    // ── Build config + spider (gpa — tracked, defer cleanup) ─────

    const config = Config{
        .max_depth = opts.depth,
        .max_pages = opts.max_pages,
        .worker_count = opts.workers,
        .respect_robots = false,
        .json_output = opts.json,
    };

    var act = posix.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &act, null);

    var spider = try Spider.init(allocator, io, opts.seed, config, &keep_running);
    defer spider.deinit();

    spider.sink.print("🕷️  Starting on {s} (depth={}, max={}, workers={})\n", .{
        opts.seed,
        config.max_depth,
        config.max_pages,
        config.worker_count,
    });

    // ── Spawn workers ────────────────────────────────────────────

    const worker_args = .{ io, allocator, &spider };
    const FutureType = @TypeOf(try io.concurrent(worker_mod.run, worker_args));

    var futures: std.ArrayList(FutureType) = .empty;
    defer futures.deinit(allocator);

    for (0..config.worker_count) |_| {
        const fut = try io.concurrent(worker_mod.run, worker_args);
        try futures.append(allocator, fut);
    }

    // ── Await all workers ────────────────────────────────────────

    for (futures.items) |*fut| {
        try fut.await(io);
    }

    // ── Report ───────────────────────────────────────────────────

    const s = spider.stats();
    spider.sink.print("\n🏁 Done. Crawled {} pages ({} blocked by robots.txt).\n", .{
        s.crawled,
        s.blocked,
    });

    if (opts.out) |file_path| {
        // Generate the JSON string
        const json = try spider.sink.toJson(allocator);
        defer allocator.free(json);

        // Create the file in the current working directory
        var file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
        defer file.close(io);

        // Write data to file
        try file.writeStreamingAll(io, json);

        spider.sink.print("\n[*] Saved JSON results to {s}\n", .{file_path});
    } else if (config.json_output) {
        spider.sink.print("\n", .{});
        spider.sink.printJson(allocator);
    }
}

// =============================================================================
// Arg parsing
// =============================================================================
const Options = struct {
    seed: []const u8,
    depth: u16 = 3,
    max_pages: usize = 1000,
    workers: usize = 4,
    json: bool = false,
    out: ?[]const u8 = null,
};

fn parseArgs(args: []const []const u8) ?Options {
    if (args.len < 2) return null;

    var opts = Options{ .seed = undefined };
    var got_seed = false;
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= args.len) return null;
            opts.depth = std.fmt.parseInt(u16, args[i], 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--max")) {
            i += 1;
            if (i >= args.len) return null;
            opts.max_pages = std.fmt.parseInt(usize, args[i], 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            i += 1;
            if (i >= args.len) return null;
            opts.workers = std.fmt.parseInt(usize, args[i], 10) catch return null;
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= args.len) return null;
            opts.out = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return null;
        } else if (!got_seed) {
            opts.seed = arg;
            got_seed = true;
        } else {
            return null;
        }
    }

    if (!got_seed) return null;
    return opts;
}

fn printUsage(io: Io) void {
    var buf: [4096]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    w.interface.print(
        \\Usage: spider [options] <url>
        \\
        \\Options:
        \\  --depth <n>      Max crawl depth (default: 3)
        \\  --max <n>        Max pages to crawl (default: 1000)
        \\  --workers <n>    Number of concurrent workers (default: 4)
        \\  --json           Print results as JSON after crawling
        \\ --out <file>      Save JSON results to a file
        \\  -h, --help       Show this help
        \\
    , .{}) catch {};
    w.interface.flush() catch {};
}
