# HashiCorp Vault 一键部署与管理脚本

这是一个用于在 Linux 系统上快速部署、初始化和管理 HashiCorp Vault 的全自动化脚本。它旨在简化繁琐的安装配置过程，支持自动解封、服务管理以及常用的运维操作。

## ✨ 功能特性

*   **智能环境检测**：自动识别操作系统（Ubuntu/CentOS）及 CPU 架构（amd64/arm64）。
*   **版本自适应**：自动获取并安装 Vault 最新版本，也支持指定版本安装。
*   **一键全自动**：
    *   自动安装依赖（curl, jq, wget, unzip）。
    *   自动配置 Systemd 服务与用户权限。
    *   **自动初始化 Vault** 并安全保存密钥至 `/root/.vault_keys`。
*   **运维增强**：
    *   **开机自动解封**：配置本地自动解封脚本，服务器重启后无需人工干预。
    *   **账号管理**：提供向导式创建 Admin 超级管理员用户与策略。
    *   **CORS 配置**：一键开启跨域访问支持（便于 Web UI 开发调试）。
*   **平滑升级**：支持在保留数据的前提下升级或降级 Vault 版本。

## 🖥️ 支持系统

*   Ubuntu 20.04 / 22.04
*   CentOS 7 / 8
*   RHEL / Fedora

## 🚀 快速开始

### 一键安装命令

在服务器 root 权限下执行以下命令即可启动：

```bash
bash <(curl -sL https://raw.githubusercontent.com/tysonair/vauin/main/vault-install.sh)
```

> **注意**：请确保你的 GitHub 仓库中文件名为 `vault-install.sh`，如果你的文件名为 `vauin.sh`，请相应修改上述命令的最后一部分。

### 脚本菜单

脚本运行后将显示交互式菜单：

1.  **安装 / 升级 Vault**：核心部署流程。
2.  **解封 Vault**：手动输入密钥或从文件读取密钥进行解封。
3.  **创建 admin 超管策略**：为创建管理员做准备。
4.  **添加管理员用户**：创建可登录 Web UI 的 Userpass 账号。
5.  **配置 CORS 跨域支持**：允许从其他域名访问 API。
6.  **查看 Vault 状态**：检查服务运行状态及密封状态。

## 📂 文件说明

*   **安装目录**：`/usr/local/bin/vault`
*   **配置文件**：`/etc/vault/vault.hcl`
*   **数据目录**：`/opt/vault/data`
*   **密钥备份**：`/root/.vault_keys` (⚠️ **极重要**，请下载保存后删除服务器上的副本)
*   **自动解封脚本**：`/usr/local/bin/vault-unseal.sh`

## ⚠️ 安全提示

1.  脚本生成的 `/root/.vault_keys` 包含 **Root Token** 和 **Unseal Keys**，这是访问 Vault 的最高权限凭证。
2.  **生产环境建议**：在部署完成后，将密钥记录在安全的密码管理工具中，并**删除**服务器上的 `/root/.vault_keys` 文件。
3.  本脚本配置的自动解封机制依赖于本地保存的密钥文件。如果删除了密钥文件，自动解封将失效，需要人工手动解封。

## 📝 常见问题

**Q: 运行脚本提示 `command not found`?**
A: 请确保系统已安装 `curl`。Ubuntu: `apt install curl` / CentOS: `yum install curl`。

**Q: 为什么安装后 Web UI 无法访问？**
A: 默认配置监听 `127.0.0.1:8200`。建议配合 Nginx 反向代理使用，或修改 `/etc/vault/vault.hcl` 中的 `address` 为 `0.0.0.0:8200`（不推荐直接暴露）。
