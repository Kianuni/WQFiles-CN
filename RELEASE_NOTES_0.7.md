> **系统要求：** iOS 26.0 – 26.7.2 或 iOS 27（实测支持 iOS 26.7.1、27.0、27.0.1 与 27.2）。
> **签名要求：** 必须使用保留 **App Group** 权限的侧载签名工具（推荐使用 AltStore、SideStore 或 Sideloadly）。若打开应用或“运行日志”中提示“缺少 App Group 权限”，请参考 [README 签名说明](https://github.com/Kianuni/WQFiles-CN#签名注意事项必读关于-app-group-权限) 重新签名。

# WQ Files（简体中文全量汉化版）v0.7 (Build 26)

## 全量简体中文汉化与体验增强

- **100% 全量界面与提示汉化**：完整汉化首页容器分类、文件浏览器、树形 Plist 编辑器、分页十六进制查看/编辑器、应用管理（备份/恢复/清空/ZIP 导出）、缓存与崩溃日志清理器、系统共享组探测以及全部安全校验与中断恢复提示。
- **内置 Apple 系统应用中文名称表**：完整本地化近百项 Apple 原生应用与系统后台服务名称（在 iOS 27 上无需调用受限 API 即可直接显示熟悉的中文应用名）。
- **新增现代设备型号识别**：支持识别并展示 iPhone 18 / 18 Pro / 18 Pro Max 等新型号名称。

## 同步上游 v0.7 核心更新

- **恢复 iOS 27.2 应用名称与缓存清理**：适配 iOS 27.2 新的 `LaunchServices` 数据库记录偏移布局，自动映射容器路径与应用名称。
- **正式支持 iOS 26（26.0 – 26.7.2）**：
  - 应用数据、扩展插件数据与 App Groups 直接通过应用数据库秒级加载，无需漫长扫描。
  - 在系统仅返回空白占位图标时，自动从应用 Bundle 中提取原始高清图标。
- **大幅提速且可持久化的扫描**：仅首次需要完整扫描，后续仅增量检查新建文件 ID；切换页面不会丢弃正在进行的后台扫描。
- **支持滑动删除**：在文件浏览器中左滑或右滑条目即可触发带安全确认与自动备份的删除操作。

## AltStore / SideStore 软件源

```text
https://raw.githubusercontent.com/Kianuni/WQFiles-CN/main/source.json
```

## 致谢与协议

- 上游原项目：[kolbicz/WQFiles](https://github.com/kolbicz/WQFiles)（作者：kolbicz）
- 底层沙盒技术：[forcequitOS/worse_query](https://github.com/forcequitOS/worse_query)（作者：Taj C / forcequit）
- 容器枚举思路：[murk-sus/kamui-escape](https://github.com/murk-sus/kamui-escape)（作者：murk-sus）
- 开源协议：`GPL-3.0-or-later`

`WQFiles.ipa` SHA-256：`eec26d35db8589a6238131f1959c2b3f0098458df46bdbdba68e8e0f51f1a75a`
