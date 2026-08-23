<#
.SYNOPSIS
    Low-RAM Duplicate File Cleaner for Windows

.DESCRIPTION
    Finds true duplicate files recursively.

    Duplicate detection:
        1. Files must have the same size.
        2. Files must have the same SHA-256 hash.

    The script uses a disk-backed index instead of keeping the
    complete file list in RAM. This makes it suitable for very
    large collections, including 1TB+ datasets.

    Features:
        - Recursive scanning
        - Very low RAM usage
        - Disk-backed indexing
        - SHA-256 verification
        - Optional excluded folder
        - Safe dry-run mode
        - Live progress
        - Speed and ETA
        - CSV deletion log
        - Final verification
        - Error handling
        - Automatic temporary-file cleanup

.NOTES
    Version : 1.1.0
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
# $true  = Scan only. NOTHING will be deleted.
# $false = Real deletion.

$DryRun = $true


# ------------------------------------------------------------
# LOG FILE
# ------------------------------------------------------------
# Created next to this script only if duplicates are found.

$LogFile = Join-Path `
    $PSScriptRoot `
    "duplicate-deletion-log.csv"


# ------------------------------------------------------------
# TEMP DIRECTORY
# ------------------------------------------------------------

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


function Write-Section {

    param (
        [string]$Title
    )

    Write-Host ""
    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host " $Title" `
        -ForegroundColor Cyan

    Write-Host "============================================================" `
        -ForegroundColor Cyan

    Write-Host ""
}


# ============================================================
# VALIDATION
# ============================================================

if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {

    Write-Host ""
    Write-Host "ERROR: Main folder does not exist." -ForegroundColor Red
    Write-Host $Folder -ForegroundColor Red
    Write-Host ""

    Read-Host "Press ENTER to exit"
    exit 1
}


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
        Write-Host "ERROR: Excluded folder does not exist." `
            -ForegroundColor Red

        Write-Host $ExcludeFolder -ForegroundColor Red
        Write-Host ""

        Read-Host "Press ENTER to exit"
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
    Write-Host "ERROR: Windows sort.exe was not found." `
        -ForegroundColor Red

    Write-Host ""

    Read-Host "Press ENTER to exit"
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
# CLEANUP FUNCTION
# ============================================================

function Remove-TemporaryFiles {

    Remove-Item `
        -LiteralPath $RawIndexFile `
        -Force `
        -ErrorAction SilentlyContinue

    Remove-Item `
        -LiteralPath $SortedIndexFile `
        -Force `
        -ErrorAction SilentlyContinue

    try {

        if (
            Test-Path `
                -LiteralPath $TempDirectory `
                -PathType Container
        ) {

            $Remaining =
                Get-ChildItem `
                    -LiteralPath $TempDirectory `
                    -Force `
                    -ErrorAction SilentlyContinue

            if ($null -eq $Remaining) {

                Remove-Item `
                    -LiteralPath $TempDirectory `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        # Cleanup failure is non-fatal.
    }
}


# ============================================================
# START
# ============================================================

Clear-Host

$ScriptStart = Get-Date


Write-Section "DUPLICATE FILE CLEANER"


Write-Host "Main folder : $Folder"

if ([string]::IsNullOrWhiteSpace($ExcludeFolder)) {

    Write-Host "Excluded    : NONE" -ForegroundColor DarkGray

}
else {

    Write-Host "Excluded    : $ExcludeFolder" `
        -ForegroundColor Yellow
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
# CREATE TEMP DIRECTORY
# ============================================================

try {

    New-Item `
        -ItemType Directory `
        -Path $TempDirectory `
        -Force `
        -ErrorAction Stop |
        Out-Null

}
catch {

    Write-Host ""
    Write-Host "ERROR: Could not create temporary directory." `
        -ForegroundColor Red

    Read-Host "Press ENTER to exit"
    exit 1
}


# ============================================================
# STEP 1
# SCAN FILES
# ============================================================

Write-Host "[1/4] Scanning files..." `
    -ForegroundColor Yellow

Write-Host "      Building disk-backed index..." `
    -ForegroundColor DarkGray

Write-Host ""


$ScanStart = Get-Date
$LastUpdate = $ScanStart


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


        if (Test-IsExcluded $File.FullName) {

            $ExcludedFiles++
            return
        }


        $FilesScanned++
        $TotalSizeBefore += $File.Length


        # Fixed-width 20-digit size prefix.
        #
        # Example:
        # 00000000000052428800    D:\folder\file.mp4

        $Line = "{0:D20}`t{1}" -f `
            $File.Length,
            $File.FullName


        $Writer.WriteLine($Line)


        # Live status every 2 seconds

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

Write-Host "Scan complete." `
    -ForegroundColor Green

Write-Host ""

Write-Host "Files scanned : $FilesScanned"
Write-Host "Total size    : $(Format-Size $TotalSizeBefore)"
Write-Host "Excluded      : $ExcludedFiles"
Write-Host "Scan errors   : $ScanErrors"

Write-Host ""


# ============================================================
# STEP 2
# SORT INDEX
# ============================================================

Write-Host "[2/4] Sorting size index..." `
    -ForegroundColor Yellow

Write-Host "      Sorting is performed on disk." `
    -ForegroundColor DarkGray

Write-Host ""


$SortStart = Get-Date


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

    Remove-TemporaryFiles

    Read-Host "Press ENTER to exit"
    exit 1
}


$SortTime = (Get-Date) - $SortStart


Remove-Item `
    -LiteralPath $RawIndexFile `
    -Force `
    -ErrorAction SilentlyContinue


Write-Host "Sort complete." `
    -ForegroundColor Green

Write-Host "Sort time: $([math]::Round($SortTime.TotalMinutes, 1)) minutes"

Write-Host ""


# ============================================================
# STEP 3
# FIND TRUE DUPLICATES
# ============================================================

Write-Host "[3/4] Checking duplicate contents..." `
    -ForegroundColor Yellow

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
# First pass:
# Count same-size candidate groups
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

        if ($Line.Length -lt 21) {
            continue
        }

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
# If there are no candidates, skip hashing completely.
# ------------------------------------------------------------

if ($CandidateFiles -eq 0) {

    Write-Host "No same-size candidate files were found." `
        -ForegroundColor Green

}
else {

    # --------------------------------------------------------
    # Second pass:
    # SHA-256 comparison
    # --------------------------------------------------------

    $Reader = New-Object `
        System.IO.StreamReader(
            $SortedIndexFile,
            [System.Text.Encoding]::UTF8,
            $true
        )


    $CurrentSize = $null

    # Only one size group exists in memory at a time.
    $HashMap = @{}

    $HashStart = Get-Date


    try {

        while (($Line = $Reader.ReadLine()) -ne $null) {

            if ($Line.Length -lt 21) {
                continue
            }


            $FileSize =
                [Int64]$Line.Substring(0, 20)

            $Path =
                $Line.Substring(21)


            # ------------------------------------------------
            # New size group
            # ------------------------------------------------

            if (
                $CurrentSize -ne $null -and
                $FileSize -ne $CurrentSize
            ) {

                $HashMap.Clear()
            }


            $CurrentSize = $FileSize


            # ------------------------------------------------
            # Progress
            # ------------------------------------------------

            $ProcessedCandidates++


            $Percent = [math]::Floor(
                ($ProcessedCandidates / $CandidateFiles) * 100
            )


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
                    [TimeSpan]::FromSeconds(
                        $ETASeconds
                    )

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


            # ------------------------------------------------
            # Verify file still exists
            # ------------------------------------------------

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


            # ------------------------------------------------
            # SHA-256
            # ------------------------------------------------

            $Hash =
                Get-FileHashSafe -Path $Path


            if ($null -eq $Hash) {

                $HashErrors++
                continue
            }


            # ------------------------------------------------
            # First file with this hash
            # ------------------------------------------------

            if (-not $HashMap.ContainsKey($Hash)) {

                $HashMap[$Hash] = $Path
                continue
            }


            # =================================================
            # TRUE DUPLICATE
            # =================================================

            $KeptFile =
                $HashMap[$Hash]


            $DuplicatesFound++


            # ------------------------------------------------
            # Default action
            # ------------------------------------------------

            $Action = "WOULD_DELETE"


            # ------------------------------------------------
            # Delete duplicate
            # ------------------------------------------------

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


            # ------------------------------------------------
            # Console output for every duplicate
            # ------------------------------------------------

            Write-Host ""
            Write-Host "Duplicate found:" `
                -ForegroundColor Yellow

            Write-Host "  Duplicate : $Path"
            Write-Host "  Keeping   : $KeptFile"
            Write-Host "  Size      : $(Format-Size $FileSize)"
            Write-Host "  SHA-256   : $Hash"
            Write-Host "  Action    : $Action" `
                -ForegroundColor $(
                    if ($Action -eq "DELETED") {
                        "Green"
                    }
                    elseif ($Action -eq "DELETE_FAILED") {
                        "Red"
                    }
                    else {
                        "Yellow"
                    }
                )


            # ------------------------------------------------
            # CSV LOG
            # ------------------------------------------------

            $LogEntry = [PSCustomObject]@{

                Timestamp =
                    (Get-Date).ToString(
                        "yyyy-MM-dd HH:mm:ss"
                    )

                Action =
                    $Action

                DuplicateFile =
                    $Path

                KeptFile =
                    $KeptFile

                SizeBytes =
                    $FileSize

                Size =
                    Format-Size $FileSize

                SHA256 =
                    $Hash
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
}


Write-Progress `
    -Activity "SHA-256 duplicate check" `
    -Completed


Write-Host ""
Write-Host "Duplicate check complete." `
    -ForegroundColor Green

Write-Host ""


# ============================================================
# STEP 4
# FINAL VERIFICATION
# ============================================================

Write-Host "[4/4] Verifying final folder status..." `
    -ForegroundColor Yellow

Write-Host ""


$FilesAfter = 0
$TotalSizeAfter = [Int64]0
$FinalScanErrors = 0

$FinalScanStart = Get-Date
$LastUpdate = $FinalScanStart


try {

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

}
catch {

    $FinalScanErrors++
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

Write-Section "FINAL REPORT"


Write-Host "FILES"
Write-Host "  Before       : $FilesScanned"
Write-Host "  Duplicates   : $DuplicatesFound"
Write-Host "  Deleted      : $FilesDeleted"
Write-Host "  Remaining    : $FilesAfter"

Write-Host ""

Write-Host "STORAGE"
Write-Host "  Before       : $(Format-Size $TotalSizeBefore)"
Write-Host "  Freed        : $(Format-Size $ActualFreed)"
Write-Host "  After        : $(Format-Size $TotalSizeAfter)"

Write-Host ""

Write-Host "DUPLICATES"
Write-Host "  Candidate groups : $CandidateGroups"
Write-Host "  Candidate files  : $CandidateFiles"
Write-Host "  True duplicates  : $DuplicatesFound"

Write-Host ""

Write-Host "PERFORMANCE"
Write-Host "  Total time   : $([math]::Round($TotalTime.TotalMinutes, 1)) minutes"
Write-Host "  Errors       : $TotalErrors"

Write-Host ""


# ============================================================
# MODE
# ============================================================

if ($DryRun) {

    Write-Host "MODE"
    Write-Host "  DRY RUN - NOTHING WAS DELETED" `
        -ForegroundColor Yellow

}
else {

    Write-Host "MODE"
    Write-Host "  LIVE - DUPLICATES WERE DELETED" `
        -ForegroundColor Green
}


Write-Host ""


# ============================================================
# LOG
# ============================================================

if (Test-Path -LiteralPath $LogFile) {

    Write-Host "LOG"
    Write-Host "  $LogFile" `
        -ForegroundColor Cyan

}
else {

    Write-Host "LOG"
    Write-Host "  No duplicate log was created." `
        -ForegroundColor DarkGray
}


Write-Host ""


# ============================================================
# CLEANUP
# ============================================================

Write-Host "Cleaning temporary files..." `
    -ForegroundColor DarkGray


Remove-TemporaryFiles


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


Read-Host "Press ENTER to exit"
