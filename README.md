````markdown
# Duplicate File Cleaner

A lightweight PowerShell tool for finding and removing duplicate files on Windows.

It finds duplicates using **file size + SHA-256**, so files are never deleted just because they have the same name or size.

## Features

- Recursive folder scanning
- Low RAM usage
- SHA-256 duplicate verification
- Exclude folders
- Dry Run mode
- Live progress and ETA
- CSV deletion log
- Supports large file collections, including 1TB+
- No third-party software required

## How It Works

```text
File Size
   ↓
Same Size?
   ↓
SHA-256
   ↓
Same Hash?
   ↓
Duplicate → Keep one, delete the other
````

Two files with the same size but different contents are **not** considered duplicates.

## Requirements

* Windows 10+
* PowerShell 5.1+

## Usage

Open `DuplicateCleaner.ps1` and configure:

```powershell
$Folder = "D:\MyFiles"

$ExcludeFolder = ""

$DryRun = $true
```

### Settings

**Folder**

The main folder to scan.

**ExcludeFolder**

A folder and all of its subfolders to ignore.

Leave it empty to disable:

```powershell
$ExcludeFolder = ""
```

**DryRun**

Run safely without deleting anything:

```powershell
$DryRun = $true
```

After reviewing the results and deletion log, enable deletion:

```powershell
$DryRun = $false
```

## Run

Open PowerShell and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
```

Then:

```powershell
cd "C:\Path\To\duplicate-file-cleaner"
.\DuplicateCleaner.ps1
```

## Report

The script shows a compact final report:

```text
FILES    : 96455 before | 1091 deleted | 95364 remaining
SIZE     : 197.37 GB before | 129.03 GB freed | 68.34 GB after
DUPLICATE: 1091 real | 12746 candidates | 4821 size-groups
TIME     : 11.7 minutes | Errors: 0
```

## Deletion Log

A `duplicate-deletion-log.csv` file records every duplicate:

* Deleted file
* Kept file
* File size
* SHA-256 hash
* Timestamp
* Action

## Safety

Always run with:

```powershell
$DryRun = $true
```

first.

Review the results and log before enabling deletion.

> **Warning:** Live deletion permanently removes files. Keep a backup of important data.

## License

MIT License

```

این نسخه برای صفحه اول GitHub مناسب‌تر است. جزئیات فنی اضافه را هم می‌توانیم بعداً داخل `docs/` ببریم تا README شلوغ نشود.
```
