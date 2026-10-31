#
# NameEdit installer.
#
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall
#
# Creates the ne.ini configuration on first run, then rebuilds the entries of
# this tool in the Explorer "Send to" menu according to that configuration.
# Safe to run repeatedly: entries this tool created are removed and recreated,
# anything else in the Send to folder is left alone.
#

[CmdletBinding()]
param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')

# Scripts live in src/, the configuration and the entry points live in the
# project root one level up.
$Root = Split-Path -Parent $PSScriptRoot
$IniPath = Join-Path $Root 'ne.ini'
$ScriptPath = Join-Path $PSScriptRoot 'ne.ps1'

# Identity written to the description of every entry this tool creates. A
# rebuild removes whatever carries it, so it has to stay unique per tool and
# must not be derived from the project folder or from the entry names, both of
# which the user is free to change.
$Marker = 'NameEdit {8f0a4b6c-5d3e-4a7b-9c21-6f1e8d0b2a43}'

# Description written by earlier versions; still recognised on rebuild.
$LegacyMarker = 'NameEdit'

$SendTo = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Microsoft\Windows\SendTo'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Shown in the install report so the installed copy can be told apart from
# another one.
$Version = Read-Version $Root

# Entries are moved here while the menu is being rebuilt. Keeping them out of
# the Send to folder leaves no stray files there if the run is cut short, and
# the ".lnk" name lets the description be read back on the next run.
$BackupDir = Join-Path $Root 'history\shortcut-backup'

$DefaultIni = @'
[Editor]
; Examples:
;   1. notepad.exe {file}
;   2. "%LOCALAPPDATA%\Programs\Microsoft VS Code\bin\code.cmd" --wait {file}
command = notepad.exe {file}

[SendTo]
; A = noExt, B = withExt, C = fullPath.
; Keep the letters of the entries you want in the "Send to" menu.
Modes = AB
; Menu item names. The "Send to" menu is sorted by name, not by line order.
A = NameEdit
B = NameEditExt
C = NameEditPath

[History]
; Rename batches kept for restore.cmd. 0 turns recording off.
Limit = 5
'@

$ModeOf = @{ A = 'noExt'; B = 'withExt'; C = 'fullPath' }

# --------------------------------------------------------------- helpers

function Get-Configuration {
    param([string]$FilePath)

    $config = @{
        Modes = 'AB'
        Names = @{ A = 'NameEdit'; B = 'NameEditExt'; C = 'NameEditPath' }
    }

    $section = ''
    foreach ($line in ((Read-TextFile $FilePath) -split "`r?`n")) {
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

        if ($section -ne 'sendto') { continue }

        if ($key -eq 'MODES') {
            $letters = ''
            foreach ($ch in $value.ToUpperInvariant().ToCharArray()) {
                if ('ABC'.IndexOf($ch) -ge 0 -and $letters.IndexOf($ch) -lt 0) {
                    $letters += $ch
                }
            }
            $config.Modes = $letters
        }
        elseif ($ModeOf.ContainsKey($key) -and $value -ne '') {
            $config.Names[$key] = $value
        }
    }

    return $config
}

# Builds the arguments of a "Send to" entry. -Command still runs when the
# script is gone, which is the only way to report a moved or deleted project
# folder; -File would just fail and the console would close before the message
# could be read. The paths added by "Send to" land behind the final # and are
# commented out, so they are read back from the raw command line instead.
function New-LaunchArguments {
    param([string]$Path, [string]$Mode)

    # A single-quoted PowerShell string keeps the path literal.
    $quoted = "'" + $Path.Replace("'", "''") + "'"

    $body = '$a = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 6); ' +
        "if (Test-Path -LiteralPath $quoted -PathType Leaf) { & $quoted -Mode $Mode -Pause @a } else { " +
        "Write-Host ''; Write-Host 'NameEdit is not where it was installed; the program folder was moved or deleted.' -ForegroundColor Yellow; " +
        "Write-Host 'Run install.cmd from the new location to recreate the Send to entries.' -ForegroundColor Yellow; " +
        "Write-Host ''; Write-Host 'Press Enter to close.' -NoNewline; [void][Console]::ReadLine() } #"

    return '-NoProfile -ExecutionPolicy Bypass -Command "' + $body + '"'
}

function Get-ShortcutScript {
    param([string]$Arguments)
    if ([string]::IsNullOrWhiteSpace($Arguments)) { return $null }

    $match = [regex]::Match($Arguments, '(?i)(?:^|\s)-File\s+(?:"([^"]*)"|(\S+))')
    if (-not $match.Success) { return $null }

    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Test-ProjectScript {
    param([string]$FilePath)

    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $false }

    try {
        $left = [IO.Path]::GetFullPath($FilePath)
        $right = [IO.Path]::GetFullPath($ScriptPath)
    }
    catch {
        return $false
    }

    return [string]::Equals($left, $right, [StringComparison]::OrdinalIgnoreCase)
}

function Test-NameEditShortcut {
    param($Shortcut)

    if ($Shortcut.Description -eq $Marker) { return $true }
    if ($Shortcut.Description -eq $LegacyMarker) { return $true }

    # Entries that run this project's script belong to this project even when
    # their description is missing or was written by another version.
    return Test-ProjectScript (Get-ShortcutScript $Shortcut.Arguments)
}

function Get-NameEditShortcuts {
    param($Shell)

    if (-not (Test-Path -LiteralPath $SendTo -PathType Container)) { return @() }

    $found = @()
    foreach ($file in (Get-ChildItem -LiteralPath $SendTo -Filter '*.lnk' -File)) {
        try {
            $shortcut = $Shell.CreateShortcut($file.FullName)
            if (Test-NameEditShortcut $shortcut) { $found += $file.FullName }
        }
        catch {
            # Unreadable shortcut, leave it alone.
        }
    }
    return $found
}

# A run cut short between moving an entry aside and creating its replacement
# leaves the entry here. Put it back when the entry itself is gone, and drop
# it when the entry has been rebuilt already.
function Repair-ShortcutBackups {
    param($Shell)

    if (-not (Test-Path -LiteralPath $BackupDir -PathType Container)) { return }

    $restored = @()
    $dropped = @()

    foreach ($file in (Get-ChildItem -LiteralPath $BackupDir -Filter '*.lnk' -File)) {
        try {
            $shortcut = $Shell.CreateShortcut($file.FullName)
            if ($shortcut.Description -ne $Marker -and $shortcut.Description -ne $LegacyMarker) { continue }
        }
        catch {
            # Unreadable backup, leave it alone.
            continue
        }

        $original = Join-Path $SendTo $file.Name

        if (Test-Path -LiteralPath $original) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $dropped += $file.Name
            continue
        }

        try {
            [void][IO.Directory]::CreateDirectory($SendTo)
            Move-Item -LiteralPath $file.FullName -Destination $original -ErrorAction Stop
            $restored += $file.Name
        }
        catch {
            # Leave it for the user to sort out.
        }
    }

    if ($restored.Count -gt 0) {
        Write-Host ('Restored entries left over from an interrupted install: ' + ($restored -join ', '))
    }
    if ($dropped.Count -gt 0) {
        Write-Host ('Removed leftover backups: ' + ($dropped -join ', '))
    }
}

$shell = New-Object -ComObject WScript.Shell

Repair-ShortcutBackups $shell

# --------------------------------------------------------------- uninstall

if ($Uninstall) {
    $removed = @(Get-NameEditShortcuts $shell)
    foreach ($path in $removed) {
        Remove-Item -LiteralPath $path -Force
    }

    if ($removed.Count -eq 0) {
        Write-Host 'No NameEdit entries found in the "Send to" menu.'
    }
    else {
        $count = $removed.Count
        Write-Host "Removed $count entries from the Send to menu:"
        foreach ($path in $removed) {
            Write-Host ('  ' + [IO.Path]::GetFileNameWithoutExtension($path))
        }
    }
    exit 0
}

# ---------------------------------------------------------- configuration

if ($Version) {
    Write-Host ('NameEdit ' + $Version)
    Write-Host ''
}

if (-not (Test-Path -LiteralPath $IniPath -PathType Leaf)) {
    try {
        $content = ($DefaultIni -replace "`r`n", "`n") -replace "`n", "`r`n"
        Write-TextFile $IniPath ($content + "`r`n")
    }
    catch {
        Write-Host ('Failed to create config file: ' + $IniPath) -ForegroundColor Red
        Write-Host $_.Exception.Message
        exit 1
    }

    Write-Host ('ne.ini not found, created: ' + $IniPath)
    Write-Host ''
    Write-Host 'Edit it first, or press Enter for the defaults.'
    Write-Host 'Press Q to quit.'

    $answer = Read-Host
    if ($answer -match '^\s*[Qq]\s*$') { exit 0 }
}

$config = $null
for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
        $config = Get-Configuration $IniPath
        if ($null -eq $config) { throw 'Configuration parser returned nothing.' }
        break
    }
    catch {
        if ($attempt -eq 3) {
            Write-Host 'The config file is locked by another program. Close it and run install again.' -ForegroundColor Red
            exit 1
        }
        Start-Sleep -Milliseconds 200
    }
}

Write-Host ('Config: ' + $IniPath)

$created = @()
$skipped = @()

# The parser already falls back to the default names, so every enabled letter
# has a non-empty name here.
foreach ($ch in $config.Modes.ToCharArray()) {
    $letter = [string]$ch
    $name = $config.Names[$letter]

    if ($name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        $skipped += ($letter + ' (invalid name)')
        continue
    }
    if ($name.EndsWith(' ') -or $name.EndsWith('.')) {
        $skipped += ($letter + ' (the name cannot end with a space or a dot)')
        continue
    }
    if ($ReservedNames -contains (($name -split '\.', 2)[0]).ToUpperInvariant()) {
        $skipped += ($letter + ' (the name is reserved)')
        continue
    }

    $created += [pscustomobject]@{ Letter = $letter; Name = $name; Mode = $ModeOf[$letter] }
}

# -------------------------------------------------------- rebuild entries

if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
    Write-Host ('Script not found: ' + $ScriptPath) -ForegroundColor Red
    Write-Host 'The package looks incomplete; copy the whole folder again.'
    exit 1
}

# The old entries are moved aside rather than deleted, so a failure while
# creating the new ones can put the menu back the way it was.
if (Test-Path -LiteralPath $BackupDir) {
    Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
}

$backups = [System.Collections.Generic.List[object]]::new()
foreach ($path in (Get-NameEditShortcuts $shell)) {
    try {
        [void][IO.Directory]::CreateDirectory($BackupDir)
        $backup = Join-Path $BackupDir ([IO.Path]::GetFileName($path))
        Move-Item -LiteralPath $path -Destination $backup -ErrorAction Stop
        [void]$backups.Add([pscustomobject]@{ Original = $path; Backup = $backup })
    }
    catch {
        # The entry stays where it is; if its name is needed it is reported
        # as taken below.
    }
}

[void][IO.Directory]::CreateDirectory($SendTo)

$installed = @()
$made = @()
$failed = @()

foreach ($entry in $created) {
    $linkPath = Join-Path $SendTo ($entry.Name + '.lnk')

    # Anything still holding the name was not recognised as ours by the
    # cleanup above, so it belongs to something else and must not be replaced.
    if (Test-Path -LiteralPath $linkPath) {
        $skipped += ($entry.Name + ' (the name is already taken in the "Send to" menu)')
        continue
    }

    try {
        $shortcut = $shell.CreateShortcut($linkPath)
        $shortcut.TargetPath = $PowerShellExe
        $shortcut.Arguments = New-LaunchArguments $ScriptPath $entry.Mode
        $shortcut.Description = $Marker
        $shortcut.WorkingDirectory = $Root
        $shortcut.Save()
        $made += $linkPath
        $installed += $entry
    }
    catch {
        $failed += ($entry.Name + ' (' + $_.Exception.Message + ')')
    }
}

if ($failed.Count -gt 0) {
    # All or nothing: drop what was created and put the old entries back.
    foreach ($path in $made) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }

    $stuckBackups = @()
    foreach ($item in $backups) {
        if (-not (Test-Path -LiteralPath $item.Backup)) { continue }
        try {
            Move-Item -LiteralPath $item.Backup -Destination $item.Original -Force -ErrorAction Stop
        }
        catch {
            $stuckBackups += $item.Backup
        }
    }

    Write-Host ''
    if ($stuckBackups.Count -eq 0) {
        Write-Host 'Could not create these entries; the previous menu entries were restored:' -ForegroundColor Red
    }
    else {
        Write-Host 'Could not create these entries, and some old entries could not be put back:' -ForegroundColor Red
    }
    foreach ($item in $failed) {
        Write-Host ('  ' + $item) -ForegroundColor Red
    }
    foreach ($backup in $stuckBackups) {
        Write-Host ('  left behind: ' + $backup) -ForegroundColor Yellow
    }

    if ($stuckBackups.Count -eq 0 -and (Test-Path -LiteralPath $BackupDir)) {
        Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

foreach ($item in $backups) {
    Remove-Item -LiteralPath $item.Backup -Force -ErrorAction SilentlyContinue
}
if (Test-Path -LiteralPath $BackupDir) {
    Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
}

$created = $installed

# ------------------------------------------------------------------ report

Write-Host ''

if ($created.Count -eq 0) {
    Write-Host 'No entries were created.'
}
else {
    Write-Host 'Created "Send to" entries:'
    foreach ($entry in $created) {
        $note = @{
            noExt    = 'file name'
            withExt  = 'file name with extension'
            fullPath = 'full path, can move files to another folder'
        }[$entry.Mode]
        Write-Host ('  ' + $entry.Name.PadRight(19) + '- ' + $note)
    }
}

if ($skipped.Count -gt 0) {
    Write-Host ''
    foreach ($item in $skipped) {
        Write-Host ('Skipped: ' + $item)
    }
}

Write-Host ''
Write-Host 'How to use:'
Write-Host '  Right-click files -> Send to -> pick an entry.'
Write-Host '  Edit the names, save and close the editor to apply.'
Write-Host ''
Write-Host 'Uninstall:'
Write-Host '  Double-click uninstall.cmd.'
