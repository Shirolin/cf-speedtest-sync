# cf-speedtest-sync ⚡

全平台 Cloudflare 优选 IP 自动同步工具。自动寻找 Cloudflare 最快 IP 并实时更新您的域名解析记录。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
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
   - **`IPSource`**：设置默认为 `"local"`, `"api"` 或 `"saas"`。
   - **`Lines`**：托管的运营商线路。若想确保 Cloudflare SaaS 证书有效和海外最优路由，建议设为 `["境内"]`，并将 DNSPod 的 `默认` 线路在后台手动配置为 CNAME 回源。

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

## 🤝 鸣谢与声明

本项目的本地测速模块依赖并集成了优秀的开源项目 [XIU2/CloudflareSpeedTest](https://github.com/XIU2/CloudflareSpeedTest)（简称 `cfst`）。在此向原作者 [XIU2](https://github.com/XIU2) 表达诚挚的感谢！

- **测速内核 (cfst)**：基于 [GPL-3.0 License](https://github.com/XIU2/CloudflareSpeedTest/blob/master/LICENSE) 协议发布。
- **本同步脚本 (Wrapper)**：采用 [MIT License](LICENSE) 协议发布。由于本脚本是通过独立进程调用方式使用 `cfst` 二进制内核，不涉及对 GPL 源码的修改与静态链接编译，故本脚本符合 MIT 与 GPL-3.0 的开源合规性。

如果您有任何建议或发现了 Bug，欢迎提交 Issue。后续计划增加更多 DNS 提供商支持，欢迎提交 Pull Request！

## 📄 开源协议

本项目脚本部分基于 [MIT License](LICENSE) 协议。核心测速内核遵循原项目的 [GPL-3.0 License](https://github.com/XIU2/CloudflareSpeedTest/blob/master/LICENSE) 协议。
