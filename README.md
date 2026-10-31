# NameEdit

Rename files in bulk with a text editor.

> [中文说明](https://github.com/Compartany/NameEdit/blob/master/README_CN.md)

## Usage

1. Select the files to rename in Explorer.
2. Right-click, choose Send to, then the `NameEdit` entry.
3. Your editor opens the list of names (sorted by name).
4. Edit the names and close the editor.

Double-click `restore.cmd` to undo a recent change (a restore can be undone
too).

## Modes

| Entry | What you edit |
| --- | --- |
| `NameEdit` | File name |
| `NameEditExt` | File name with extension |
| `NameEditPath` | Full path, can move files to another folder |

## Install

Double-click `install.cmd`. It creates `ne.ini` and adds the entries to the
"Send to" menu; reinstall after editing `ne.ini`.

Double-click `uninstall.cmd` to remove the entries.

## Configuration

`ne.ini` is created the first time `install.cmd` runs. `Modes` selects which
entries are created, and `A`, `B`, `C` set their names.

```ini
[Editor]
command = notepad.exe {file}

[SendTo]
Modes = AB
A = NameEdit
B = NameEditExt
C = NameEditPath

[History]
Limit = 5
```

`{file}` is replaced with the path of the temporary list file and gets quoted
automatically. `Limit` is how many batches of history `restore.cmd` keeps,
restores included; `0` turns recording off. The records live in the `history`
folder here; delete them to clear the history.
Requires Windows PowerShell 5.1, included in Windows.

## Limits

- Renaming a very large number of files can hit the command line length limit.
- Moving this folder breaks the shortcuts; run `install.cmd` again to restore
  them.

## Command line

Besides the Send to menu, the entry points can be run from a command prompt:

```bat
restore.cmd
restore.cmd -Index 1
install.cmd
uninstall.cmd
```

Add `--no-pause` to skip the final key prompt, as in
`restore.cmd -Index 1 --no-pause`.

`-Index` is the batch number in that list (1 is the newest); without it,
`restore.cmd` lists the batches and asks.
