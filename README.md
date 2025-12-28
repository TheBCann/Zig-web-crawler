# Zig Web Crawler

A high-performance, async web crawler written in Zig. This tool connects to a seed URL, extracts links, and recursively visits them using Zig's experimental `std.Io` async runtime.

## Features

- **Async I/O:** Uses Zig 0.16.0's new `std.Io` runtime to spawn lightweight concurrent tasks instead of heavy OS threads.
- **Zero-Allocation Parsing:** Uses efficient string splitting to find `href` tags without heavy DOM parsing.
- **Headers and Duplicate URL Detection:** Includes User-Agent spoofing and strict duplicate URL detection.
- **Protocol Handling:** Normalizes relative URLs (e.g., `//google.com` or `/about`) to absolute URLs.

## Requirements

- **Zig 0.16.0-dev (Nightly)**
  - _Note: This project relies on the experimental `std.Io` module which is only available in recent nightly builds._
