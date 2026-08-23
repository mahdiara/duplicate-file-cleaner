# Duplicate File Cleaner

A simple and low-RAM PowerShell tool for finding and removing duplicate files on Windows.

The tool recursively scans folders, finds files with the same size, and then verifies their contents using SHA-256 before deleting duplicates.

## Features

- Recursive folder scanning
- Works with any file type
- Low RAM usage
- Disk-backed file indexing
- Same-size filtering before hashing
- SHA-256 duplicate verification
- Exclude folders
- Dry-run mode
- Live progress
- Processing speed and ETA
- CSV deletion log
- Final verification
- Suitable for large file collections
- Designed for 1TB+ datasets

## How It Works

The tool does not consider two files duplicates just because they have the same size.

It uses two steps:

1. Compare file sizes
2. Compare SHA-256 hashes

Only when both values match is a file considered a duplicate.

```text
Same Size
    ↓
SHA-256
    ↓
Same Hash
    ↓
Duplicate
    ↓
Keep one
Delete the other
