> **系统要求：** iOS 27，或 iOS 26.0 – 26.7.2（初步支持）。已在 iOS 27.0.1、27.2 与 26.7.1 上实测通过。
> **签名要求：** 请使用保留 App Group 权限的侧载签名工具（如 AltStore、SideStore 或 Impactor；注意 Sideloadly 不会添加 App Group 权限），详见 README 中的[签名注意事项](https://github.com/Kianuni/WQFiles-CN#%E7%AD%BE%E5%90%8D%E6%B3%A8%E6%84%8F%E4%BA%8B%E9%A1%B9%E5%BF%85%E8%AF%BB%E5%85%B3%E4%BA%8E-app-group-%E6%9D%83%E9%99%90)。

# Worse Query Files 0.9（简体中文全量汉化版）

## 批量文件操作与跨应用管理

- **多选批量操作**（[#9](https://github.com/kolbicz/WQFiles/issues/9)）：点按任意文件夹右上角的 **“选择”**，即可同时勾选多个项目进行 **移动**、**压缩** 或 **删除**。
- **跨应用移动**：选择文件或文件夹后，打开任意应用数据目录下的目标文件夹，点按底部的 **“移动到此处”** 即可完成移动（永不覆盖目标位置已有的同名项目）。
- **ZIP 压缩与解压**：点按 **“压缩”** 可在当前目录生成 `.zip` 压缩包；长按 `.zip` 文件选择 **“解压”** 可将其解包到新建文件夹中（自动拦截并跳过越界路径、加密 ZIP 与符号链接）。
- **批量导入文件与导入整个文件夹**（[#23](https://github.com/kolbicz/WQFiles/issues/23)）：右上角 `•••` 菜单现支持一次导入多个文件，或直接选择并递归导入整个文件夹。若遇同名项目会自动添加数字后缀（如 `Name 2`），不会覆盖原有内容。

## 新增功能

- **代码与数据文件语法高亮**（[#34](https://github.com/kolbicz/WQFiles/issues/34)）：文本查看器在浏览与编辑时支持 **17 种语言语法高亮**：XML/plist、JSON、YAML、INI/TOML、CSS、SQL、Markdown、C/Objective-C、Swift、JavaScript/TypeScript、Java/Kotlin、Go、Rust、Python、Shell、Ruby 与 Lua。无扩展名文件可通过首行 `#!` 或 XML/JSON 内容自动识别；超过 1 MB 的大文件保持纯文本渲染以保证流畅度。
- **内置媒体播放器**（[#25](https://github.com/kolbicz/WQFiles/issues/25)、[#29](https://github.com/kolbicz/WQFiles/issues/29)）：支持直接点按（或通过 **“打开方式 → 媒体播放器”**）播放音视频文件（`mp3`、`m4a`、`wav`、`flac`、`mp4`、`mov` 等）。播放前会先将文件复制到 WQ Files 的临时目录中。
- **应用管理分类筛选**（[#28](https://github.com/kolbicz/WQFiles/issues/28)）：“应用管理”右上角按钮在排序选项旁新增 **“显示范围：全部应用 / Apple 应用 / 第三方应用 / 已备份应用”** 过滤器。
- **显示与复制 Bundle ID**（[#27](https://github.com/kolbicz/WQFiles/issues/27)）：
  - “应用数据”及其他容器列表现在直接在应用名称下方显示 **Bundle ID**，不再显示冗长的容器文件夹 UUID。
  - 在“应用管理”中长按任意应用，可快速选择 **“复制 Bundle ID”**、**“复制容器路径”** 与 **“打开数据文件夹”**。
- **从“应用备份”直接恢复**：在 **“应用备份”** 目录中长按应用或具体备份文件夹并选择 **“恢复备份…”**，即可直接跳转到“应用管理”并弹出该应用的恢复选项（目标应用仍需处于已安装状态）。
- **首页新增“设置”分区**：
  - **允许删除**（[#32](https://github.com/kolbicz/WQFiles/issues/32)，默认开启）：关闭后将禁止一切删除操作（文件夹和备份中隐藏“删除”与左滑删除、“应用管理”中隐藏“清空应用数据…”、“缓存清理”中也无法执行清理），但保存、移动与恢复功能仍正常可用。
  - **显示文件夹项目数**（[#35](https://github.com/kolbicz/WQFiles/issues/35)，默认关闭）：开启后在文件夹列表中异步统计并显示每个子文件夹内包含的项目数量。

## 交互改进

- **仅左滑触发删除**（[#36](https://github.com/kolbicz/WQFiles/issues/36)）：现在仅向左滑动行时显示删除操作，向右滑动不再触发删除，避免返回手势误触。

## 问题修复

- **修复 iOS 26.5 上“应用管理”仅显示少量应用及乱码的问题**（[#37](https://github.com/kolbicz/WQFiles/issues/37)）：iOS 26.5 的 `LaunchServices` 数据库结构与 26.7 略有差异，现已适配 26.5 布局；若遇到无法正常解析的数据库，WQ Files 会拒绝采用残缺列表并回退至全盘扫描。
- **支持删除带有锁定标志的文件**（[#8](https://github.com/kolbicz/WQFiles/issues/8)）：删除带有用户不可变（`UF_IMMUTABLE`）或仅追加（`UF_APPEND`）标志的文件时不再报 `Operation not permitted`，而是自动清除锁定标志后重试。
- **缺少 App Group 时不再弹出无效的全盘扫描提示**（[#31](https://github.com/kolbicz/WQFiles/issues/31)）：当签名工具移除了 App Group 权限时，直接提示需要重新签名，不再询问无意义的耗时长扫描。
- **日志优化**：
  - 应用数据库摘要日志不再重复输出两次。
  - 缺失容器标识符的日志每个文件夹仅记录一次。
  - 删除失败时在日志中详细记录目标项目的 `flags`、`uid` 与权限模式。

## 安装与签名说明更新

- README 新增 **Add AltSource** 与 **Download .ipa** 快捷按钮（[#24](https://github.com/kolbicz/WQFiles/issues/24)）。
- **重要提醒：Sideloadly 不会添加 WQ Files 所需的 App Group 权限**（[#33](https://github.com/kolbicz/WQFiles/issues/33)）。请改用 **AltStore**、**SideStore** 或 **[Impactor](https://github.com/claration/impactor)**（支持 macOS、Windows 与 Linux）安装，应用内签名检查弹窗已同步更新此说明。

## 致谢

底层沙盒技术：[worse_query](https://github.com/forcequitOS/worse_query)（作者 Taj C / forcequit）。容器枚举思路：[KAMUI](https://github.com/murk-sus/kamui-escape)（作者 murk-sus）。上游原项目：[kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)（作者 kolbicz）。开源协议：GPL-3.0-or-later。

WQFiles.ipa 的 SHA-256：`1bd24b34d4464f7c9366f6b945f4709c8b743db020add811f3fbfb871672d472`
