# NameEdit

通过文本编辑器批量重命名文件。

## 用法

1. 在资源管理器中选中需要重命名的文件。
2. 右键「发送到」选择 `NameEdit` 菜单项。
3. 编辑器打开文件名列表（按名称排序）。
4. 编辑文件名后关闭编辑器。

可双击 `restore.cmd` 撤销近期更改（恢复本身也能被撤销）。

## 模式

| 入口 | 编辑内容 |
| --- | --- |
| `NameEdit` | 文件名 |
| `NameEditExt` | 文件名（含扩展名） |
| `NameEditPath` | 完整路径，可以把文件移到其他文件夹 |

## 安装

双击 `install.cmd`，它会生成 `ne.ini` 并把入口加到「发送到」菜单；修改 `ne.ini` 后需重新安装。

双击 `uninstall.cmd` 删除入口。

## 配置

`ne.ini` 在首次运行 `install.cmd` 时生成。`Modes` 决定生成哪些入口，`A`、`B`、`C` 用于设置入口名称。

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

`{file}` 会替换成临时列表文件的路径，并自动加引号。`Limit` 决定给 `restore.cmd` 保留多少批历史记录（恢复操作也记作一批），`0` 表示不记录。记录存放在本文件夹下的 `history\` 中，删除其中的记录文件即可清空历史。

需要 Windows 自带的 Windows PowerShell 5.1。

## 限制

- 重命名文件数量非常多时，可能会超出命令行长度限制。
- 移动本文件夹会让快捷方式失效，重新运行 `install.cmd` 恢复。

## 命令行

除「发送到」菜单外，也可以在命令行里调用：

```bat
restore.cmd
restore.cmd -Index 1
install.cmd
uninstall.cmd
```

追加 `--no-pause` 可跳过结束时的等待，如 `restore.cmd -Index 1 --no-pause`。

`-Index` 是列表中的批次序号（1 为最新）；省略时 `restore.cmd` 会先列出记录再询问。
