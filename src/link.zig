const std = @import("std");

pub fn extractLinks(
    allocator: std.mem.Allocator,
    html: []const u8,
    base_host: []const u8,
    base_url: []const u8,
) !std.ArrayList([]const u8) {
    var links: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (links.items) |l| allocator.free(l);
        links.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, html, '>');
    while (it.next()) |chunk| {
        if (std.mem.indexOf(u8, chunk, "href=\"")) |found| {
            const remainder = chunk[found + 6 ..];
            if (std.mem.indexOf(u8, remainder, "\"")) |end| {
                const href = remainder[0..end];

                if (!isValidHref(href)) continue;

                const resolved = resolveUrl(allocator, base_host, base_url, href) catch continue;

                const uri = std.Uri.parse(resolved) catch {
                    allocator.free(resolved);
                    continue;
                };
                if (uri.host) |h| {
                    if (!std.mem.eql(u8, h.percent_encoded, base_host)) {
                        allocator.free(resolved);
                        continue;
                    }
                }

                try links.append(allocator, resolved);
            }
        }
    }

    return links;
}

pub fn resolveUrl(
    allocator: std.mem.Allocator,
    base_host: []const u8,
    base_url: []const u8,
    href: []const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, href, "javascript:") or
        std.mem.startsWith(u8, href, "mailto:") or
        std.mem.startsWith(u8, href, "data:") or
        std.mem.startsWith(u8, href, "#"))
        return error.Skip;

    if (std.mem.startsWith(u8, href, "http"))
        return try allocator.dupe(u8, href);

    if (std.mem.startsWith(u8, href, "//"))
        return try std.fmt.allocPrint(allocator, "https:{s}", .{href});

    if (std.mem.startsWith(u8, href, "/"))
        return try std.fmt.allocPrint(allocator, "https://{s}{s}", .{ base_host, href });

    const uri = try std.Uri.parse(base_url);
    const path = uri.path.percent_encoded;
    const last_slash = std.mem.lastIndexOf(u8, path, "/") orelse 0;
    return try std.fmt.allocPrint(allocator, "https://{s}{s}/{s}", .{
        base_host,
        path[0..last_slash],
        href,
    });
}

pub fn isValidHref(href: []const u8) bool {
    if (href.len == 0) return false;
    if (href.len > 2048) return false;
    if (std.mem.eql(u8, href, ".")) return false;
    if (std.mem.eql(u8, href, "..")) return false;

    for (href) |c| {
        switch (c) {
            '\'', '"', '`', '(', ')', '{', '}', '[', ']', '<', '>', '+', '*', ' ', '\t', '\n', '\r', ',', ';', '\\' => return false,
            else => {},
        }
    }
    return true;
}
