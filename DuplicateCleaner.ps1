<#
.SYNOPSIS
    Low-RAM Duplicate File Cleaner for Windows

.DESCRIPTION
    Finds and removes true duplicate files recursively.

    Duplicate detection:
        1. Files must have the same size.
        2. Files must have the same SHA-256 hash.

    The script uses a disk-backed size index instead of keeping the
    complete file list in RAM. This makes it suitable for very large
    collections, including 1TB+ datasets and hundreds of thousands
    of files.

    Features:
        - Recursive scanning
        - Low RAM usage
        - Disk-backed indexing
        - SHA-256 verification
        - Exclude folder support
        - Dry-run mode
        - Live progress
        - Speed and ETA
        - CSV deletion log
        - Final verification scan
        - Error handling
        - Temporary-file cleanup

.NOTES
    Version : 1.0.0
    Platform: Windows PowerShell 5.1+ / PowerShell 7+
#>


# ============================================================
# CONFIGURATION
# ============================================================

# Main folder to scan
$Folder = ""


# Folder to completely exclude.
# Leave empty ("") to disable exclusion.
#
# Example:
# $ExcludeFolder = "D:\Important"

$ExcludeFolder = ""


# ------------------------------------------------------------
# SAFETY MODE
# ------------------------------------------------------------
# $true  = Scan and report only. NO files are deleted.
# $false = Real deletion.

$DryRun = $true


# ------------------------------------------------------------
# LOG FILE
# ------------------------------------------------------------
# The deletion log is created next to this script.

$LogFile = Join-Path `
    $PSScriptRoot `
    "duplicate-deletion-log.csv"


# ------------------------------------------------------------
# TEMP DIRECTORY
# ------------------------------------------------------------
# Temporary index files are created here.
# They are deleted automatically when the script finishes.

$TempDirectory = Join-Path `
    ([System.IO.Path]::GetTempPath()) `
    "DuplicateCleaner"


# ============================================================
# FUNCTIONS
# ============================================================

function Format-Size {

    param (
        [Int64]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return "{0:N2} TB" -f ($Bytes / 1TB)
    }

    if ($Bytes -ge 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }

    if ($Bytes -ge 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    }

    if ($Bytes -ge 1KB) {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }

    return "$Bytes B"
}


function Test-IsExcluded {

    param (
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($ExcludeFolder)) {
        return $false
    }

    $Path = $Path.TrimEnd('\')
    $Excluded = $ExcludeFolder.TrimEnd('\')

    if ($Path -ieq $Excluded) {
        return $true
    }

    if (
        $Path.StartsWith(
            "$Excluded\",
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        return $true
    }

    return $false
}


function Get-FileHashSafe {

    param (
        [string]$Path
    )

    try {

        return (
            Get-FileHash `
                -LiteralPath $Path `
                -Algorithm SHA256 `
                -ErrorAction Stop
        ).Hash

    }
    catch {

        return $null
    }
}


# ============================================================
# VALIDATION
# ============================================================

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {

    Write-Host ""
    Write-Host "ERROR: Main folder does not exist." -ForegroundColor Red
    Write-Host $Folder -ForegroundColor Red
    exit 1
}


# Resolve main folder to absolute path
$Folder = (
    Resolve-Path `
        -LiteralPath $Folder `
        -ErrorAction Stop
).Path


# ------------------------------------------------------------
# Validate excluded folder
# ------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($ExcludeFolder)) {

    if (
        -not (
            Test-Path `
                -LiteralPath $ExcludeFolder `
                -PathType Container
        )
    ) {

        Write-Host ""
        Write-Host "ERROR: Excluded folder does not exist." -ForegroundColor Red
        Write-Host $ExcludeFolder -ForegroundColor Red
        exit 1
    }

    $ExcludeFolder = (
        Resolve-Path `
            -LiteralPath $ExcludeFolder `
            -ErrorAction Stop
    ).Path
}


# ------------------------------------------------------------
# Check sort.exe
# ------------------------------------------------------------

$SortExe = Join-Path `
    $env:SystemRoot `
    "System32\sort.exe"


if (-not (Test-Path -LiteralPath $SortExe)) {

    Write-Host ""
    Write-Host "ERROR: Windows sort.exe was not found." -ForegroundColor Red
    exit 1
}


# ============================================================
# TEMP FILES
# ============================================================

$RunId = [Guid]::NewGuid().ToString("N")

$RawIndexFile = Join-Path `
    $TempDirectory `
    "index-$RunId.txt"

$SortedIndexFile = Join-Path `
    $TempDirectory `
    "sorted-$RunId.txt"


# ============================================================
# CREATE TEMP DIRECTORY
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $TempDirectory `
    -Force `
    -ErrorAction Stop |
    Out-Null


# ============================================================
# START
# ============================================================

Clear-Host

$ScriptStart = Get-Date

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "              DUPLICATE FILE CLEANER" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Main folder : $Folder"

if ([string]::IsNullOrWhiteSpace($ExcludeFolder)) {

    Write-Host "Excluded    : NONE" -ForegroundColor DarkGray

}
else {

    Write-Host "Excluded    : $ExcludeFolder" -ForegroundColor Yellow
}


if ($DryRun) {

    Write-Host "Mode        : DRY RUN - NO FILES WILL BE DELETED" `
        -ForegroundColor Yellow

}
else {

    Write-Host "Mode        : LIVE - DUPLICATES WILL BE DELETED" `
        -ForegroundColor Red
}

Write-Host ""


# ============================================================
# COUNTERS
# ============================================================

$FilesScanned = 0
$TotalSizeBefore = [Int64]0

$ExcludedFiles = 0
$ScanErrors = 0


# ============================================================
# STEP 1
# STREAM FILES INTO DISK-BACKED INDEX
# ============================================================

Write-Host "[1/4] Scanning files..." -ForegroundColor Yellow
Write-Host "      Building disk-backed index..." -ForegroundColor DarkGray
Write-Host ""


$ScanStart = Get-Date
$LastUpdate = $ScanStart


# ------------------------------------------------------------
# StreamWriter
# ------------------------------------------------------------

$Writer = New-Object `
    System.IO.StreamWriter(
        $RawIndexFile,
        $false,
        [System.Text.UTF8Encoding]::new($false)
    )


try {

    Get-ChildItem `
        -LiteralPath $Folder `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |

    ForEach-Object {

        $File = $_


        # ----------------------------------------------------
        # Exclude
        # ----------------------------------------------------

        if (Test-IsExcluded $File.FullName) {

            $ExcludedFiles++
            return
        }


        # ----------------------------------------------------
        # File counters
        # ----------------------------------------------------

        $FilesScanned++
        $TotalSizeBefore += $File.Length


        # ----------------------------------------------------
        # Fixed-width size prefix
        #
        # 20 digits supports files up to ~9.9 EB.
        #
        # Example:
        # 00000000000052428800    D:\folder\file.mp4
        # ----------------------------------------------------

        $Line = "{0:D20}`t{1}" -f `
            $File.Length,
            $File.FullName


        $Writer.WriteLine($Line)


        # ----------------------------------------------------
        # Live status every 2 seconds
        # ----------------------------------------------------

        $Now = Get-Date

        if (($Now - $LastUpdate).TotalSeconds -ge 2) {

            $ElapsedSeconds =
                ($Now - $ScanStart).TotalSeconds


            if ($ElapsedSeconds -gt 0) {

                $Speed = [math]::Round(
                    $FilesScanned / $ElapsedSeconds,
                    1
                )

            }
            else {

                $Speed = 0
            }


            Write-Host `
                "`rFiles scanned: $FilesScanned | Size: $(Format-Size $TotalSizeBefore) | Speed: $Speed files/sec" `
                -NoNewline


            $LastUpdate = $Now
        }
    }

}
catch {

    $ScanErrors++

    Write-Host ""
    Write-Host ""
    Write-Host "WARNING: Error while scanning files." `
        -ForegroundColor Yellow
}

finally {

    $Writer.Flush()
    $Writer.Dispose()
}


Write-Host ""
Write-Host ""

Write-Host "Scan complete." -ForegroundColor Green

Write-Host ""
Write-Host "Files scanned : $FilesScanned"
Write-Host "Total size    : $(Format-Size $TotalSizeBefore)"
Write-Host "Excluded      : $ExcludedFiles"
Write-Host "Scan errors   : $ScanErrors"
Write-Host ""


# ============================================================
# STEP 2
# SORT INDEX ON DISK
# ============================================================

Write-Host "[2/4] Sorting size index..." -ForegroundColor Yellow
Write-Host "      Sorting is performed on disk." -ForegroundColor DarkGray
Write-Host ""


$SortStart = Get-Date


# Windows sort.exe sorts text lexicographically.
# Because file sizes have a fixed 20-digit prefix,
# lexicographical sorting produces numeric size ordering.

& $SortExe `
    $RawIndexFile `
    /O $SortedIndexFile `
    /REC 65535 `
    2>$null


$SortExitCode = $LASTEXITCODE


if ($SortExitCode -ne 0) {

    Write-Host ""
    Write-Host "ERROR: Sorting the index failed." `
        -ForegroundColor Red

    Write-Host "Sort exit code: $SortExitCode" `
        -ForegroundColor Red

    Remove-Item `
        -LiteralPath $RawIndexFile `
        -Force `
        -ErrorAction SilentlyContinue

    exit 1
}


$SortTime = (Get-Date) - $SortStart


Remove-Item `
    -LiteralPath $RawIndexFile `
    -Force `
    -ErrorAction SilentlyContinue


Write-Host "Sort complete." -ForegroundColor Green
Write-Host "Sort time: $([math]::Round($SortTime.TotalMinutes, 1)) minutes"
Write-Host ""


# ============================================================
# STEP 3
# STREAM SORTED INDEX + HASH DUPLICATES
# ============================================================

Write-Host "[3/4] Checking duplicate contents..." -ForegroundColor Yellow
Write-Host "      Same-size files are verified using SHA-256." `
    -ForegroundColor DarkGray
Write-Host ""



$CandidateFiles = 0
$CandidateGroups = 0

$DuplicatesFound = 0
$FilesDeleted = 0

$BytesFreed = [Int64]0

$HashErrors = 0
$DeleteErrors = 0

$ProcessedCandidates = 0


# ------------------------------------------------------------
# First pass over sorted index to count candidates
#
# This does NOT load the index into RAM.
# ------------------------------------------------------------

$Reader = New-Object `
    System.IO.StreamReader(
        $SortedIndexFile,
        [System.Text.Encoding]::UTF8,
        $true
    )


try {

    $PreviousSize = $null
    $CurrentGroupCount = 0

    while (($Line = $Reader.ReadLine()) -ne $null) {

        $CurrentSize =
            [Int64]$Line.Substring(0, 20)


        if ($PreviousSize -eq $null) {

            $PreviousSize = $CurrentSize
            $CurrentGroupCount = 1

        }
        elseif ($CurrentSize -eq $PreviousSize) {

            $CurrentGroupCount++

        }
        else {

            if ($CurrentGroupCount -gt 1) {

                $CandidateGroups++
                $CandidateFiles += $CurrentGroupCount

            }

            $PreviousSize = $CurrentSize
            $CurrentGroupCount = 1
        }
    }


    if ($CurrentGroupCount -gt 1) {

        $CandidateGroups++
        $CandidateFiles += $CurrentGroupCount

    }

}
finally {

    $Reader.Dispose()
}


Write-Host "Candidate groups : $CandidateGroups"
Write-Host "Candidate files  : $CandidateFiles"
Write-Host ""


# ------------------------------------------------------------
# Second pass: actual hash comparison
# ------------------------------------------------------------

$Reader = New-Object `
    System.IO.StreamReader(
        $SortedIndexFile,
        [System.Text.Encoding]::UTF8,
        $true
    )


$CurrentSize = $null

# Hash map exists only for ONE size group at a time.
$HashMap = @{}

$HashStart = Get-Date


try {

    while (($Line = $Reader.ReadLine()) -ne $null) {


        # ----------------------------------------------------
        # Parse fixed-width size and path
        # ----------------------------------------------------

        $FileSize =
            [Int64]$Line.Substring(0, 20)

        $Path =
            $Line.Substring(21)


        # ----------------------------------------------------
        # New size group
        # ----------------------------------------------------

        if (
            $CurrentSize -ne $null -and
            $FileSize -ne $CurrentSize
        ) {

            # Release previous group from RAM
            $HashMap.Clear()

        }


        $CurrentSize = $FileSize


        # ----------------------------------------------------
        # Progress
        # ----------------------------------------------------

        $ProcessedCandidates++


        if ($CandidateFiles -gt 0) {

            $Percent = [math]::Floor(
                ($ProcessedCandidates / $CandidateFiles) * 100
            )

        }
        else {

            $Percent = 100
        }


        $Elapsed =
            (Get-Date) - $HashStart


        if ($Elapsed.TotalSeconds -gt 0) {

            $Speed = [math]::Round(
                $ProcessedCandidates /
                $Elapsed.TotalSeconds,
                1
            )

        }
        else {

            $Speed = 0
        }


        if ($Speed -gt 0) {

            $Remaining =
                $CandidateFiles -
                $ProcessedCandidates

            $ETASeconds =
                $Remaining / $Speed

            $ETA =
                [TimeSpan]::FromSeconds($ETASeconds)

            $ETAString =
                $ETA.ToString("hh\:mm\:ss")

        }
        else {

            $ETAString = "--:--:--"
        }


        Write-Progress `
            -Activity "SHA-256 duplicate check" `
            -Status "$Percent% | $ProcessedCandidates / $CandidateFiles | Duplicates: $DuplicatesFound | Speed: $Speed files/sec | ETA: $ETAString" `
            -PercentComplete $Percent


        # ----------------------------------------------------
        # Check file
        # ----------------------------------------------------

        if (
            -not (
                Test-Path `
                    -LiteralPath $Path `
                    -PathType Leaf
            )
        ) {

            $HashErrors++
            continue
        }


        # ----------------------------------------------------
        # SHA-256
        # ----------------------------------------------------

        $Hash =
            Get-FileHashSafe -Path $Path


        if ($null -eq $Hash) {

            $HashErrors++
            continue
        }


        # ----------------------------------------------------
        # First file with this hash
        # ----------------------------------------------------

        if (-not $HashMap.ContainsKey($Hash)) {

            $HashMap[$Hash] = $Path

            continue
        }


        # ====================================================
        # TRUE DUPLICATE
        # ====================================================

        $KeptFile =
            $HashMap[$Hash]


        $DuplicatesFound++


        # ----------------------------------------------------
        # Log information
        # ----------------------------------------------------

        $Action = "WOULD_DELETE"


        if (-not $DryRun) {

            try {

                Remove-Item `
                    -LiteralPath $Path `
                    -Force `
                    -ErrorAction Stop

                $Action = "DELETED"

                $FilesDeleted++
                $BytesFreed += $FileSize

            }
            catch {

                $Action = "DELETE_FAILED"
                $DeleteErrors++

            }
        }


        # ----------------------------------------------------
        # CSV LOG
        # ----------------------------------------------------

        $LogEntry = [PSCustomObject]@{

            Timestamp     = (Get-Date).ToString(
                "yyyy-MM-dd HH:mm:ss"
            )

            Action        = $Action

            DuplicateFile = $Path

            KeptFile      = $KeptFile

            SizeBytes     = $FileSize

            Size          = Format-Size $FileSize

            SHA256        = $Hash
        }


        if (-not (Test-Path -LiteralPath $LogFile)) {

            $LogEntry |
                Export-Csv `
                    -LiteralPath $LogFile `
                    -NoTypeInformation `
                    -Encoding UTF8

        }
        else {

            $LogEntry |
                Export-Csv `
                    -LiteralPath $LogFile `
                    -NoTypeInformation `
                    -Append `
                    -Encoding UTF8
        }
    }

}
finally {

    $Reader.Dispose()
    $HashMap.Clear()
}


Write-Progress `
    -Activity "SHA-256 duplicate check" `
    -Completed


Write-Host ""
Write-Host "Duplicate check complete." -ForegroundColor Green
Write-Host ""


# ============================================================
# STEP 4
# FINAL VERIFICATION SCAN
# ============================================================

Write-Host "[4/4] Verifying final folder status..." -ForegroundColor Yellow
Write-Host ""


$FilesAfter = 0
$TotalSizeAfter = [Int64]0
$FinalScanErrors = 0

$FinalScanStart = Get-Date
$LastUpdate = $FinalScanStart


Get-ChildItem `
    -LiteralPath $Folder `
    -File `
    -Recurse `
    -ErrorAction SilentlyContinue |

ForEach-Object {

    $File = $_


    if (Test-IsExcluded $File.FullName) {
        return
    }


    $FilesAfter++
    $TotalSizeAfter += $File.Length


    $Now = Get-Date


    if (($Now - $LastUpdate).TotalSeconds -ge 2) {

        $Elapsed =
            ($Now - $FinalScanStart).TotalSeconds


        if ($Elapsed -gt 0) {

            $Speed = [math]::Round(
                $FilesAfter / $Elapsed,
                1
            )

        }
        else {

            $Speed = 0
        }


        Write-Host `
            "`rVerifying: $FilesAfter files | Size: $(Format-Size $TotalSizeAfter) | Speed: $Speed files/sec" `
            -NoNewline


        $LastUpdate = $Now
    }
}


Write-Host ""
Write-Host ""


# ============================================================
# FINAL CALCULATIONS
# ============================================================

$ActualFreed =
    $TotalSizeBefore -
    $TotalSizeAfter


$TotalTime =
    (Get-Date) -
    $ScriptStart


$TotalErrors =
    $ScanErrors +
    $HashErrors +
    $DeleteErrors +
    $FinalScanErrors


# ============================================================
# FINAL REPORT
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host "                     FINAL REPORT" `
    -ForegroundColor Green

Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host ""


# ------------------------------------------------------------
# Main summary
# ------------------------------------------------------------

Write-Host `
    "FILES    : $FilesScanned before | $FilesDeleted deleted | $FilesAfter remaining" `
    -ForegroundColor White


Write-Host `
    "SIZE     : $(Format-Size $TotalSizeBefore) before | $(Format-Size $ActualFreed) freed | $(Format-Size $TotalSizeAfter) after" `
    -ForegroundColor White


Write-Host `
    "DUPLICATE: $DuplicatesFound real | $CandidateFiles candidates | $CandidateGroups size-groups" `
    -ForegroundColor Yellow


Write-Host `
    "TIME     : $([math]::Round($TotalTime.TotalMinutes, 1)) minutes | Errors: $TotalErrors" `
    -ForegroundColor White


Write-Host ""


# ------------------------------------------------------------
# Mode
# ------------------------------------------------------------

if ($DryRun) {

    Write-Host `
        "MODE     : DRY RUN - NOTHING WAS DELETED" `
        -ForegroundColor Yellow

}
else {

    Write-Host `
        "MODE     : LIVE - DUPLICATES DELETED" `
        -ForegroundColor Green
}


# ------------------------------------------------------------
# Exclusion
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ExcludeFolder)) {

    Write-Host "EXCLUDE  : NONE" -ForegroundColor DarkGray

}
else {

    Write-Host `
        "EXCLUDE  : $ExcludeFolder" `
        -ForegroundColor Yellow
}


# ------------------------------------------------------------
# Log
# ------------------------------------------------------------

if (Test-Path -LiteralPath $LogFile) {

    Write-Host ""
    Write-Host "LOG      : $LogFile" -ForegroundColor Cyan
}


# ============================================================
# CLEANUP TEMP FILES
# ============================================================

Write-Host ""
Write-Host "Cleaning temporary files..." -ForegroundColor DarkGray


Remove-Item `
    -LiteralPath $RawIndexFile `
    -Force `
    -ErrorAction SilentlyContinue


Remove-Item `
    -LiteralPath $SortedIndexFile `
    -Force `
    -ErrorAction SilentlyContinue


# Remove temp directory if empty
try {

    if (
        (Get-ChildItem `
            -LiteralPath $TempDirectory `
            -Force `
            -ErrorAction SilentlyContinue).Count -eq 0
    ) {

        Remove-Item `
            -LiteralPath $TempDirectory `
            -Force `
            -ErrorAction SilentlyContinue
    }

}
catch {
    # Temporary directory cleanup failure is non-fatal.
}


# ============================================================
# END
# ============================================================

Write-Host ""
Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host "                  PROCESS COMPLETED" `
    -ForegroundColor Green

Write-Host "============================================================" `
    -ForegroundColor Green

Write-Host ""
