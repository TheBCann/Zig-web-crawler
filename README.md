# Zig Web Crawler

A high-performance, async web crawler written in Zig with robots.txt support, content deduplication, and priority-based crawling.

## Features

- **Async I/O:** Uses Zig 0.16.0's `std.Io` runtime for lightweight concurrent tasks
- **Priority Queue:** Crawls important pages first (seeds prioritized over discovered links)
- **robots.txt Support:** Respects `Disallow`, `Allow`, and `Crawl-delay` directives
- **Content Deduplication:** SHA-256 hashing to skip duplicate content (different URLs, same page)
- **URL Normalization:** Handles relative URLs, protocol-relative links, and fragments
- **Colored Output:** Status codes color-coded (green=2xx, blue=3xx, red=4xx, yellow=5xx)

## Requirements

- **Zig 0.16.0-dev (Nightly)** — requires experimental `std.Io` module

## Build
```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseSafe
```

## Usage
```bash
./zig-out/bin/spider <url>

# Examples
./zig-out/bin/spider https://ziglang.org
./zig-out/bin/spider https://example.com
```

## Configuration

Edit `src/spider.zig` to adjust:
```zig
const config = Spider.Config{
    .max_depth = 3,        // How deep to follow links
    .max_pages = 1000,     // Maximum pages to crawl
    .worker_count = 4,     // Concurrent workers
    .respect_robots = true // Obey robots.txt
};
```

## Output
```
  Starting on https://example.com (depth=3, max=1000, robots=true)
Fetching robots.txt for example.com
3 disallowed paths
[200] https://example.com
[200] https://example.com/about
[200] https://example.com/contact
Blocked by robots.txt: https://example.com/admin/
[404] https://example.com/broken-link

Done. Crawled 42 pages.
```

## Project Structure
```
.
├── build.zig          # Build configuration
├── build.zig.zon      # Package manifest
├── src/
│   └── spider.zig     # Main crawler source
└── README.md
```

## How It Works

1. **Seed URL** added to priority queue (priority=100)
2. **Workers** pull highest-priority URLs from queue
3. **robots.txt** fetched and parsed per domain
4. **Pages** fetched, content hashed for dedup
5. **Links** extracted, resolved, and queued (priority=50)
6. **Repeat** until max_pages or queue empty

## License

MIT
