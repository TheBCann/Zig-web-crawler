# Zig Web Crawler

A high-performance, multi-threaded web crawler written in Zig. This tool connects to a seed URL, extracts links, and recursively visits them using a thread pool.

## Features

- **Multi-threaded:** Spawns multiple workers to crawl pages concurrently.
- **Custom HTML Parsing:** Uses a manual, zero-allocation string splitting method to find `href` tags.
- **Polite Crawling:** Includes User-Agent spoofing and duplicate URL detection.
- **Protocol Handling:** Normalizes relative URLs (e.g., `//google.com` or `/about`) to absolute URLs.

## Requirements

- [Zig](https://ziglang.org/download/) (0.15.2)

## Building

To build the project for performance:

```bash
cd src && zig build-exe spider.zig -Doptimize=ReleaseSafe or zig build

```
