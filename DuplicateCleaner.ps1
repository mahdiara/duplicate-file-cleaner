<#
.SYNOPSIS
    Low-RAM Duplicate File Cleaner for Windows

.DESCRIPTION
    Finds true duplicate files recursively.

    A duplicate is confirmed when:
        1. File size is identical.
        2. SHA-256 hash is identical.

    Files are distributed into disk-backed buckets.
    Only one bucket is processed at a time, keeping RAM usage low.

    Designed for large collections, including 1TB+ datasets.

.NOTES
    Version : 3.0.0
    Platform: Windows PowerShell 5.1+ / PowerShell 7+
#>


# ============================================================
# CONFIGURATION
# ============================================================

# Folder to scan
$Folder = ""


# Folder to exclude
# Leave empty to disable
$ExcludeFolder = ""


# SAFETY MODE
# $true  = Find and report duplicates only
# $false = Delete duplicates

$DryRun = $true


# Number of disk buckets.
# More buckets = lower RAM usage.

$BucketCount = 2048


# CSV log file
$LogFile = Join-Path `
    $PSScriptRoot `
    "duplicate-deletion-log.csv"


# Temporary directory
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


function Remove-TempFolder {

    if (
        Test-Path `
            -LiteralPath $TempDirectory `
            -PathType Container
    ) {

        Remove-Item `
            -LiteralPath $TempDirectory `
            -Recurse `
            -Force `
            -Confirm:$false `
            -ErrorAction SilentlyContinue
    }
}


function Write-Header {

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

if ([string]::IsNullOrWhiteSpace($Folder)) {

    Write-Host ""
    Write-Host "ERROR: Folder is not configured." `
        -ForegroundColor Red

    Write-Host ""
    Read-Host "Press ENTER to exit"

    exit 1
}


if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {

    Write-Host ""
    Write-Host "ERROR: Folder does not exist:" `
        -ForegroundColor Red

    Write-Host $Folder `
        -ForegroundColor Red

    Write-Host ""
    Read-Host "Press ENTER to exit"

    exit 1
}


try {

    $Folder = (
        Resolve-Path `
            -LiteralPath $Folder `
            -ErrorAction Stop
    ).Path

}
catch {

    Write-Host ""
    Write-Host "ERROR: Could not resolve folder." `
        -ForegroundColor Red

    Write-Host $_.Exception.Message `
        -ForegroundColor Red

    Read-Host "Press ENTER to exit"

    exit 1
}


# ------------------------------------------------------------
# Excluded folder
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

        Write-Host $ExcludeFolder `
            -ForegroundColor Red

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


# ============================================================
# TEMP DIRECTORY
# ============================================================

$RunId = [Guid]::NewGuid().ToString("N")

$RunDirectory = Join-Path `
    $TempDirectory `
    $RunId


try {

    New-Item `
        -ItemType Directory `
        -Path $RunDirectory `
        -Force `
        -ErrorAction Stop |
        Out-Null

}
catch {

    Write-Host ""
    Write-Host "ERROR: Could not create temporary directory." `
        -ForegroundColor Red

    Write-Host $_.Exception.Message `
        -ForegroundColor Red

    Read-Host "Press ENTER to exit"

    exit 1
}


# ============================================================
# START
# ============================================================

Clear-Host

$StartTime = Get-Date


Write-Header "DUPLICATE FILE CLEANER"


Write-Host "Folder      : $Folder"


if ([string]::IsNullOrWhiteSpace($ExcludeFolder)) {

    Write-Host "Excluded    : NONE" `
        -ForegroundColor DarkGray

}
else {

    Write-Host "Excluded    : $ExcludeFolder" `
        -ForegroundColor Yellow
}


if ($DryRun) {

    Write-Host "Mode        : DRY RUN - NOTHING WILL BE DELETED" `
        -ForegroundColor Yellow

}
else {

    Write-Host "Mode        : LIVE - DUPLICATES WILL BE DELETED" `
        -ForegroundColor Red
}


Write-Host "Buckets     : $BucketCount"

Write-Host ""


# ============================================================
# COUNTERS
# ============================================================

$FilesScanned = 0
$ExcludedFiles = 0
$ScanErrors = 0

$TotalSizeBefore = [Int64]0


$DuplicatesFound = 0
$FilesDeleted = 0
$BytesFreed = [Int64]0

$HashErrors = 0
$DeleteErrors = 0


# ============================================================
# STEP 1
# CREATE DISK-BACKED BUCKETS
# ============================================================

Write-Host "[1/4] Scanning files..." `
    -ForegroundColor Yellow

Write-Host "      Creating disk-backed index..." `
    -ForegroundColor DarkGray

Write-Host ""


$ScanStart = Get-Date
$LastUpdate = $ScanStart


# ------------------------------------------------------------
# Open bucket writers only when needed.
# ------------------------------------------------------------

$BucketWriters = @{}

try {

    Get-ChildItem `
        -LiteralPath $Folder `
        -File `
        -Recurse `
        -ErrorAction SilentlyContinue |

    ForEach-Object {

        $File = $_


        # ----------------------------------------------------
        # Excluded folder
        # ----------------------------------------------------

        if (Test-IsExcluded $File.FullName) {

            $ExcludedFiles++

            return
        }


        # ----------------------------------------------------
        # Counters
        # ----------------------------------------------------

        $FilesScanned++

        $TotalSizeBefore += $File.Length


        # ----------------------------------------------------
        # Select bucket using file size
        # ----------------------------------------------------

        $BucketNumber =
            [int]($File.Length % $BucketCount)


        $BucketFile = Join-Path `
            $RunDirectory `
            ("bucket-{0:D4}.txt" -f $BucketNumber)


        # ----------------------------------------------------
        # Create writer when first needed
        # ----------------------------------------------------

        if (-not $BucketWriters.ContainsKey($BucketNumber)) {

            $BucketWriters[$BucketNumber] =
                New-Object `
                    System.IO.StreamWriter(
                        $BucketFile,
                        $false,
                        [System.Text.UTF8Encoding]::new($false)
                    )
        }


        # ----------------------------------------------------
        # Fixed-width size + TAB + path
        # ----------------------------------------------------

        $Line = "{0:D20}`t{1}" -f `
            $File.Length,
            $File.FullName


        $BucketWriters[$BucketNumber].WriteLine($Line)


        # ----------------------------------------------------
        # Live progress
        # ----------------------------------------------------

        $Now = Get-Date


        if (($Now - $LastUpdate).TotalSeconds -ge 2) {

            $Elapsed =
                ($Now - $ScanStart).TotalSeconds


            if ($Elapsed -gt 0) {

                $Speed = [math]::Round(
                    $FilesScanned / $Elapsed,
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
    Write-Host "WARNING: Error while scanning." `
        -ForegroundColor Yellow

    Write-Host $_.Exception.Message `
        -ForegroundColor Yellow
}

finally {

    # --------------------------------------------------------
    # Close ALL bucket writers before doing anything else.
    # --------------------------------------------------------

    foreach ($Writer in $BucketWriters.Values) {

        try {
            $Writer.Flush()
            $Writer.Dispose()
        }
        catch {
            # Ignore cleanup errors.
        }
    }

    $BucketWriters.Clear()
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
# FIND SAME-SIZE CANDIDATES
# ============================================================

Write-Host "[2/4] Finding same-size candidates..." `
    -ForegroundColor Yellow

Write-Host "      Processing one disk bucket at a time." `
    -ForegroundColor DarkGray

Write-Host ""


$CandidateFiles = 0
$CandidateGroups = 0


$BucketFiles = @(
    Get-ChildItem `
        -LiteralPath $RunDirectory `
        -Filter "bucket-*.txt" `
        -File `
        -ErrorAction SilentlyContinue |
    Sort-Object Name
)


foreach ($BucketFile in $BucketFiles) {

    Write-Host `
        "`rProcessing bucket: $($BucketFile.Name)" `
        -NoNewline


    $Groups = @(
        Get-Content `
            -LiteralPath $BucketFile.FullName `
            -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Length -ge 21
        } |
        Group-Object {
            $_.Substring(0, 20)
        } |
        Where-Object {
            $_.Count -gt 1
        }
    )


    foreach ($Group in $Groups) {

        $CandidateGroups++

        $CandidateFiles += $Group.Count
    }
}


Write-Host ""
Write-Host ""

Write-Host "Candidate groups : $CandidateGroups"
Write-Host "Candidate files  : $CandidateFiles"

Write-Host ""


# ============================================================
# STEP 3
# SHA-256 DUPLICATE CHECK
# ============================================================

Write-Host "[3/4] Checking duplicate contents..." `
    -ForegroundColor Yellow

Write-Host "      SHA-256 is calculated only for same-size files." `
    -ForegroundColor DarkGray

Write-Host ""


$ProcessedCandidates = 0
$HashStart = Get-Date


foreach ($BucketFile in $BucketFiles) {

    # --------------------------------------------------------
    # Load only this bucket.
    # --------------------------------------------------------

    $Lines = @(
        Get-Content `
            -LiteralPath $BucketFile.FullName `
            -ErrorAction SilentlyContinue
    )


    if ($Lines.Count -eq 0) {
        continue
    }


    # --------------------------------------------------------
    # Group by exact file size.
    # --------------------------------------------------------

    $Groups = @(
        $Lines |
        Where-Object {
            $_.Length -ge 21
        } |
        Group-Object {
            $_.Substring(0, 20)
        } |
        Where-Object {
            $_.Count -gt 1
        }
    )


    foreach ($Group in $Groups) {

        # ----------------------------------------------------
        # Hash map for ONE size group only.
        # ----------------------------------------------------

        $HashMap = @{}


        foreach ($Item in $Group.Group) {

            $ProcessedCandidates++


            # ------------------------------------------------
            # Progress
            # ------------------------------------------------

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
            # Extract path
            # ------------------------------------------------

            $Path =
                $Item.Substring(21)


            # ------------------------------------------------
            # Check file
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
            # Hash
            # ------------------------------------------------

            $Hash =
                Get-FileHashSafe `
                    -Path $Path


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


            $FileSize =
                [Int64]$Item.Substring(0, 20)


            $DuplicatesFound++


            # ------------------------------------------------
            # Action
            # ------------------------------------------------

            $Action = "WOULD_DELETE"


            if (-not $DryRun) {

                try {

                    Remove-Item `
                        -LiteralPath $Path `
                        -Force `
                        -Confirm:$false `
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
            # Console report
            # ------------------------------------------------

            Write-Host ""

            Write-Host "Duplicate found:" `
                -ForegroundColor Yellow

            Write-Host "  Duplicate : $Path"

            Write-Host "  Keeping   : $KeptFile"

            Write-Host "  Size      : $(Format-Size $FileSize)"

            Write-Host "  SHA-256   : $Hash"


            if ($Action -eq "DELETED") {

                Write-Host "  Action    : DELETED" `
                    -ForegroundColor Green

            }
            elseif ($Action -eq "DELETE_FAILED") {

                Write-Host "  Action    : DELETE FAILED" `
                    -ForegroundColor Red

            }
            else {

                Write-Host "  Action    : WOULD DELETE" `
                    -ForegroundColor Yellow
            }


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


        # ----------------------------------------------------
        # Release this size group from memory.
        # ----------------------------------------------------

        $HashMap.Clear()
    }


    # --------------------------------------------------------
    # Release bucket from memory.
    # --------------------------------------------------------

    $Lines = $null
    $Groups = $null

    [System.GC]::Collect()
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

Write-Host "[4/4] Verifying final folder..." `
    -ForegroundColor Yellow

Write-Host ""


$FilesAfter = 0
$TotalSizeAfter = [Int64]0
$FinalScanErrors = 0

$VerifyStart = Get-Date
$LastUpdate = $VerifyStart


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
                ($Now - $VerifyStart).TotalSeconds


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
# FINAL REPORT
# ============================================================

$ActualFreed =
    $TotalSizeBefore -
    $TotalSizeAfter


$TotalTime =
    (Get-Date) -
    $StartTime


$TotalErrors =
    $ScanErrors +
    $HashErrors +
    $DeleteErrors +
    $FinalScanErrors


Write-Header "FINAL REPORT"


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

Write-Host "MODE"


if ($DryRun) {

    Write-Host "  DRY RUN - NOTHING WAS DELETED" `
        -ForegroundColor Yellow

}
else {

    Write-Host "  LIVE - DUPLICATES WERE DELETED" `
        -ForegroundColor Green
}


Write-Host ""


# ============================================================
# LOG
# ============================================================

Write-Host "LOG"


if (Test-Path -LiteralPath $LogFile) {

    Write-Host "  $LogFile" `
        -ForegroundColor Cyan

}
else {

    Write-Host "  No duplicate log was created." `
        -ForegroundColor DarkGray
}


Write-Host ""


# ============================================================
# CLEANUP
# ============================================================

Write-Host "Cleaning temporary files..." `
    -ForegroundColor DarkGray


Remove-TempFolder


# ============================================================
# COMPLETE
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
