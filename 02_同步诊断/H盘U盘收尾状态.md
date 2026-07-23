# H 盘 U 盘收尾状态

更新时间：2026-07-23 10:20:00 中国时间 (UTC+8)

本文件是公开摘要，只记录 H 盘整理、G 盘救援闭环和计划任务注意事项。不保存完整文件清单、原始日志、任务 XML、私有数据内容或敏感配置。

## 当前结论

- H 盘定位：默认 BitLocker 锁定的冷备 U 盘，不作为在线热备或计划任务依赖。
- G 盘定位：可直接访问的在线热备盘；日常备份计划任务统一写 `G:\80_Backup`。
- H 盘长期结构：00_使用说明、01_随身重要资料、02_临时交换区、03_下载与安装包、80_自动备份区、90_人工保留区。
- `E:\Downloads` 已建立到 `G:\80_Backup\03_下载与安装包` 的人工热备基线；H 的 03 区只在统一 `G → H` 冷备窗口刷新。
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

## 计划任务收敛结果

| 任务 | 当前状态 | 热备目标 | 公开结论 |
| --- | --- | --- | --- |
| WeChatBackup-Weekly | Ready | `G:\80_Backup\WeChat\xwechat_files` | 参数为 `Hot,Drive`，不自动写 H。 |
| AutoDigitalBackupToG | Ready | `G:\80_Backup\软件环境` | 旧 `AutoDigitalBackupToH` 已删除。 |
| AIModelsBackup-Hot-Daily | Ready | `G:\80_Backup\AI大模型` | 旧 USB-Daily / OnUSB 自动写 H 任务已删除。 |
| AgentsHotMirror-Daily | Ready | `G:\80_Backup\ControlPlane\.agents` | 每日镜像 `.agents` 当前工作树；排除 `.git` 与临时附件，不写 H。 |
| DevConfigBackup-Weekly | Ready | `G:\80_Backup\DevConfig` | 参数为 `Hot,Drive`；旧 OnUSB 任务已删除。 |
| DownloadsToUSB-Daily | Removed | 无 | 旧 H 脚本及任务均已退役；如需刷新下载归档，人工运行 G 热备脚本。 |

## 后续原则

- 下载归档日常只写 G，不恢复下载到 H 的计划任务；是否纳入某次人工 G→H 冷备由当次容量和价值判断。
- H 冷备只能在人工维护窗口解锁、检查健康/空间、刷新后重新锁定；不得恢复插入即写或定时写任务。
- 不在公开索引仓库保存完整 G 救援清单；详细清单只留在 G 盘救援目录的 00_manifest。
