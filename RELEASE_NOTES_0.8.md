> **系统要求：** iOS 27，或 iOS 26.0 – 26.7.2（初步支持）。实测支持 iOS 27.0.1、27.2 与 26.7.1。
> **签名要求：** 必须使用保留 **App Group** 权限的侧载签名工具（推荐使用 AltStore、SideStore 或 Sideloadly）。WQ Files 现已在启动时自动检查签名权限；若提示缺少权限，请参考 [README 签名说明](https://github.com/Kianuni/WQFiles-CN#签名注意事项必读关于-app-group-权限) 重新签名。

# WQ Files（简体中文全量汉化版）v0.8 (Build 34)

## 应用列表秒级加载

- **告别漫长首次扫描**：在所有 iOS 版本上，“应用管理”、“缓存清理”、“应用数据”与“扩展插件数据”现在均直接从 iOS 系统的应用数据库（`LaunchServices`）读取。数据库只需在最新文件中查找一次（通常仅需数秒）并自动记忆；此前首次全盘扫描可能需要数分钟至近一小时（[#11](https://github.com/kolbicz/WQFiles/issues/11)、[#12](https://github.com/kolbicz/WQFiles/issues/12)、[#16](https://github.com/kolbicz/WQFiles/issues/16)、[#17](https://github.com/kolbicz/WQFiles/issues/17)）。
- **自动过滤已卸载应用的残留记录**：数据库中仍保留但磁盘上已不存在的旧安装容器会被自动跳过，不再显示为“拒绝访问”。
- **按需且经用户确认才执行全盘扫描**：“内部守护进程”（以及数据库无法读取时的应用目录）仍需扫描所有文件 ID。WQ Files 现在会先弹窗告知文件总数与预计耗时，经确认后才开始扫描，并提供包含进度百分比、剩余时间、“隐藏”与“停止扫描”按钮的独立扫描进度窗口；后续扫描仅增量检查新增文件。

## 新增功能（已 100% 简体中文汉化）

- **多维排序**（[#14](https://github.com/kolbicz/WQFiles/issues/14)）：在文件夹右上角 `•••` 菜单中支持按 **名称**、**修改日期**、**创建日期** 或 **大小** 排序；再次点选同一项即可切换正序/倒序，并支持“文件夹置顶”开关。“应用管理”列表支持按 **大小** 或 **名称** 排序。
- **A–Z 快速索引侧边栏**（[#20](https://github.com/kolbicz/WQFiles/issues/20)）：按名称排序的长列表右侧自动显示 A–Z 字母快速跳转栏。
- **只读 SQLite 数据库查看器**（[#21](https://github.com/kolbicz/WQFiles/issues/21)）：支持浏览所有数据表与视图（含行数统计）、分页浏览数据行、查看与复制单行完整字段、运行只读 SQL 查询（`SELECT`、只读 `PRAGMA`、`EXPLAIN`）以及一键导出 CSV。全程基于数据库及其 `-wal` 文件的临时副本运行，绝不修改应用原文件；打开 SQLite 文件时自动进入，也可通过“打开方式”手动切换。
- **文件浏览器左滑 / 右滑删除**：支持左右滑动删除条目，删除前会弹窗确认并自动备份普通文件。
- **启动时签名权限自检**：若签名工具移除了 App Group 权限，启动进入首页时会立即弹窗说明原因并提供签名帮助链接（[#15](https://github.com/kolbicz/WQFiles/issues/15)）。
- **首页底部显示版本号**：在首页底部作者信息旁直接展示当前版本号与构建号。

## 修复与改进

- **iOS 26 兼容性说明**：在 iOS 26 上系统不向 WQ Files 提供其他应用的图标且不允许跨沙盒读取应用 Bundle，因此应用显示为首字母符号色块；除“系统数据”和“系统共享组”外，其余功能均与 iOS 27 一致。
- **沙盒授权查询优化**：首次成功后即固定使用当前设备适用的查询标志，不再反复来回切换。
- **日志增强**：在“运行日志”中详细记录拒绝访问的应用容器及应用数据库的读取方式。

## AltStore / SideStore 软件源

```text
https://raw.githubusercontent.com/Kianuni/WQFiles-CN/main/source.json
```

## 致谢与协议

- 上游原项目：[kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)（作者：kolbicz）
- 底层沙盒技术：[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)（作者：Taj C / forcequit）
- 容器枚举思路：[murk-sus/kamui-escape](https://github.com/murk-sus/kamui-escape)（作者：murk-sus）
- 开源协议：`GPL-3.0-or-later`

`WQFiles.ipa` SHA-256：`61bf90c4bc9341157c83bffffd63b0b3eb7b4f6aae4e0c925371a75e0a93b2be`
