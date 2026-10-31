#
# NameEdit restore - undo a recent rename.
#
#   powershell -ExecutionPolicy Bypass -File restore.ps1 [-Index <n>]
#
# Lists the batches recorded by ne.ps1, newest first, and renames the entries
# of the chosen batch back to their original names. Entries whose renamed file
# is gone, or whose original name is taken, are skipped so the rest still
# completes. A completed restore is recorded as a batch of its own, so it can
# be walked back the same way.
#

[CmdletBinding()]
param(
    # Restores this entry without asking; 0 asks.
    [int]$Index = 0
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

# Scripts live in src/, the history folder lives in the project root and is
# shared with ne.ps1.
$Root = Split-Path -Parent $PSScriptRoot
$IniPath = Join-Path $Root 'ne.ini'
$HistoryDir = Join-Path $Root 'history'

$HistoryLimit = Read-HistoryLimit $IniPath

# Written by ne.ps1 while a batch is being renamed and removed once that
# batch is finished.
$PendingPath = Join-Path $HistoryDir 'pending.txt'

# ---------------------------------------------------------------- history

function Read-HistoryFile {
    param([string]$FilePath)

    try {
        $lines = (Read-TextFile $FilePath) -split "`r?`n"
    }
    catch {
        return $null
    }

    $entry = @{
        Path  = $FilePath
        Time  = ''
        Mode  = ''
        Steps = [System.Collections.Generic.List[object]]::new()
    }

    $inBody = $false
    foreach ($line in $lines) {
        if (-not $inBody) {
            if ($line -eq '---') {
                $inBody = $true
                continue
            }

            $eq = $line.IndexOf('=')
            if ($eq -lt 1) { continue }

            $key = $line.Substring(0, $eq)
            $value = $line.Substring($eq + 1)
            if ($key -eq 'time') { $entry.Time = $value }
            elseif ($key -eq 'mode') { $entry.Mode = $value }
            continue
        }

        if ($line -eq '') { continue }

        $tab = $line.IndexOf("`t")
        if ($tab -lt 1) { continue }

        [void]$entry.Steps.Add([pscustomobject]@{
            From = $line.Substring(0, $tab)
            To   = $line.Substring($tab + 1)
        })
    }

    if ($entry.Steps.Count -eq 0) { return $null }
    return $entry
}

function Get-HistoryEntries {
    if (-not [IO.Directory]::Exists($HistoryDir)) { return }

    $files = @(Get-ChildItem -LiteralPath $HistoryDir -Filter '*.txt' -File |
        Sort-Object -Property Name -Descending)

    foreach ($file in $files) {
        $entry = Read-HistoryFile $file.FullName
        if ($null -ne $entry) { $entry }
    }
}

# A batch cut short in the middle of renaming. Each line holds the temporary
# name, the original name and the intended name; the file sits under the
# temporary name unless the second phase already reached it.
function Read-PendingFile {
    param([string]$FilePath)

    if (-not (Test-FsItem $FilePath)) { return $null }

    try {
        $lines = (Read-TextFile $FilePath) -split "`r?`n"
    }
    catch {
        return $null
    }

    $entry = @{
        Path  = $FilePath
        Time  = ''
        Mode  = 'pending'
        Steps = [System.Collections.Generic.List[object]]::new()
    }

    foreach ($line in $lines) {
        $parts = $line.Split("`t")
        if ($parts.Count -ne 3) { continue }

        $current = if (Test-FsItem $parts[0]) { $parts[0] } else { $parts[2] }
        if (-not (Test-FsItem $current)) { continue }

        [void]$entry.Steps.Add([pscustomobject]@{ From = $parts[1]; To = $current })
    }

    if ($entry.Steps.Count -eq 0) { return $null }

    try {
        $entry.Time = (Get-Item -LiteralPath $FilePath).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
    catch {
        $entry.Time = ''
    }

    return $entry
}

# ------------------------------------------------------------ file system

function Test-FsItem {
    param([string]$Path)
    return ([IO.File]::Exists($Path) -or [IO.Directory]::Exists($Path))
}

# ------------------------------------------------------------------ input

$entries = @()
$pending = Read-PendingFile $PendingPath
if ($null -ne $pending) { $entries += $pending }
$entries += @(Get-HistoryEntries)

Write-Host 'NameEdit restore'
Write-Host ''

if ($entries.Count -eq 0) {
    Write-Host ('No rename history found in ' + $HistoryDir)
    exit 0
}

for ($i = 0; $i -lt $entries.Count; $i++) {
    $entry = $entries[$i]
    $number = $i + 1

    Write-Host ('  ' + $number + '. ' + $entry.Time + '  ' + $entry.Mode.PadRight(9) + $entry.Steps.Count + ' item(s)')
    if ($entry.Mode -eq 'pending') {
        Write-Host '       (interrupted rename; restoring puts the files back to their old names)'
    }

    # A short preview helps pick the batch without dumping every path.
    $shown = [Math]::Min($entry.Steps.Count, 3)
    for ($j = 0; $j -lt $shown; $j++) {
        $step = $entry.Steps[$j]
        Write-Host ('       ' + [IO.Path]::GetFileName($step.To) + '  ->  ' + [IO.Path]::GetFileName($step.From))
    }
    if ($entry.Steps.Count -gt $shown) {
        Write-Host ('       ... and ' + ($entry.Steps.Count - $shown) + ' more')
    }
}

$selection = 0
if ($Index -gt 0) {
    $selection = $Index
}
else {
    Write-Host ''
    $answer = Read-Host 'Batch to restore (empty quits)'
    $answer = $answer.Trim()
    if ($answer -eq '') { exit 0 }

    if (-not [int]::TryParse($answer, [ref]$selection)) { $selection = 0 }
}

if ($selection -lt 1 -or $selection -gt $entries.Count) {
    Write-Host 'Invalid selection.' -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------- restore

$entry = $entries[$selection - 1]

$restored = 0
$missing = 0
$conflicts = 0
$failed = [System.Collections.Generic.List[string]]::new()
$staged = [System.Collections.Generic.List[object]]::new()
$undone = [System.Collections.Generic.List[object]]::new()

# Stage every item under a temporary name first, so a batch that swaps two
# names does not block itself while walking back.
foreach ($step in $entry.Steps) {
    if (-not (Test-FsItem $step.To)) {
        $missing++
        continue
    }

    $targetDir = [IO.Path]::GetDirectoryName($step.From)
    if ([string]::IsNullOrEmpty($targetDir) -or -not [IO.Directory]::Exists($targetDir)) {
        $conflicts++
        continue
    }

    $isDir = [IO.Directory]::Exists($step.To)
    $temp = [IO.Path]::Combine([IO.Path]::GetDirectoryName($step.To),
        '.~ne-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')

    try {
        Move-FsItem $step.To $temp $isDir
        [void]$staged.Add([pscustomobject]@{ Step = $step; Temp = $temp; IsDir = $isDir })
    }
    catch {
        [void]$failed.Add($step.To + ' : ' + $_.Exception.Message)
    }
}

foreach ($item in $staged) {
    $step = $item.Step

    if (Test-FsItem $step.From) {
        # Something else holds the original name; put the item back where it
        # was and leave the batch entry alone.
        try { Move-FsItem $item.Temp $step.To $item.IsDir } catch { }
        $conflicts++
        continue
    }

    try {
        Move-FsItem $item.Temp $step.From $item.IsDir
        $restored++
        # The batch is recorded the same way as a rename: the name before it
        # and the name after it. Walking it back therefore redoes this one.
        [void]$undone.Add([pscustomobject]@{ From = $step.To; To = $step.From })
    }
    catch {
        try { Move-FsItem $item.Temp $step.To $item.IsDir } catch { }
        [void]$failed.Add($step.To + ' : ' + $_.Exception.Message)
    }
}

# The batch no longer reflects the disk once it has been walked back, but
# anything left alone may still need the record.
$leftAlone = $missing + $conflicts + $failed.Count
if ($leftAlone -eq 0) {
    try { Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop } catch { }
}

# The restore itself becomes a batch: walking it back puts the new names in
# place again.
if ($undone.Count -gt 0) {
    [void](Add-HistoryEntry -HistoryDir $HistoryDir -Limit $HistoryLimit -Steps $undone -Mode 'restore')
}

# ----------------------------------------------------------------- report

Write-Host ''
Write-Host ("Restored $restored / Skipped $($missing + $conflicts) / Failed $($failed.Count)")

if ($missing -gt 0) {
    Write-Host ('  ' + $missing + ' renamed item(s) no longer exist, left alone.')
}
if ($conflicts -gt 0) {
    Write-Host ('  ' + $conflicts + ' original name(s) are taken or their folder is missing, left alone.')
}
foreach ($message in $failed) {
    Write-Host ('  ' + $message) -ForegroundColor Yellow
}

Write-Host ''
if ($leftAlone -eq 0) {
    Write-Host 'The restored batch was removed from the history.'
}
else {
    Write-Host ('The record was kept at ' + $entry.Path + ' because some entries were left alone.') -ForegroundColor Yellow
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
