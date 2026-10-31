#
# NameEdit - rename files and folders in bulk with a text editor. Invoked
# from a "Send to" shortcut:
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ne.ps1 `
#       -Mode <noExt|withExt|fullPath> <paths...>
#

[CmdletBinding()]
param(
    [ValidateSet('noExt', 'withExt', 'fullPath')]
    [string]$Mode = 'noExt',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Paths,

    [switch]$KeepTemp,

    [switch]$Pause
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

# Entries opened from the "Send to" menu run in a console window that closes
# as soon as this script exits; -Pause keeps it open on the outcomes the user
# needs to read. Read-Host would append a colon to the prompt, so the line is
# written and read directly.
function Read-Close {
    if (-not $Pause) { return }
    Write-Host 'Press Enter to close.' -NoNewline
    [void][Console]::ReadLine()
}

# Scripts live in src/, the configuration and the entry points live in the
# project root one level up.
$Root = Split-Path -Parent $PSScriptRoot
$IniPath = Join-Path $Root 'ne.ini'

$Version = Read-Version $Root

# Successful batches are recorded in the project folder, next to the
# configuration; restore.ps1 reads the same folder. How many are kept comes
# from ne.ini and defaults to 5.
$HistoryDir = Join-Path $Root 'history'

# While a batch is being renamed its old-to-new mapping is kept here, so a run
# cut short can be undone by restore.ps1.
$PendingPath = Join-Path $HistoryDir 'pending.txt'

$InvalidChars = [IO.Path]::GetInvalidFileNameChars()

# A full path stops at MAX_PATH unless the system enables long paths, in
# which case the file system itself accepts up to 32767 characters.
$PathLimit = 259
try {
    $longPaths = Get-ItemPropertyValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'LongPathsEnabled' -ErrorAction Stop
    if ($longPaths -eq 1) { $PathLimit = 32767 }
}
catch {
    # Key missing or unreadable: keep the conservative limit.
}

# ----------------------------------------------------------------- config

# ne.ps1 only needs the editor command; the Send to section is read by
# install.ps1 and has no meaning here.
function Get-Configuration {
    $config = @{
        Editor       = 'notepad.exe {file}'
        HistoryLimit = 5
    }

    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) {
        return $config
    }

    $section = ''
    foreach ($line in ((Read-TextFile $IniPath) -split "`r?`n")) {
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith(';') -or $text.StartsWith('#')) { continue }

        if ($text -match '^\[(.*)\]$') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            continue
        }

        $eq = $text.IndexOf('=')
        if ($eq -lt 1) { continue }

        $key = $text.Substring(0, $eq).Trim().ToUpperInvariant()
        $value = $text.Substring($eq + 1).Trim()

        switch ($section) {
            'editor' {
                if ($key -eq 'COMMAND' -and $value -ne '') { $config.Editor = $value }
            }
            'history' {
                # Zero turns the recording off.
                if ($key -eq 'LIMIT') {
                    $limit = 0
                    if ([int]::TryParse($value, [ref]$limit) -and $limit -ge 0) {
                        $config.HistoryLimit = $limit
                    }
                }
            }
        }
    }

    return $config
}

# ------------------------------------------------------------------ input

if ($null -eq $Paths -or $Paths.Count -eq 0) {
    Write-Host 'No files were selected.'
    Write-Host 'Select them in Explorer first, then pick an entry from Send to.'
    Write-Host 'Usage: ne.ps1 -Mode <noExt|withExt|fullPath> <paths...>'
    Read-Close
    exit 1
}

$config = Get-Configuration

# An unfinished run leaves its files under temporary names; the record stays
# until that batch is rolled back.
if (Test-Path -LiteralPath $PendingPath -PathType Leaf) {
    Write-Host 'A previous rename was interrupted. Its temporary names are recorded in:' -ForegroundColor Yellow
    Write-Host ('  ' + $PendingPath)
    Write-Host 'Run restore.cmd to undo it.' -ForegroundColor Yellow
    Write-Host ''
}

$items = [System.Collections.Generic.List[object]]::new()
$missing = [System.Collections.Generic.List[object]]::new()
$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

foreach ($raw in $Paths) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }

    $full = $raw
    try {
        if (-not [IO.Path]::IsPathRooted($full)) {
            $full = Join-Path (Get-Location).ProviderPath $full
        }
        $full = [IO.Path]::GetFullPath($full)
    }
    catch {
        [void]$missing.Add([pscustomobject]@{ Raw = $raw; Full = ''; Reason = $_.Exception.Message })
        continue
    }

    # A trailing separator leaves GetFileName with an empty leaf, which turns
    # into a list line the user cannot fix. Keep it on drive roots only.
    if ($full.Length -gt 1 -and ($full.EndsWith('\') -or $full.EndsWith('/'))) {
        $full = $full.TrimEnd([char[]]('\', '/'))
        if ($full -match '^[A-Za-z]:$') { $full += '\' }
    }

    $isDir = [IO.Directory]::Exists($full)
    $isFile = [IO.File]::Exists($full)
    if (-not $isDir -and -not $isFile) {
        [void]$missing.Add([pscustomobject]@{ Raw = $raw; Full = $full; Reason = 'Not found' })
        continue
    }

    # The same path twice would make the second rename fail and roll back the
    # whole batch.
    if (-not $seen.Add($full)) { continue }

    $leaf = [IO.Path]::GetFileName($full)
    $ext = ''
    $base = $leaf

    if (-not $isDir) {
        $ext = [IO.Path]::GetExtension($full)
        $base = [IO.Path]::GetFileNameWithoutExtension($full)
        # Dot files such as ".gitignore" have no extension to keep.
        if ($base -eq '') {
            $base = $leaf
            $ext = ''
        }
    }

    [void]$items.Add([pscustomobject]@{
        FullPath = $full
        IsDir    = $isDir
        Dir      = [IO.Path]::GetDirectoryName($full)
        Leaf     = $leaf
        Base     = $base
        Ext      = $ext
    })
}

if ($items.Count -eq 0) {
    Write-Host 'Nothing to rename.'
    foreach ($entry in $missing) {
        Write-Host ('  ' + $entry.Reason + ': [' + $entry.Raw + ']')
        if ($entry.Full -ne '' -and $entry.Full -cne $entry.Raw) {
            Write-Host ('    resolved to: [' + $entry.Full + ']')
        }
    }
    Read-Close
    exit 1
}

# --------------------------------------------------------------- ordering

# The order passed by "Send to" starts at the item that was right-clicked and
# wraps around, which is not the order shown in Explorer. Sort by name, with
# digit runs compared as numbers so that 2 comes before 10.
function Get-SortedItems {
    param($Items)

    if ($Items.Count -le 1) { return $Items }

    $pad = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        $match.Value.PadLeft(10, '0')
    }

    $entries = foreach ($item in $Items) {
        [pscustomobject]@{
            Item  = $item
            # Folders come first, the way Explorer groups them.
            Group = if ($item.IsDir) { 0 } else { 1 }
            # Digit runs compared as numbers, so 2 sorts before 10.
            Name  = [regex]::Replace($item.Leaf, '\d+', $pad)
            # Only used to break ties such as 01 against 1.
            Raw   = $item.Leaf
        }
    }

    return @($entries | Sort-Object -Property Group, Name, Raw | ForEach-Object { $_.Item })
}

$items = @(Get-SortedItems $items)

# The console window stays open while the editor runs; fill it with what the
# batch is about instead of leaving it blank.
Write-Host ''
if ($Version) {
    Write-Host ('NameEdit ' + $Version)
    Write-Host ''
}
Write-Host ('  Mode    ' + $Mode)
Write-Host ('  Items   ' + $items.Count)
Write-Host ('  Editor  ' + $config.Editor.Replace('{file}', '').Trim())
Write-Host ''
Write-Host '  Edit the names, save and close the editor to apply.'
Write-Host ''

# --------------------------------------------------------------- list file

$tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
$tempDir = Join-Path $env:TEMP ('NameEdit\' + $tag)
[void][IO.Directory]::CreateDirectory($tempDir)
$listPath = Join-Path $tempDir 'names.txt'

$initialLines = @(foreach ($item in $items) {
    switch ($Mode) {
        'noExt' { $item.Base }
        'withExt' { $item.Leaf }
        default { $item.FullPath }
    }
})

$original = ($initialLines -join "`r`n") + "`r`n"
Write-TextFile $listPath $original

# Every way out of this script removes the temp folder; -KeepTemp keeps it for
# inspection.
function Remove-TempDir {
    if ($KeepTemp) { return }
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- validate

function Test-List {
    param($Items, $Lines)

    $problems = [System.Collections.Generic.List[object]]::new()

    if ($Lines.Count -ne $Items.Count) {
        [void]$problems.Add("Expected $($Items.Count) lines, found $($Lines.Count).")
        [void]$problems.Add('Keep the line of an entry unchanged to skip it; do not delete lines.')
        return @{ Problems = $problems; Targets = @() }
    }

    # A folder and something inside it cannot be renamed in one batch.
    foreach ($folder in $Items) {
        if (-not $folder.IsDir) { continue }
        foreach ($other in $Items) {
            if ($other.FullPath -eq $folder.FullPath) { continue }
            if ($other.FullPath.StartsWith($folder.FullPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
                [void]$problems.Add('Both "' + $folder.FullPath + '" and "' + $other.FullPath +
                    '" are selected; renaming the folder would invalidate the other path.')
            }
        }
    }

    $sources = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Items) { [void]$sources.Add($item.FullPath) }

    $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $results = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        $no = $i + 1
        $item = $Items[$i]

        if ($line -eq '') {
            [void]$problems.Add("Line $no is empty.")
            continue
        }

        # The list may have been open for a while; the source can be gone by
        # the time it is saved.
        if (-not ([IO.File]::Exists($item.FullPath) -or [IO.Directory]::Exists($item.FullPath))) {
            [void]$problems.Add("Line $no : the source no longer exists: $($item.FullPath)")
            continue
        }

        if ($Mode -eq 'fullPath') {
            if (-not [IO.Path]::IsPathRooted($line)) {
                [void]$problems.Add("Line $no is not a full path.")
                continue
            }

            # Normalised, so that "a\..\b" and "b" count as one target in
            # the duplicate and existence checks below.
            try {
                $target = [IO.Path]::GetFullPath($line)
            }
            catch [IO.PathTooLongException] {
                [void]$problems.Add("Line $no : name is too long.")
                continue
            }
            catch {
                [void]$problems.Add("Line $no : invalid path `"$line`".")
                continue
            }
        }
        else {
            # Only the full path mode may move a file to another folder.
            if ($line.IndexOf('\') -ge 0 -or $line.IndexOf('/') -ge 0) {
                [void]$problems.Add("Line $no : a name cannot contain a path separator.")
                continue
            }
            if ($Mode -eq 'noExt') {
                $target = [IO.Path]::Combine($item.Dir, $line + $item.Ext)
            }
            else {
                $target = [IO.Path]::Combine($item.Dir, $line)
            }
        }

        if ($target.EndsWith('\') -or $target.EndsWith('/')) {
            [void]$problems.Add("Line $no : a path cannot end with a separator.")
            continue
        }

        $leaf = [IO.Path]::GetFileName($target)

        if ($leaf.IndexOfAny($InvalidChars) -ge 0) {
            [void]$problems.Add("Line $no : invalid character in `"$line`".")
            continue
        }

        if ($leaf.EndsWith(' ') -or $leaf.EndsWith('.')) {
            [void]$problems.Add("Line $no : name cannot end with a space or a dot.")
            continue
        }

        $stem = [IO.Path]::GetFileNameWithoutExtension($leaf)
        if ($ReservedNames -contains $stem.ToUpperInvariant()) {
            [void]$problems.Add("Line $no : `"$leaf`" is a reserved name.")
            continue
        }

        if ($leaf.Length -gt 255 -or $target.Length -gt $PathLimit) {
            [void]$problems.Add("Line $no : name is too long.")
            continue
        }

        $parent = [IO.Path]::GetDirectoryName($target)
        if ([string]::IsNullOrEmpty($parent)) {
            [void]$problems.Add("Line $no : invalid path `"$line`".")
            continue
        }
        if (-not [IO.Directory]::Exists($parent)) {
            [void]$problems.Add("Line $no : folder does not exist: $parent")
            continue
        }

        if (-not $targets.Add($target)) {
            [void]$problems.Add("Line $no : duplicate name.")
            continue
        }

        if (([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) -and
            -not $sources.Contains($target)) {
            [void]$problems.Add("Line $no : target already exists.")
            continue
        }

        [void]$results.Add([pscustomobject]@{ Index = $i; Target = $target })
    }

    return @{ Problems = $problems; Targets = $results }
}

# ------------------------------------------------------------ edit and run

function Open-Editor {
    # The configured command may be a batch file itself (code.cmd) or contain
    # quoted paths, so run it through a small batch wrapper instead of trying
    # to quote it for cmd directly.
    # The placeholder is quoted unless the command already quotes it.
    $editor = $config.Editor

    # Without the placeholder the editor opens on its own and every save
    # looks like "no changes".
    if (-not $editor.Contains('{file}')) {
        Write-Host ''
        Write-Host ('The editor command has no {file} placeholder. Check ' + $IniPath + '.') -ForegroundColor Red
        Write-Host ('The list file is kept at ' + $listPath)
        Read-Close
        exit 1
    }

    if ($editor.Contains('"{file}"') -or $editor.Contains("'{file}'")) {
        $command = $editor.Replace('{file}', $listPath)
    }
    else {
        $command = $editor.Replace('{file}', '"' + $listPath + '"')
    }

    $wrapper = Join-Path $tempDir 'run-editor.cmd'
    $body = "@echo off`r`n" + $command + "`r`n"
    $bytes = [Text.Encoding]::Default.GetBytes($body)

    # cmd reads the wrapper in the current code page; characters it cannot
    # represent would reach the editor as question marks.
    if ([Text.Encoding]::Default.GetString($bytes) -ne $body) {
        Write-Host ''
        Write-Host 'The command or the list path contains characters this code page cannot write.' -ForegroundColor Red
        Write-Host ('The list file is kept at ' + $listPath)
        Read-Close
        exit 1
    }

    [IO.File]::WriteAllBytes($wrapper, $bytes)

    try {
        $process = Start-Process -FilePath $wrapper -Wait -NoNewWindow -PassThru -ErrorAction Stop
    }
    catch {
        Write-Host ''
        Write-Host ('Failed to launch the editor: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Check the command line in ' + $IniPath + '.')
        Write-Host ('The list file is kept at ' + $listPath)
        Read-Close
        exit 1
    }

    return $process.ExitCode
}

# Compare and parse with a single line ending, so an editor that saves the
# list with another line ending is not mistaken for an edit.
function ConvertTo-Lf {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

$last = ConvertTo-Lf $original
$approved = $null

while ($true) {
    $editorCode = Open-Editor

    $current = ConvertTo-Lf (Read-TextFile $listPath)

    if ($current -ceq $last) {
        Write-Host 'No changes, nothing was renamed.'
        # Exit codes other than 0 usually mean the command never reached the
        # editor, which is the one case worth stopping for.
        if ($editorCode -ne 0) {
            Write-Host ('The editor command exited with code ' + $editorCode + '. Check the command line in ' + $IniPath + '.') -ForegroundColor Yellow
            Read-Close
        }
        Remove-TempDir
        exit 0
    }

    $lines = @()
    if ($current -ne '') {
        $normalized = $current.TrimEnd("`n")
        if ($normalized -ne '') { $lines = $normalized.Split("`n") }
    }

    if ($lines.Count -eq 0) {
        Write-Host 'Cancelled.'
        Remove-TempDir
        exit 0
    }

    $check = Test-List $items $lines
    if ($check.Problems.Count -eq 0) {
        $approved = $check.Targets
        break
    }

    Write-Host ''
    Write-Host 'Nothing was renamed.' -ForegroundColor Yellow
    Write-Host ''

    $shown = [Math]::Min($check.Problems.Count, 20)
    for ($i = 0; $i -lt $shown; $i++) {
        Write-Host ('  ' + $check.Problems[$i]) -ForegroundColor Yellow
    }
    if ($check.Problems.Count -gt 20) {
        Write-Host ('  ... and ' + ($check.Problems.Count - 20) + ' more') -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Reopening the list. Fix the lines above, then save and close.'

    $last = $current
}

# ----------------------------------------------------------------- pending

# The temporary-name mapping is written before the first rename and removed
# once the batch has completed or been rolled back in full. It is kept when a
# rollback itself fails, because the files are still under those names.
function Write-Pending {
    param($Steps)

    try {
        [void][IO.Directory]::CreateDirectory($HistoryDir)
        $lines = @(foreach ($step in $Steps) {
            $step.Temp + "`t" + $step.From + "`t" + $step.To
        })
        Write-TextFile $PendingPath (($lines -join "`r`n") + "`r`n")
    }
    catch {
        Write-Host ('Could not record the rename in progress: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host 'An interruption now would leave the files under temporary names.'
    }
}

function Remove-Pending {
    Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------ rename

$plan = [System.Collections.Generic.List[object]]::new()
foreach ($result in $approved) {
    $item = $items[$result.Index]
    if ($result.Target -cne $item.FullPath) {
        $temp = [IO.Path]::Combine($item.Dir, '.~ne-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.tmp')
        [void]$plan.Add([pscustomobject]@{
            From = $item.FullPath
            Temp = $temp
            To   = $result.Target
            Dir  = $item.IsDir
        })
    }
}

$renamed = 0
$undo = [System.Collections.Generic.List[object]]::new()

if ($plan.Count -gt 0) {
    # A record left over from an unfinished run must not be overwritten; it
    # is the only way back for those files.
    if (Test-Path -LiteralPath $PendingPath -PathType Leaf) {
        Write-Host ''
        Write-Host 'An earlier rename is still unfinished, so nothing was renamed.' -ForegroundColor Red
        Write-Host ('Run restore.cmd first. The record is kept at ' + $PendingPath)
        Remove-TempDir
        Read-Close
        exit 1
    }
    Write-Pending $plan
}

try {
    foreach ($step in $plan) {
        Move-FsItem $step.From $step.Temp $step.Dir
        [void]$undo.Add([pscustomobject]@{ From = $step.Temp; To = $step.From; Dir = $step.Dir })
    }
    foreach ($step in $plan) {
        Move-FsItem $step.Temp $step.To $step.Dir
        [void]$undo.Add([pscustomobject]@{ From = $step.To; To = $step.Temp; Dir = $step.Dir })
        $renamed++
    }
}
catch {
    $message = $_.Exception.Message

    $stuck = [System.Collections.Generic.List[object]]::new()
    for ($i = $undo.Count - 1; $i -ge 0; $i--) {
        try {
            Move-FsItem $undo[$i].From $undo[$i].To $undo[$i].Dir
        }
        catch {
            [void]$stuck.Add($undo[$i])
        }
    }

    Write-Host ''
    Write-Host ('Rename failed: ' + $message) -ForegroundColor Red

    if ($stuck.Count -eq 0) {
        Write-Host 'All completed changes were rolled back.'
        if ($plan.Count -gt 0) { Remove-Pending }
    }
    else {
        Write-Host ('Rollback failed for ' + $stuck.Count + ' entries, which were left in place:') -ForegroundColor Yellow
        foreach ($entry in $stuck) {
            Write-Host ('  ' + $entry.From) -ForegroundColor Yellow
        }
        Write-Host ('The temporary names are recorded in ' + $PendingPath + '; run restore.cmd to undo the rest.') -ForegroundColor Yellow
    }

    Remove-TempDir
    Read-Close
    exit 1
}

if ($plan.Count -gt 0) { Remove-Pending }

Write-Host ''
Write-Host ("Renamed $renamed / Skipped $($items.Count - $plan.Count) / Failed 0")

Add-HistoryEntry -HistoryDir $HistoryDir -Limit $config.HistoryLimit -Steps $plan -Mode $Mode

Remove-TempDir
