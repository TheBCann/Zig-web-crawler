const std = @import("std");

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
            var line = std.mem.trim(u8, raw_line, " \t\r");

            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.indexOf(u8, line, "#")) |idx| {
                line = std.mem.trim(u8, line[0..idx], " \t");
            }

            if (std.mem.indexOf(u8, line, ":")) |colon| {
                const key = std.mem.trim(u8, line[0..colon], " \t");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

                if (std.ascii.eqlIgnoreCase(key, "user-agent")) {
                    const is_wildcard = std.mem.eql(u8, value, "*");
                    const is_specific = std.mem.indexOfPos(u8, user_agent, 0, value) != null or
                        std.mem.indexOfPos(u8, value, 0, user_agent) != null;

                    if (is_specific and dominated_by_ua != .specific) {
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
        for (self.allowed.items) |pattern| {
            if (std.mem.startsWith(u8, path, pattern)) return true;
        }

        for (self.disallowed.items) |pattern| {
            if (std.mem.startsWith(u8, path, pattern)) return false;
        }

        return true;
    }
};
