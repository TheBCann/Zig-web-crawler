# Zig Web Crawler


A high-performance, async web crawler written in Zig with support, content deduplication, and priority-based crawling.

## Features

- **Async I/O:** Uses Zig 0.16.0's `std.Io` runtime for lightweight concurrent tasks
- **Priority Queue:** Crawls important pages first (seeds prioritized over discovered links)
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
};
```

## Output
```
Starting on https://example.com (depth=3, max=1000)
3 disallowed paths
[200] https://example.com
[200] https://example.com/about
[200] https://example.com/contact
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
3. **Pages** fetched, content hashed for dedup
4. **Links** extracted, resolved, and queued (priority=50)
5. **Repeat** until max_pages or queue empty
=======
A high-performance, concurrent web crawler written in Zig 0.16.0. Connects to a seed URL, extracts links, and recursively crawls them using Zig's new `std.Io` runtime with future-based concurrency.

## Features

- **Future-Based Concurrency:** Spawns 16 concurrent workers via `io.concurrent()` — no OS thread pool management needed.
- **Content Deduplication:** SHA-256 fingerprinting detects duplicate content served at different URLs.
- **Thread-Safe Frontier:** Priority queue with mutex protection and condition variable signaling — workers block instead of polling.
- **Same-Host Enforcement:** Only follows links within the seed URL's domain.
- **URL Normalization:** Resolves relative paths (`/about`), protocol-relative URLs (`//cdn.example.com`), and filters out `javascript:`, `mailto:`, and template strings.
- **Clean Ownership Model:** Visited set owns all URL strings; frontier borrows them. No double-frees, no use-after-free.

## Requirements

- **Zig 0.16.0-dev (Nightly)** — requires the `std.Io` module available in recent nightly builds.

## Usage

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/spider https://example.com
```

Or run directly:

```sh
zig run src/spider.zig -- https://example.com
```

## Configuration

Edit the `Config` struct in `main()`:

```zig
const config = Spider.Config{
    .max_depth = 3,      // max link-following depth
    .max_pages = 1000,   // stop after N pages crawled
    .worker_count = 16,  // concurrent fetch workers
};
```

## Architecture

```
main()
 ├── Spider.init()          — seed URL, TLS bundle, frontier
 ├── io.concurrent(worker)  — spawn N futures
 │    └── worker loop:
 │         ├── getNextBlocking()     — cond.wait() until work or shutdown
 │         ├── client.fetch()        — HTTP GET via shared TLS client
 │         ├── computeSignature()    — SHA-256 content fingerprint
 │         ├── isContentDuplicate()  — skip if already seen
 │         └── extractAndQueueLinks() — parse hrefs, addUrl() signals cond
 └── fut.await(io)          — join all workers
```
