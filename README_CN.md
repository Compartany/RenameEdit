# RenameEdit

通过文本编辑器批量重命名文件。

轻量且强大。选定文件即开始，关闭编辑器即完成。无需安装依赖、配置环境、学习语法。

文件列表即普通文本：正则替换、多选编辑、列编辑、文字转换、排序、编号、宏等一切文本处理工具都能直接应用，整份交给 AI 处理亦可。

能力上限只取决于你能如何处理文本，而不像同类软件那样受预设功能限制。

## 用法

1. 在资源管理器中选中需要重命名的文件。
2. 右键「发送到」选择 `RenameEdit` 菜单项。
3. 编辑器打开文件名列表（按名称排序）。
4. 编辑文件名后关闭编辑器。

可双击 `restore.cmd` 撤销近期更改（恢复本身也能被撤销）。

## 模式

| 入口 | 编辑内容 |
| --- | --- |
| `RenameEdit` | 文件名 |
| `RenameEditExt` | 文件名（含扩展名） |
| `RenameEditPath` | 完整路径，可将文件移到其他目录 |

## 安装

双击 `install.cmd`，它会生成 `re.ini` 并把入口加到「发送到」菜单；修改 `re.ini` 后需重新安装。

双击 `uninstall.cmd` 删除入口。

## 配置

`re.ini` 在首次运行 `install.cmd` 时生成。`Modes` 决定生成哪些入口，`A`、`B`、`C` 用于设置入口名称。

```ini
[Editor]
command = notepad.exe {file}

[SendTo]
Modes = AB
A = RenameEdit
B = RenameEditExt
C = RenameEditPath

[History]
Limit = 5
```

`{file}` 会替换成临时列表文件的路径，并自动加引号。`Limit` 决定给 `restore.cmd` 保留多少批历史记录（恢复操作也记作一批），`0` 表示不记录。记录存放在本文件夹下的 `history\` 中，删除其中的记录文件即可清空历史。

需要 Windows 自带的 Windows PowerShell 5.1。

## 限制

- 重命名文件数量非常多时，可能会超出命令行长度限制。
- 移动安装目录会使菜单项失效，重新运行 `install.cmd` 即可修复。

## 命令行

| 命令 | 作用 |
| --- | --- |
| `re.cmd [-Mode <模式>] <文件…>` | 打开重命名列表，`-Mode` 缺省为 `noExt` |
| `restore.cmd [-Index <序号>]` | 恢复历史批次，序号 1 为最新；省略时先列出记录再询问 |
| `install.cmd` | 重建「发送到」菜单项（首次运行时生成 `re.ini`） |
| `uninstall.cmd` | 删除本工具加入「发送到」菜单的入口 |

任一命令追加 `--no-pause` 可跳过结束时的等待。
