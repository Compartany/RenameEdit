#
# NameEdit shared helpers. Dot-sourced by ne.ps1, install.ps1 and restore.ps1
# so that the file reading, the reserved-name list and the cross-volume move
# live in one place.
#

# --------------------------------------------------------------- file text

function Read-TextFile {
    param([string]$FilePath)

    $bytes = [IO.File]::ReadAllBytes($FilePath)

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        return [Text.Encoding]::Default.GetString($bytes)
    }
}

function Write-TextFile {
    param([string]$FilePath, [string]$Text)
    [IO.File]::WriteAllText($FilePath, $Text, [Text.UTF8Encoding]::new($true))
}

# ------------------------------------------------------------ file system

# Move-Item cannot move a directory to another volume, so such moves are done
# as a copy followed by a delete. If the source cannot be removed, the copy is
# dropped again, so the caller never sees both halves side by side.
function Move-FsItem {
    param([string]$From, [string]$To, [bool]$Directory)

    if ($Directory) {
        $fromRoot = [IO.Path]::GetPathRoot($From)
        $toRoot = [IO.Path]::GetPathRoot($To)
        if (-not [string]::Equals($fromRoot, $toRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $From -Destination $To -Recurse -Force

            try {
                Remove-Item -LiteralPath $From -Recurse -Force -ErrorAction Stop
            }
            catch {
                $sourceError = $_.Exception.Message
                try {
                    Remove-Item -LiteralPath $To -Recurse -Force -ErrorAction Stop
                }
                catch {
                    throw ('Copied to "' + $To + '" but could not remove "' + $From +
                        '"; delete one of them by hand. Original error: ' + $sourceError)
                }
                throw $sourceError
            }

            return
        }
    }

    Move-Item -LiteralPath $From -Destination $To
}

# Names Windows refuses to create a file with.
$ReservedNames = @('CON', 'PRN', 'AUX', 'NUL')
for ($n = 1; $n -le 9; $n++) {
    $ReservedNames += "COM$n"
    $ReservedNames += "LPT$n"
}

# ---------------------------------------------------------------- history

# ne.ini [History] Limit: how many batches the history folder keeps. Zero
# turns the recording off.
function Read-HistoryLimit {
    param([string]$IniPath)

    $limit = 5
    if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) { return $limit }

    $section = ''
    foreach ($line in ((Read-TextFile $IniPath) -split "`r?`n")) {
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith(';') -or $text.StartsWith('#')) { continue }

        if ($text -match '^\[(.*)\]$') {
            $section = $Matches[1].Trim().ToLowerInvariant()
            continue
        }

        if ($section -ne 'history') { continue }

        $eq = $text.IndexOf('=')
        if ($eq -lt 1) { continue }

        $key = $text.Substring(0, $eq).Trim().ToUpperInvariant()
        if ($key -ne 'LIMIT') { continue }

        $value = $text.Substring($eq + 1).Trim()
        $parsed = 0
        if ([int]::TryParse($value, [ref]$parsed) -and $parsed -ge 0) {
            $limit = $parsed
        }
    }

    return $limit
}

# Writes one batch as a history file. A path never contains a tab, so it
# separates the two sides without quoting.
function Write-HistoryFile {
    param([string]$Path, [string]$Time, [string]$Mode, $Steps)

    $lines = [System.Collections.Generic.List[string]]::new()
    [void]$lines.Add('# NameEdit history')
    [void]$lines.Add('time=' + $Time)
    [void]$lines.Add('mode=' + $Mode)
    [void]$lines.Add('count=' + $Steps.Count)
    [void]$lines.Add('---')
    foreach ($step in $Steps) {
        [void]$lines.Add($step.From + "`t" + $step.To)
    }

    Write-TextFile $Path (($lines -join "`r`n") + "`r`n")
}

# Records a batch so restore.ps1 can walk it backwards. The timestamp prefix
# sorts by age, so the oldest entries are dropped first once the limit is
# exceeded. Returns the path written, or $null when nothing was recorded.
function Add-HistoryEntry {
    param([string]$HistoryDir, [int]$Limit, $Steps, [string]$Mode)

    if ($Limit -le 0) { return }
    if ($null -eq $Steps -or $Steps.Count -eq 0) { return }

    try {
        [void][IO.Directory]::CreateDirectory($HistoryDir)

        $name = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' +
            [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt'
        $path = Join-Path $HistoryDir $name

        Write-HistoryFile $path (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Mode $Steps

        $files = @(Get-ChildItem -LiteralPath $HistoryDir -Filter '*.txt' -File |
            Sort-Object -Property Name -Descending)
        for ($i = $Limit; $i -lt $files.Count; $i++) {
            Remove-Item -LiteralPath $files[$i].FullName -Force -ErrorAction SilentlyContinue
        }

        return $path
    }
    catch {
        # History is a convenience; failing to record it must not turn a
        # completed rename into an error.
        Write-Host ('Could not record the history entry: ' + $_.Exception.Message) -ForegroundColor Yellow
    }
}
