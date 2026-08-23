# Duplicate File Cleaner

A simple, low-RAM PowerShell tool for finding true duplicate files on Windows.

It first groups files by size, then uses **SHA-256** to verify whether same-size files are actually identical. Only confirmed duplicates can be deleted.

## Features

* Recursive file scanning
* Low RAM usage
* Disk-backed file indexing
* SHA-256 verification
* Safe `Dry Run` mode
* Live progress, speed and ETA
* Console duplicate reports
* CSV deletion log
* Folder exclusion support
* Final verification report
* Designed for large file collections

## Usage

Edit these settings in `DuplicateCleaner.ps1`:

```powershell
$Folder = "D:\Your\Folder"
$ExcludeFolder = ""
$DryRun = $true
```

### Safe Mode

Keep:

```powershell
$DryRun = $true
```

The script will find and report duplicates without deleting anything.

After reviewing the results, change it to:

```powershell
$DryRun = $false
```

to enable deletion.

### Run

Open PowerShell in the project folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\DuplicateCleaner.ps1
```

The final report is displayed directly in PowerShell.

> Always run the script in `Dry Run` mode first.

---

# پاک‌کننده فایل‌های تکراری

یک ابزار ساده و کم‌مصرف PowerShell برای پیدا کردن فایل‌های تکراری واقعی در ویندوز.

اسکریپت ابتدا فایل‌ها را بر اساس حجم دسته‌بندی می‌کند و سپس برای فایل‌های هم‌حجم از **SHA-256** استفاده می‌کند تا مطمئن شود فایل‌ها واقعاً یکسان هستند. فقط Duplicateهای تأییدشده امکان حذف دارند.

## قابلیت‌ها

* اسکن فایل‌ها و زیرپوشه‌ها
* مصرف پایین RAM
* ذخیره Index روی دیسک
* بررسی با SHA-256
* حالت امن `Dry Run`
* نمایش پیشرفت، سرعت و زمان باقی‌مانده
* نمایش Duplicateها در PowerShell
* ذخیره لاگ حذف‌ها در CSV
* امکان مستثنی کردن پوشه‌ها
* گزارش نهایی و بررسی مجدد
* مناسب برای مجموعه‌های بزرگ فایل

## استفاده

این تنظیمات را در فایل `DuplicateCleaner.ps1` تغییر دهید:

```powershell
$Folder = "D:\Your\Folder"
$ExcludeFolder = ""
$DryRun = $true
```

### حالت امن

به‌صورت پیش‌فرض:

```powershell
$DryRun = $true
```

اسکریپت Duplicateها را پیدا و گزارش می‌کند، اما هیچ فایلی را حذف نمی‌کند.

بعد از بررسی نتیجه، برای فعال کردن حذف فایل‌ها:

```powershell
$DryRun = $false
```

### اجرا

PowerShell را در پوشه پروژه باز کنید و اجرا کنید:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\DuplicateCleaner.ps1
```

گزارش نهایی مستقیماً داخل PowerShell نمایش داده می‌شود.

> قبل از حذف واقعی، همیشه ابتدا اسکریپت را در حالت `Dry Run` اجرا کنید.
