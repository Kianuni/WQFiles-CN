# WQ Files（简体中文全量汉化版 · 已归档停更）

> [!IMPORTANT]
> ### 📢 停更与归档说明（官方自 `v0.9.1` 起已原生内置简体中文）
>
> 自上游 **[kolbicz/WQFiles v0.9.1 (Build 50)](https://github.com/kolbicz/WQFiles/releases/tag/v0.9.1)** 起，官方原版已正式内置原生 **简体中文（`zh-Hans`）** 多语言支持（默认自动跟随 iOS 系统语言，也可在首页 **“设置 → 语言 (Language)”** 中手动切换）。
>
> 因此，本第三方汉化仓库（`Kianuni/WQFiles-CN`）已完成阶段性历史使命，**版本定格于 `v0.9 (Build 38)` 并停止后续同步更新**，仅保留已有源码与历史发版记录供参考。
>
> **👉 强烈建议所有用户直接前往上游官方仓库或切换至官方软件源，以获取 `v0.9.1` 及后续更新：**
> - **官方仓库**：[https://github.com/kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)
> - **官方 Releases 下载（原生支持中文）**：[https://github.com/kolbicz/WQFiles/releases/latest](https://github.com/kolbicz/WQFiles/releases/latest)
> - **官方 AltStore / SideStore / LiveContainer 软件源**：
>   ```text
>   https://raw.githubusercontent.com/kolbicz/WQFiles/main/source.json
>   ```
>
> <p align="center">
> <a href="https://altdirect.app/?url=https://raw.githubusercontent.com/kolbicz/WQFiles/main/source.json"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" width="180"></a>
> &nbsp;
> <a href="https://github.com/kolbicz/WQFiles/releases/latest/download/WQFiles.ipa"><img src="https://altdirect.app/assets/png/Download_Blue.png" width="180"></a>
> </p>

---

**WQ Files（Worse Query Files）** 是一款专为 **iOS 26 与 iOS 27** 打造的免越狱沙盒文件浏览器、应用数据备份/恢复管理器与缓存清理工具。无需越狱、无需内核漏洞，即可直接浏览和管理第三方 App 及系统共享容器文件（实测支持 iOS 26.0 – 26.7.2、iOS 27.0 – 27.2）。

本项目基于 [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles) (`v0.9`, Build `38`) 进行 **100% 全量简体中文汉化**，完整汉化了所有主界面、文件浏览器、跨应用文件移动、ZIP 压缩与解压、媒体播放器、17 种语言语法高亮查看器、Plist 属性列表编辑器、十六进制查看/编辑器、只读 SQLite 数据库查看器、应用数据备份与恢复管理、缓存清理器、内置系统应用名称映射表及安全提示文案，并新增 iPhone 18 系列机型名称识别。

---

## 核心特性

### 1. 支持访问的容器目录
- **应用数据 (`Containers/Data/Application`)**：全 iOS 版本均直接通过系统 `LaunchServices` 数据库秒级加载并记忆，自动识别已安装应用的中文名称、Bundle ID 与圆角图标（自动跳过已卸载应用的残留记录）。
- **App Groups 共享容器**：跨应用共享组数据目录（列表直接展示对应标识符而非文件夹 UUID）。
- **扩展插件数据 (`PluginKitPlugin`)** 与 **内部守护进程 (`InternalDaemon`)**：访问内部守护进程（或数据库不可读时的应用目录）首次需要全盘文件 ID 扫描，扫描前会弹窗展示文件数量与预计耗时，并提供可隐藏/停止的进度窗口；后续扫描仅增量检查新文件。
- **系统数据 (`/var/containers/Data/System`)**：仅 iOS 27 支持（支持列出目录；root 所有的系统文件受 Unix 权限保护）。
- **系统共享组 (`System Groups`)**：仅 iOS 27 支持。内置常见系统组探测（包含 `mobilegestaltcache`、`configurationprofiles` 等），也可点按右上角 `+` 手动输入任意 `systemgroup.*` 名称打开。
- **跳转到路径…**：输入任意绝对路径直接打开文件夹或文件。

> **iOS 26 兼容性说明（26.0 – 26.7.2，初步支持）**：
> 在 iOS 26 上，`worse_query` 可访问应用、扩展插件、守护进程与 App Groups 容器，但无法访问“系统数据”和“系统共享组”（界面会自动隐藏这两项及崩溃日志清理）。此外 iOS 26 不向第三方沙盒返回其他应用的图标，因此应用列表展示为彩色首字母符号色块。

### 2. 内置实用工具
- **应用管理**：
  - 支持按 **占用空间** 或 **应用名称（带 A–Z 侧边索引栏）** 排序，并支持按 **全部应用 / Apple 应用 / 第三方应用 / 已备份应用** 筛选显示范围。
  - 支持一键 **备份应用数据**（`Documents` + `Library`）、**从备份恢复**（也可在“应用备份”目录中长按直接恢复）、**清空应用数据**（效果等同全新重装）、**隔空投送 / 导出 ZIP 备份包**，长按应用可快速复制 Bundle ID、复制容器路径或打开数据文件夹。
- **缓存清理**：统计所有应用与扩展插件的 `Library/Caches`、`tmp` 以及系统崩溃日志（iOS 27）大小；支持一键勾选 50 MB+ 大缓存、搜索过滤、中途随时停止清理，长按条目可直接跳转到对应目录检查。
- **全功能文件管理与多模式原位编辑器**：
  - **多选批量操作与跨应用移动**：点按文件夹右上角 **“选择”** 可同时对多个文件/文件夹执行 **移动**、**压缩** 或 **删除**。**跨应用移动**支持在任意应用文件夹间自由搬移文件（自动防覆盖同名项目）。
  - **ZIP 压缩与解压**：支持将单个或多个项目直接压缩为 `.zip`，或长按 `.zip` 文件选择 **“解压”** 解包到新文件夹（自动拦截路径穿越、加密压缩包与符号链接）。
  - **批量导入文件与导入整个文件夹**：右上角 `•••` 菜单支持一次导入多个文件或递归导入整个文件夹（遇到同名项自动添加数字后缀，绝不覆盖原文件）。
  - **文件夹多维排序与 A–Z 索引栏**：支持按 **名称**、**修改日期**、**创建日期** 或 **大小** 正反序排列（支持切换“文件夹置顶”）；长列表按名称排序时自动提供右侧 A–Z 快速跳转栏。
  - **Plist 编辑器**：树形浏览与编辑字典/数组，按类型安全修改（布尔开关、整数、浮点数、字符串、ISO 8601 日期、十六进制二进制数据），支持新增、左滑/右滑删除、重命名键、数组拖拽排序，并保持原格式（二进制或 XML）原位写回。
  - **十六进制查看器与编辑器**：分页流式读取任意大小文件，支持跳转到十六进制/十进制偏移、搜索十六进制字节序列或 UTF-8 文本、高亮显示未保存修改并原位覆写字节。
  - **SQLite 数据库查看器（只读）**：自动识别 SQLite 数据库文件（或通过“打开方式”进入），支持浏览所有数据表与视图及行数统计、分页查看行数据、单行全字段详情复制、运行只读 SQL 查询（`SELECT` / `PRAGMA` / `EXPLAIN`）以及一键导出 CSV。操作全程基于数据库与 `-wal` 日志的私有临时副本，绝不改动原应用文件。
  - **媒体播放器**：支持直接播放音视频文件（`mp3`、`m4a`、`wav`、`flac`、`mp4`、`mov` 等，自动复制到临时目录后调用系统播放器播放）。
  - **代码语法高亮与文本/图片查看器**：支持 UTF-8 文本编辑、Plist XML 源码编辑及图片直接预览；内置 **17 种语言语法高亮**（XML/plist、JSON、YAML、INI/TOML、CSS、SQL、Markdown、C/Objective-C、Swift、JavaScript/TypeScript、Java/Kotlin、Go、Rust、Python、Shell、Ruby、Lua，支持无扩展名文件的 `#!` 或内容头自动识别，最高 1 MB）。
- **首页安全与显示设置**：
  - **允许删除**（默认开启）：关闭后将全局禁用所有删除、清空数据与缓存清理操作（保存、移动和恢复仍正常可用），防止误触删文件。
  - **显示文件夹项目数**（默认关闭）：开启后在文件夹列表中异步统计并显示每个子文件夹包含的项目数量。
- **运行日志**：记录容器扫描、沙盒令牌获取、文件读写备份、自动恢复及当前生效的 App Group 权限状态（启动时自动检测签名权限），支持一键分享排查。

---

## 安全保护机制

- **自动文件级备份**：在文件浏览器中覆写或删除任何普通文件前，都会先通过 APFS 克隆（Copy-on-Write）或流式复制自动备份至 **“文件备份 (`WQFiles/Backups`)”**（在系统自带“文件”App 中同样可见）。在备份文件上长按选择 **“恢复到原始位置”** 即可一键还原。
- **完整性校验与断电/闪退自动回滚**：应用数据备份采用隐藏暂存目录 + SHA-256 目录结构与内容哈希清单校验；执行应用数据恢复前会自动创建 **“恢复前自动备份”** 并写入持久化恢复日志（`active-restore.plist`），即使恢复中途闪退或断电，下次启动时也会自动回滚还原。
- **防误删保护**：支持左滑删除（右滑不再触发删除），且可在首页一键关闭“允许删除”总开关；文件浏览器仅允许删除空文件夹，不跟随符号链接（防止越界误删目标文件），且禁止通过普通文件操作递归篡改备份存储区。
- **重要提示**：备份、恢复、清空应用数据或清理缓存前，**请务必先在多任务切换器中上滑关闭目标应用**。修改系统或其他应用文件存在风险，请保留好备份并仅修改您明确了解的内容。

---

## 安装方式

### 方式一：通过 AltStore / SideStore / LiveContainer 软件源添加（推荐）

<h3 align="center">
<a href="https://altdirect.app/?url=https://raw.githubusercontent.com/Kianuni/WQFiles-CN/main/source.json"><img src="https://altdirect.app/assets/png/AltSource_Blue.png" width="200"></a>
&nbsp;
<a href="https://github.com/Kianuni/WQFiles-CN/releases/latest/download/WQFiles.ipa"><img src="https://altdirect.app/assets/png/Download_Blue.png" width="200"></a>
</h3>

在 iPhone 上点按上方 **Add AltSource** 即可通过 [AltDirect](https://altdirect.app) 一键添加中文版软件源至 AltStore、SideStore 或 LiveContainer，也可手动复制以下软件源地址添加：

```text
https://raw.githubusercontent.com/Kianuni/WQFiles-CN/main/source.json
```

### 方式二：手动下载 IPA 自签安装

前往 [Releases 页面](https://github.com/Kianuni/WQFiles-CN/releases) 下载最新的 `WQFiles.ipa`，使用支持保留 **App Group** 权限的签名工具签名安装。

---

## 签名注意事项（必读：关于 App Group 权限）

WQ Files 必须拥有一个有效的 **App Group** 权限才能通过 `worse_query` 访问其他沙盒容器（具体 Group 名称不限，应用会自动识别并使用签名赋予的第一个 App Group，可在“运行日志”顶部查看）。

- **AltStore / SideStore / [Impactor](https://github.com/claration/impactor)（使用个人免费或付费 Apple ID）**：会自动分配并保留 App Group，**最省心、最推荐**（Impactor 支持 macOS、Windows 与 Linux；注意：**Sideloadly 不会添加 App Group 权限**，使用 Sideloadly 签名会导致提示缺少 App Group）。
- **Feather / ESign / 巨魔之外的第三方证书（`.p12` + `.mobileprovision`）**：描述文件必须显式包含 `App Groups` 权限。市面上常见的通配符证书（App ID 为 `*`）不支持 App Group，会导致签名报错或打开后提示 **“缺少 App Group 权限”**。
- **Apple 开发者账号手动配置**：在 Apple Developer 后台创建一个 App Group，为显式 App ID 勾选 **App Groups** 权限并关联该组，生成对应的描述文件后再对 IPA 进行签名（请勿勾选移除权限选项）。

---

## 从源码编译与测试

环境要求：macOS + Xcode（含 iOS SDK）+ Python 3。

```bash
# 运行全部 14 项 Objective-C 回归测试 + Python 发布策略与静态 UI 检查 + 编译打包 WQFiles.ipa
./build.sh

# 仅运行主机端与静态回归测试套件
./tests/run_all_tests.sh
```

---

## 与上游同步更新

本仓库保留了与上游 [kolbicz/WQFiles](https://github.com/kolbicz/WQFiles) 完整的 Git 提交历史基线，支持自动与手动同步：

1. **GitHub Actions 自动巡检与同步（`.github/workflows/sync-upstream.yml`）**：每天定时检测上游 `main` 分支（也可在 GitHub Actions 页面手动点击 `Run workflow` 立即触发）。一旦发现上游更新，会自动拉取合并、在云端 macOS 环境编译验证并创建同步 Pull Request（如涉及汉化文本冲突则自动创建提醒 Issue）。
2. **本地一键同步脚本**：运行 `./scripts/sync_upstream.sh` 即可拉取合并 `upstream/main`、列出上游新增的英文文案并自动编译校验打包。

---

## 致谢与开源协议 (Credits & License)

本项目站在以下优秀开源项目与安全研究者的肩膀之上，特此致以诚挚感谢：

- **上游原项目**：[kolbicz/WQFiles](https://github.com/kolbicz/WQFiles) — 作者 **kolbicz**（[@_kolbicz](https://x.com/_kolbicz)）设计并编写了完整的 WQ Files 应用架构、UI 与安全备份恢复机制。
- **底层沙盒技术**：[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query) — 作者 **Taj C / forcequit**（[@forcequitOS](https://x.com/forcequitOS)），GPL-3.0-or-later。
- **基于 `fsgetpath` 的容器枚举思路**：[murk-sus/kamui-escape](https://github.com/murk-sus/kamui-escape) — 作者 **murk-sus**。

本项目遵循与上游一致的 **GNU General Public License v3.0 or later (`GPL-3.0-or-later`)** 开源协议发布，详见 [LICENSE](LICENSE)。
