<#
.SYNOPSIS
    Low-RAM Duplicate File Cleaner for Windows

.DESCRIPTION
    Finds true duplicate files recursively.

    Duplicate detection:
        1. Files must have the same size.
        2. Files must have the same SHA-256 hash.

    The script uses a disk-backed external merge sort.
    It does NOT use Windows sort.exe and does not keep
    the complete file list in RAM.

    Designed for very large collections, including 1TB+
    datasets and hundreds of thousands of files.

.FEATURES
    - Recursive scanning
    - Very low RAM usage
    - Disk-backed indexing
    - External merge sort
    - SHA-256 verification
    - Optional excluded folder
    - Safe dry-run mode
    - Live progress
    - Speed and ETA
    - Console duplicate report
    - CSV deletion log
    - Final verification
    - Error handling
    - Automatic temporary-file cleanup

.NOTES
    Version : 2.0.0
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
# SORT MEMORY
# ------------------------------------------------------------
# Number of index lines kept in RAM during each sort chunk.
#
# 50,000 lines keeps RAM usage low even with long file paths.

$SortChunkSize = 50000


# ------------------------------------------------------------
# LOG FILE
# ------------------------------------------------------------

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
# CREATE SORTED CHUNKS
# ============================================================

function New-SortedChunks {

    param (
        [string]$InputFile,
        [string]$OutputDirectory,
        [int]$ChunkSize
    )


    $Reader = New-Object `
        System.IO.StreamReader(
            $InputFile,
            [System.Text.Encoding]::UTF8,
            $true
        )


    $ChunkNumber = 0
    $Lines = New-Object System.Collections.Generic.List[string]


    try {

        while (($Line = $Reader.ReadLine()) -ne $null) {

            if ($Line.Length -lt 21) {
                continue
            }

            $Lines.Add($Line)


            if ($Lines.Count -ge $ChunkSize) {

                $ChunkNumber++


                $ChunkFile = Join-Path `
                    $OutputDirectory `
                    ("chunk-{0:D6}.txt" -f $ChunkNumber)


                # Sort only this small chunk in RAM.
                $Lines.Sort()


                $Writer = New-Object `
                    System.IO.StreamWriter(
                        $ChunkFile,
                        $false,
                        [System.Text.UTF8Encoding]::new($false)
                    )


                try {

                    foreach ($Item in $Lines) {
                        $Writer.WriteLine($Item)
                    }

                }
                finally {

                    $Writer.Flush()
                    $Writer.Dispose()
                }


                $Lines.Clear()
            }
        }


        # Write remaining lines.

        if ($Lines.Count -gt 0) {

            $ChunkNumber++


            $ChunkFile = Join-Path `
                $OutputDirectory `
                ("chunk-{0:D6}.txt" -f $ChunkNumber)


            $Lines.Sort()


            $Writer = New-Object `
                System.IO.StreamWriter(
                    $ChunkFile,
                    $false,
                    [System.Text.UTF8Encoding]::new($false)
                )


            try {

                foreach ($Item in $Lines) {
                    $Writer.WriteLine($Item)
                }

            }
            finally {

                $Writer.Flush()
                $Writer.Dispose()
            }


            $Lines.Clear()
        }

    }
    finally {

        $Reader.Dispose()
    }


    return $ChunkNumber
}


# ============================================================
# MERGE TWO SORTED FILES
# ============================================================

function Merge-TwoSortedFiles {

    param (
        [string]$FileA,
        [string]$FileB,
        [string]$OutputFile
    )


    $ReaderA = New-Object `
        System.IO.StreamReader(
            $FileA,
            [System.Text.Encoding]::UTF8,
            $true
        )


    $ReaderB = New-Object `
        System.IO.StreamReader(
            $FileB,
            [System.Text.Encoding]::UTF8,
            $true
        )


    $Writer = New-Object `
        System.IO.StreamWriter(
            $OutputFile,
            $false,
            [System.Text.UTF8Encoding]::new($false)
        )


    try {

        $LineA = $ReaderA.ReadLine()
        $LineB = $ReaderB.ReadLine()


        while (
            $null -ne $LineA -or
            $null -ne $LineB
        ) {

            if ($null -eq $LineA) {

                $Writer.WriteLine($LineB)
                $LineB = $ReaderB.ReadLine()

            }
            elseif ($null -eq $LineB) {

                $Writer.WriteLine($LineA)
                $LineA = $ReaderA.ReadLine()

            }
            elseif ([string]::CompareOrdinal($LineA, $LineB) -le 0) {

                $Writer.WriteLine($LineA)
                $LineA = $ReaderA.ReadLine()

            }
            else {

                $Writer.WriteLine($LineB)
                $LineB = $ReaderB.ReadLine()
            }
        }

    }
    finally {

        $Writer.Flush()
        $Writer.Dispose()

        $ReaderA.Dispose()
        $ReaderB.Dispose()
    }
}


# ============================================================
# MERGE ALL SORTED CHUNKS
# ============================================================

function Merge-AllSortedChunks {

    param (
        [string]$ChunkDirectory,
        [string]$FinalOutput
    )


    $Files = @(
        Get-ChildItem `
            -LiteralPath $ChunkDirectory `
            -Filter "chunk-*.txt" `
            -File `
            -ErrorAction SilentlyContinue |
        Sort-Object Name
    )


    if ($Files.Count -eq 0) {
        return $false
    }


    $Round = 0


    while ($Files.Count -gt 1) {

        $Round++

        $NextFiles = New-Object System.Collections.Generic.List[string]


        for (
            $i = 0;
            $i -lt $Files.Count;
            $i += 2
        ) {

            $FileA = $Files[$i].FullName


            # If there is no pair, carry the file forward.

            if (($i + 1) -ge $Files.Count) {

                $NextFiles.Add($FileA)
                continue
            }


            $FileB = $Files[$i + 1].FullName


            $MergedFile = Join-Path `
                $ChunkDirectory `
                ("merge-{0:D4}-{1:D6}.txt" -f $Round, ($i / 2))


            Merge-TwoSortedFiles `
                -FileA $FileA `
                -FileB $FileB `
                -OutputFile $MergedFile


            Remove-Item `
                -LiteralPath $FileA `
                -Force `
                -ErrorAction SilentlyContinue

            Remove-Item `
                -LiteralPath $FileB `
                -Force `
                -ErrorAction SilentlyContinue


            $NextFiles.Add($MergedFile)
        }


        $Files = @(
            $NextFiles |
            ForEach-Object {
                Get-Item `
                    -LiteralPath $_ `
                    -ErrorAction SilentlyContinue
            }
        )
    }


    Move-Item `
        -LiteralPath $Files[0].FullName `
        -Destination $FinalOutput `
        -Force


    return $true
}


# ============================================================
# CLEANUP FUNCTION
# ============================================================

function Remove-TemporaryFiles {

    if (
        Test-Path `
            -LiteralPath $TempDirectory `
            -PathType Container
    ) {

        try {

            Get-ChildItem `
                -LiteralPath $TempDirectory `
                -Force `
                -ErrorAction SilentlyContinue |
            Remove-Item `
                -Force `
                -Recurse `
                -ErrorAction SilentlyContinue

        }
        catch {
            # Cleanup failure is non-fatal.
        }


        try {

            Remove-Item `
                -LiteralPath $TempDirectory `
                -Force `
                -ErrorAction SilentlyContinue

        }
        catch {
            # Cleanup failure is non-fatal.
        }
    }
}


# ============================================================
# VALIDATION
# ============================================================

if ([string]::IsNullOrWhiteSpace($Folder)) {

    Write-Host ""
    Write-Host "ERROR: Please set the `$Folder variable first." `
        -ForegroundColor Red

    Write-Host ""
    Write-Host 'Example:' `
        -ForegroundColor Yellow

    Write-Host '$Folder = "D:\MyFiles"' `
        -ForegroundColor Yellow

    Write-Host ""

    Read-Host "Press ENTER to exit"
    exit 1
}


if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {

    Write-Host ""
    Write-Host "ERROR: Main folder does not exist." `
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
    Write-Host "ERROR: Could not resolve main folder." `
        -ForegroundColor Red

    Read-Host "Press ENTER to exit"
    exit 1
}


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

$RawIndexFile = Join-Path `
    $RunDirectory `
    "index.txt"

$SortedIndexFile = Join-Path `
    $RunDirectory `
    "sorted-index.txt"

$ChunkDirectory = Join-Path `
    $RunDirectory `
    "chunks"


try {

    New-Item `
        -ItemType Directory `
        -Path $ChunkDirectory `
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

$ScriptStart = Get-Date


Write-Section "DUPLICATE FILE CLEANER"


Write-Host "Main folder : $Folder"


if ([string]::IsNullOrWhiteSpace($ExcludeFolder)) {

    Write-Host "Excluded    : NONE" `
        -ForegroundColor DarkGray

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


$Writer = $null


try {

    $Writer = New-Object `
        System.IO.StreamWriter(
            $RawIndexFile,
            $false,
            [System.Text.UTF8Encoding]::new($false)
        )


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


        # 20-digit fixed-width size + TAB + path

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

    Write-Host $_.Exception.Message `
        -ForegroundColor Yellow

}
finally {

    if ($null -ne $Writer) {

        $Writer.Flush()
        $Writer.Dispose()
    }
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
# EXTERNAL MERGE SORT
# ============================================================

Write-Host "[2/4] Sorting size index..." `
    -ForegroundColor Yellow

Write-Host "      Using disk-backed external merge sort." `
    -ForegroundColor DarkGray

Write-Host "      RAM chunk size: $SortChunkSize files" `
    -ForegroundColor DarkGray

Write-Host ""


$SortStart = Get-Date


try {

    # --------------------------------------------------------
    # Create individually sorted chunks
    # --------------------------------------------------------

    Write-Host "      Creating sorted chunks..." `
        -ForegroundColor DarkGray


    $ChunkCount = New-SortedChunks `
        -InputFile $RawIndexFile `
        -OutputDirectory $ChunkDirectory `
        -ChunkSize $SortChunkSize


    if ($ChunkCount -eq 0) {

        Write-Host ""
        Write-Host "No files were indexed." `
            -ForegroundColor Yellow

        Remove-TemporaryFiles

        Read-Host "Press ENTER to exit"
        exit 0
    }


    Write-Host "      Created $ChunkCount sorted chunk(s)." `
        -ForegroundColor DarkGray


    # --------------------------------------------------------
    # Merge chunks
    # --------------------------------------------------------

    Write-Host "      Merging sorted chunks..." `
        -ForegroundColor DarkGray


    $MergeSuccess = Merge-AllSortedChunks `
        -ChunkDirectory $ChunkDirectory `
        -FinalOutput $SortedIndexFile


    if (-not $MergeSuccess) {

        throw "The sorted index could not be created."
    }


    # --------------------------------------------------------
    # Verify output
    # --------------------------------------------------------

    if (
        -not (
            Test-Path `
                -LiteralPath $SortedIndexFile `
                -PathType Leaf
        )
    ) {

        throw "The sorted index file was not created."
    }


    $SortTime =
        (Get-Date) - $SortStart


    Write-Host ""
    Write-Host "Sort complete." `
        -ForegroundColor Green

    Write-Host "Sort time: $([math]::Round($SortTime.TotalMinutes, 1)) minutes"

    Write-Host ""


}
catch {

    Write-Host ""
    Write-Host "ERROR: Sorting the index failed." `
        -ForegroundColor Red

    Write-Host ""
    Write-Host "Reason:" `
        -ForegroundColor Yellow

    Write-Host $_.Exception.Message `
        -ForegroundColor Red

    Write-Host ""

    Remove-TemporaryFiles

    Read-Host "Press ENTER to exit"
    exit 1
}


# Raw index is no longer needed.

Remove-Item `
    -LiteralPath $RawIndexFile `
    -Force `
    -ErrorAction SilentlyContinue


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


        if ($null -eq $PreviousSize) {

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
# Second pass:
# SHA-256 comparison
# ------------------------------------------------------------

if ($CandidateFiles -eq 0) {

    Write-Host "No same-size candidate files were found." `
        -ForegroundColor Green

}
else {

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
                $null -ne $CurrentSize -and
                $FileSize -ne $CurrentSize
            ) {

                $HashMap.Clear()
            }


            $CurrentSize = $FileSize


            # ------------------------------------------------
            # Progress
            # ------------------------------------------------

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
            # Console duplicate report
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
