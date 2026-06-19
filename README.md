# cf-speedtest-sync ⚡

全平台 Cloudflare 优选 IP 自动同步工具。自动寻找 Cloudflare 最快 IP 并实时更新您的域名解析记录。

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20iStoreOS-blue)](https://github.com/your-username/cf-speedtest-sync)

## 🚀 核心功能

- **全平台支持**：原生支持 Windows (PowerShell) 及 Linux/iStoreOS (Shell)。
- **多样化数据源 (IPSource)**：
  - **本机测速 (`local`)**：使用本地运行的 `cfst` 内核，精准测试并选取适合您当前宽带的 IP。
  - **第三方优选 API (`api`)**：拉取全国范围内的综合优选 IP，解决本地网络偏颇、不具备高宽带测速的痛点。
  - **影子优选 (`saas`)**：从高可用的大厂 SaaS 域名（如 Discord, Zoom, Pages 等）中自动抓取并扩展活跃的企业级 /24 网段，在不耗费大量外部接口流量下本地优选。
- **目录归档与隔离**：所有生成的中间 CSV 结果、最终 Markdown 报告和日志，都将按照配置中的 `Domain` 分门别类存储在 `output/<Domain>/` 目录下，保持项目目录整洁。
- **精细化线路安全隔离**：DNS 同步删除逻辑**仅对配置在 `Lines` 中的解析线路生效**。这能让您安全地在 DNSPod 中把 `"默认"` (Default) 或 `"境外"` (Overseas) 线路配置为 CNAME 记录回源（防止影响 Cloudflare SaaS 证书校验），同时放心地让脚本只托管国内的 `"境内"` (A 记录) 或各运营商线路。
- **智能同步逻辑**：
  - **安全锁**：测速失败自动停止同步，防止误删现有解析。
  - **增量更新**：仅当 IP 发生变动时才调用 API，极大减少 API 消耗。
  - **限流保护**：内置写操作延时，避开 DNS 提供商的频率限制。
- **架构适配**：Linux 版脚本自动识别并下载 `x86_64` 或 `aarch64` (R4S/R5S) 架构的测速内核。
- **多提供商计划**：目前已支持 **DNSPod (腾讯云)**，即将支持 **阿里云 DNS**、**Cloudflare API** 等。

## 🛠️ 安装要求

### Windows / WSL
- PowerShell 5.1+ 或 PowerShell 7+ (Windows) / Bash (WSL)
- 已经获取腾讯云 API 密钥 (`SecretId`, `SecretKey`)

### iStoreOS (R4S 等)
- 安装必要依赖：
  ```bash
  opkg update && opkg install jq curl openssl-util
  ```
- 自动化安装：
  ```bash
  sh linux/optimize.sh install
  ```

## 📦 快速上手

1. **克隆项目**
   ```bash
   git clone https://github.com/your-username/cf-speedtest-sync.git
   cd cf-speedtest-sync
   ```

2. **配置信息**
   将 `config.example.json` 复制为 `config.json` 并填写你的信息。
   
   #### ⚙️ 配置参数详解
   
   | 参数项 | 默认值 | 释义 |
   | :--- | :--- | :--- |
   | `DNSProvider` | `"dnspod"` | DNS 解析提供商。当前支持 `"dnspod"` (腾讯云)。 |
   | `IPSource` | `"local"` | 优选 IP 来源。`"local"` 本机测速 / `"api"` 第三方优选 API / `"saas"` 大厂影子网段优选。 |
   | `Api.IPv4` | `"https://ipdb.api.030101.xyz/?type=bestcf"` | 第三方优选 IPv4 接口地址（仅在 `IPSource` 设为 `"api"` 时生效）。 |
   | `SecretId` | `"YOUR_SECRET_ID"` | 腾讯云 API 密钥 SecretId。 |
   | `SecretKey` | `"YOUR_SECRET_KEY"` | 腾讯云 API 密钥 SecretKey。 |
   | `Domain` | `"example.com"` | 托管的主域名。 |
   | `SubDomain` | `["cdn"]` | 待优选绑定的子域名数组（支持多个）。 |
   | `Lines` | `["电信", "联通", "移动"]` | 托管解析的运营商线路。如用 CNAME 回源 SaaS，推荐仅托管 `["境内"]`，并保持 `默认` 线路为 CNAME。 |
   | `IPv4.Enable` | `true` | 是否启用 IPv4 测速与同步。 |
   | `IPv4.File` | `"ip.txt"` | 本机测速时使用的 CF 原始 IP 范围文件（位于 `core/` 下）。 |
   | `IPv4.Threads` | `50` | 测速并发线程数。 |
   | `IPv4.DownloadCount` | `2` | 最终在 DNS 中绑定的优选 IP 数量。 |
   | `IPv4.LatencyLimit` | `250` | 延迟上限门槛（单位 ms），超过该延迟的 IP 丢弃。 |
   | `IPv4.SpeedTestURL` | `"https://speed.cloudflare.com/__down?bytes=100000000"` | 测速下载接口（使用 Cloudflare 官方测速大文件，按需截断不消耗整包）。 |

   - 支持 IPv4 和 IPv6 分别配置。

3. **运行脚本**
   - **Windows**: 
     - 默认运行: `powershell -ExecutionPolicy Bypass -File optimize.ps1`
     - 指定数据源: `powershell -ExecutionPolicy Bypass -File optimize.ps1 -Source [local|api|saas]`
   - **Linux/iStoreOS**:
     - 默认运行: `sh linux/optimize.sh`
     - 指定数据源: `sh linux/optimize.sh --source [local|api|saas]`
     - 安全测试模式（不修改 DNS）: `sh linux/optimize.sh test`

## 📅 自动化运行 (Crontab)

建议每天凌晨运行一次。在 iStoreOS 中只需运行：
```bash
sh linux/optimize.sh install
```
该命令会自动将脚本加入系统计划任务（每天凌晨 4 点执行）。

## 💡 强力安全机制

- **安全测试模式**：支持 `test` 参数进行 Dry Run，在不修改真实 DNS 的情况下验证逻辑。
- **双栈支持**：同时支持 IPv4 和 IPv6 (AAAA) 记录同步。
- **环境变量安全**：支持从环境变量 `CF_SECRET_ID` 和 `CF_SECRET_KEY` 读取密钥，无需写入配置文件。
- **自动加锁**：防止多个进程同时运行导致冲突。
- **智能日志**：支持自动日志轮转，防止占用过多空间。

## 📊 查看同步日志

项目会自动将 IP 同步记录写入到 `output/<你的域名>/sync.log`。为了方便查看历史轨迹，项目提供了查询过去一周（7天内）IP 同步日志的脚本：

### Windows 平台
在项目根目录下运行：
```powershell
powershell -ExecutionPolicy Bypass -File view_logs.ps1
```

### Linux 平台
在项目根目录下运行：
```bash
sh linux/view_logs.sh
```

## 🤝 鸣谢与声明

本项目的本地测速模块依赖并集成了优秀的开源项目 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（简称 `cfst`）。在此向原作者 [XIU2](https://github.com/XIU2) 表达诚挚的感谢！

- **测速内核 (cfst)**：基于 [GPL-3.0 License](https://github.com/XIU2/CloudflareSpeedTest/blob/master/LICENSE) 协议发布。
- **本同步脚本 (Wrapper)**：采用 [GPL-3.0 License](LICENSE) 协议发布，与上游测速内核保持一致。

如果您有任何建议或发现了 Bug，欢迎提交 Issue。后续计划增加更多 DNS 提供商支持，欢迎提交 Pull Request！

## 📄 开源协议

本项目完全基于 [GPL-3.0 License](LICENSE) 开源协议。
