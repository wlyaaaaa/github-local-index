# H 盘 U 盘收尾状态

更新时间：2026-07-08 20:43:31 中国时间 (UTC+8)

本文件是公开摘要，只记录 H 盘整理、G 盘救援闭环和计划任务注意事项。不保存完整文件清单、原始日志、任务 XML、私有数据内容或敏感配置。

## 当前结论

- H 盘定位：随身 U 盘，不作为 DATA 镜像。
- H 盘长期结构：00_使用说明、01_随身重要资料、02_临时交换区、03_下载与安装包、80_自动备份区、90_人工保留区。
- 03_下载与安装包 保留为 E:\Downloads 同步目标，下载区不按 2025-07 前后做自动清理。
- 90_人工保留区\Downloads_redownload_risk_from_E 作为难以精确重新下载的软件/安装包风险保留集合。
- G 盘救援闭环目录为 G:\80_Backup\H_Drive_Rescue_20260707_DO_NOT_DELETE，该目录不得清理、去重或移动，除非用户明确点名删除这个救援目录。

## 本轮收尾证据

| 项目 | 公开摘要 |
| --- | --- |
| 风险下载集合 | H/G 双份校验：8413 个文件，29,560,907,193 字节；相对路径和长度全量匹配。 |
| 软件环境清单 | H/G 双份校验：3 个文件，35,510 字节；apps_latest.txt、env_latest.txt、winget_latest.json 的 SHA256 匹配。 |
| WeFlow 安装包 | E:\Downloads\WeFlow-dev-x64-Setup.exe 已补到 H 风险集合和 G 最终快照；三处 SHA256 一致。 |
| H 格式化前救援 | 精选资料、H-only 下载例外和全量元数据清单仍保留在 G 救援目录。 |
| H 盘健康 | 格式化后 H 盘为 NTFS，后续验收中 Get-Volume 为 Healthy/OK，fsutil dirty query H: 为 NOT Dirty。 |

## U 盘写入计划任务注意项

| 任务 | 当前状态 | H 写入关系 | 公开结论 |
| --- | --- | --- | --- |
| WeChatBackup-Weekly | Ready | 写 H:\80_自动备份区\WeChat\xwechat_files | 当前最需要注意的 H 写入任务；参数含 Usb,Drive。 |
| DownloadsToUSB-Daily | Disabled | 写 H:\03_下载与安装包 | 保留为下载同步任务；启用后只复制/更新，不删除 H 旧文件。 |
| AutoDigitalBackupToH | Disabled | 写 H:\80_自动备份区\软件环境 | 脚本已修复 winget 中文路径导出问题；当前禁用。 |
| AIModelsBackup-USB-Daily / AIModelsBackup-OnUSB | Disabled | 写 H:\80_自动备份区\AI大模型 | USB 层使用镜像语义，启用前必须确认目标路径、空间和 H 盘健康。 |
| DevConfigBackup-OnUSB / DevConfigBackup-Weekly | Disabled | 写 H:\80_自动备份区\DevConfig | 当前禁用；启用前建议先做状态检查。 |

## 后续原则

- 不建议把 E:\Downloads 全量再搬到 H 或 G；只补高价值、难以精确重下的小缺口。
- 启用任何 H 写入任务前，先检查 H 盘挂载、dirty 位、HealthStatus/OperationalStatus 和剩余空间。
- 不在公开索引仓库保存完整 G 救援清单；详细清单只留在 G 盘救援目录的 00_manifest。