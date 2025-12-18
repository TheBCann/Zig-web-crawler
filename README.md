# Zig Web Crawler

A high-performance, async web crawler written in Zig. This tool connects to a seed URL, extracts links, and recursively visits them using Zig's experimental `std.Io` async runtime.

## Features

- **Async I/O:** Uses Zig 0.16.0's new `std.Io` runtime to spawn lightweight concurrent tasks instead of heavy OS threads.
- **Zero-Allocation Parsing:** Uses efficient string splitting to find `href` tags without heavy DOM parsing.
- **Polite Crawling:** Includes User-Agent spoofing and strict duplicate URL detection.
- **Protocol Handling:** Normalizes relative URLs (e.g., `//google.com` or `/about`) to absolute URLs.

## Requirements

- **Zig 0.16.0-dev (Nightly)**
  - _Note: This project relies on the experimental `std.Io` module which is only available in recent nightly builds._

## Building & Running

### Quick Start

To build and run the crawler in one step:

```bash
zig build run -- [https://ziglang.org](https://ziglang.org)
```
