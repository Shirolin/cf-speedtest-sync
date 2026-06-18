# cf-speedtest-sync ⚡

全平台 Cloudflare 优选 IP 自动同步工具。自动寻找 Cloudflare 最快 IP 并实时更新您的域名解析记录。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux%20%7C%20iStoreOS-blue)](https://github.com/your-username/cf-speedtest-sync)

## 🚀 核心功能

- **全平台支持**：原生支持 Windows (PowerShell) 及 Linux/iStoreOS (Shell)。
- **多子域名同步**：支持单次测速结果同步至多个子域名（如 `www`, `cdn` 等）。
- **智能同步逻辑**：
    - **安全锁**：测速失败自动停止同步，防止误删现有解析。
    - **增量更新**：仅当 IP 发生变动时才调用 API，极大减少 API 消耗。
    - **限流保护**：内置写操作延时，避开 DNS 提供商的频率限制。
- **架构适配**：Linux 版脚本自动识别并下载 `x86_64` 或 `aarch64` (R4S/R5S) 架构的测速内核。
- **多提供商计划**：目前已支持 **DNSPod (腾讯云)**，即将支持 **阿里云 DNS**、**Cloudflare API** 等。

## 🛠️ 安装要求

### Windows / WSL
- PowerShell 7+ (Windows) 或 Bash (WSL)
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
   - 现在支持 IPv4 和 IPv6 分别配置。
   - 支持自定义测速链接。

3. **运行脚本**
   - **Windows**: `pwsh optimize.ps1`
   - **Linux/iStoreOS**:
     - 测试运行（不修改 DNS）: `sh linux/optimize.sh test`
     - 正式运行: `sh linux/optimize.sh`

## 📅 自动化运行 (Crontab)

建议每天凌晨运行一次。在 iStoreOS 中只需运行：
```bash
sh linux/optimize.sh install
```
该命令会自动将脚本加入系统计划任务（每天凌晨 4 点执行）。

## 💡 Linux 版增强功能 (Phase 2)

- **安全测试模式**：支持 `test` 参数进行 Dry Run，在不修改真实 DNS 的情况下验证逻辑。
- **双栈支持**：同时支持 IPv4 和 IPv6 (AAAA) 记录同步。
- **模块化 DNS**：支持多种 DNS 提供商（目前已内置 DNSPod）。
- **环境变量安全**：支持从环境变量 `CF_SECRET_ID` 和 `CF_SECRET_KEY` 读取密钥，无需写入配置文件。
- **下载镜像支持**：内置 GitHub 镜像加速（如 ghproxy），解决国内下载测速内核慢的问题。
- **无损更新**：采用“先对比、再更新”策略，仅在 IP 变动时操作，避免 DNS 停机。
- **自动加锁**：防止多个进程同时运行导致冲突。
- **智能日志**：支持自动日志轮转，防止占用 R4S 过多空间。

## 🤝 贡献与支持

如果你有任何建议或发现了 Bug，欢迎提交 Issue。后续计划增加更多 DNS 提供商支持，欢迎提交 Pull Request！

## 📄 开源协议

基于 [MIT License](LICENSE) 协议。
