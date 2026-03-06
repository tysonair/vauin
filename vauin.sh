#!/bin/bash

# =============================================================
# HashiCorp Vault 一键部署脚本
# 适用于：Ubuntu 20.04 / 22.04 / CentOS 7 / 8
# 作者：Tyson
# =============================================================

set -e

# -------- 颜色输出 --------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# -------- 配置变量（可修改）--------
VAULT_VERSION=""  # 留空则自动获取最新版本，或手动指定如 "1.17.2"
VAULT_PORT="8200"
VAULT_DATA_DIR="/opt/vault/data"
VAULT_CONFIG_DIR="/etc/vault"
VAULT_BIN="/usr/local/bin/vault"
VAULT_USER="vault"

# -------- 检查 root --------
check_root() {
  if [ "$EUID" -ne 0 ]; then
    error "请使用 root 用户运行此脚本：sudo bash vault-install.sh"
  fi
}

# -------- 检查系统 --------
check_system() {
  info "检测系统环境..."
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    VAULT_ARCH="amd64"
  elif [ "$ARCH" = "aarch64" ]; then
    VAULT_ARCH="arm64"
  else
    error "不支持的 CPU 架构: $ARCH"
  fi

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
    info "系统: $PRETTY_NAME | 架构: $ARCH"
  else
    error "无法识别操作系统"
  fi
}

# -------- 获取最新版本 --------
get_latest_version() {
  if [ -n "$VAULT_VERSION" ]; then
    info "使用指定版本: $VAULT_VERSION"
    return
  fi

  info "正在获取 Vault 最新版本..."
  
  # 通过 HashiCorp Checkpoint API 获取最新版本
  LATEST=$(curl -s --connect-timeout 10 "https://checkpoint-api.hashicorp.com/v1/check/vault" | jq -r '.current_version' 2>/dev/null)
  
  if [ -n "$LATEST" ] && [ "$LATEST" != "null" ]; then
    VAULT_VERSION="$LATEST"
    success "获取到最新版本: $VAULT_VERSION"
  else
    # 回退方案：从 releases 页面解析
    LATEST=$(curl -s --connect-timeout 10 "https://releases.hashicorp.com/vault/" | grep -oP 'vault_\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [ -n "$LATEST" ]; then
      VAULT_VERSION="$LATEST"
      success "获取到最新版本: $VAULT_VERSION"
    else
      VAULT_VERSION="1.17.2"
      warn "无法获取最新版本，使用默认版本: $VAULT_VERSION"
    fi
  fi
}

# -------- 安装依赖 --------
install_deps() {
  info "安装依赖..."
  if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -qq
    apt-get install -y -qq wget unzip curl jq > /dev/null
  elif [[ "$OS" == "centos" || "$OS" == "rhel" || "$OS" == "fedora" ]]; then
    yum install -y -q wget unzip curl jq > /dev/null
  else
    error "不支持的发行版: $OS"
  fi
  success "依赖安装完成"
}

# -------- 版本比较函数 --------
version_gt() {
  # 返回 0 表示 $1 > $2
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

# -------- 下载并安装 Vault --------
install_vault() {
  # 检测本地已安装版本
  if command -v vault &> /dev/null; then
    CURRENT_VERSION=$(vault --version | grep -oP '\d+\.\d+\.\d+' | head -1)
    
    if [ -n "$CURRENT_VERSION" ]; then
      echo ""
      info "检测到本地已安装 Vault"
      echo -e "  当前版本: ${YELLOW}$CURRENT_VERSION${NC}"
      echo -e "  目标版本: ${GREEN}$VAULT_VERSION${NC}"
      echo ""
      
      if [ "$CURRENT_VERSION" = "$VAULT_VERSION" ]; then
        success "版本一致，无需更新"
        return
      elif version_gt "$VAULT_VERSION" "$CURRENT_VERSION"; then
        # 目标版本更新
        echo -e "${YELLOW}发现新版本可用！${NC}"
        echo -e "  ${BLUE}[1]${NC} 升级到 $VAULT_VERSION"
        echo -e "  ${BLUE}[2]${NC} 保持当前版本 $CURRENT_VERSION"
        echo -e "  ${BLUE}[3]${NC} 强制重新安装 $VAULT_VERSION"
        echo ""
        read -p "请选择操作 [1/2/3] (默认: 1): " UPGRADE_CHOICE
        UPGRADE_CHOICE=${UPGRADE_CHOICE:-1}
        
        case $UPGRADE_CHOICE in
          1)
            info "开始升级..."
            ;;
          2)
            success "保持当前版本 $CURRENT_VERSION"
            VAULT_VERSION="$CURRENT_VERSION"
            return
            ;;
          3)
            info "强制重新安装..."
            ;;
          *)
            warn "无效选择，默认升级"
            ;;
        esac
      else
        # 本地版本更新
        echo -e "${YELLOW}本地版本比目标版本更新${NC}"
        echo -e "  ${BLUE}[1]${NC} 保持当前版本 $CURRENT_VERSION"
        echo -e "  ${BLUE}[2]${NC} 降级到 $VAULT_VERSION"
        echo ""
        read -p "请选择操作 [1/2] (默认: 1): " DOWNGRADE_CHOICE
        DOWNGRADE_CHOICE=${DOWNGRADE_CHOICE:-1}
        
        case $DOWNGRADE_CHOICE in
          1)
            success "保持当前版本 $CURRENT_VERSION"
            VAULT_VERSION="$CURRENT_VERSION"
            return
            ;;
          2)
            warn "开始降级安装..."
            ;;
          *)
            success "保持当前版本"
            VAULT_VERSION="$CURRENT_VERSION"
            return
            ;;
        esac
      fi
    fi
  else
    info "未检测到本地 Vault，将进行全新安装"
  fi

  # 执行下载安装
  info "下载 Vault $VAULT_VERSION..."
  DOWNLOAD_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${VAULT_ARCH}.zip"
  TMP_DIR=$(mktemp -d)

  wget -q --show-progress "$DOWNLOAD_URL" -O "$TMP_DIR/vault.zip" || \
    error "下载失败，请检查网络或手动下载: $DOWNLOAD_URL"

  info "安装 Vault..."
  unzip -q "$TMP_DIR/vault.zip" -d "$TMP_DIR"
  mv "$TMP_DIR/vault" "$VAULT_BIN"
  chmod +x "$VAULT_BIN"
  rm -rf "$TMP_DIR"

  # 允许 Vault 锁定内存（安全需要）
  setcap cap_ipc_lock=+ep "$VAULT_BIN" 2>/dev/null || warn "setcap 失败，Vault 仍可运行，但内存加锁功能不可用"

  success "Vault $VAULT_VERSION 安装完成"
}

# -------- 创建用户和目录 --------
setup_dirs() {
  info "创建目录和用户..."

  # 创建系统用户
  if ! id "$VAULT_USER" &>/dev/null; then
    useradd --system --no-create-home --shell /bin/false "$VAULT_USER"
  fi

  mkdir -p "$VAULT_DATA_DIR" "$VAULT_CONFIG_DIR"
  chown -R "$VAULT_USER:$VAULT_USER" "$VAULT_DATA_DIR" "$VAULT_CONFIG_DIR"
  chmod 750 "$VAULT_DATA_DIR" "$VAULT_CONFIG_DIR"

  success "目录创建完成"
}

# -------- 写入配置文件 --------
write_config() {
  info "写入 Vault 配置..."

  cat > "$VAULT_CONFIG_DIR/vault.hcl" << EOF
# HashiCorp Vault 配置文件
# 生成时间: $(date)

ui = true

storage "file" {
  path = "$VAULT_DATA_DIR"
}

listener "tcp" {
  address     = "127.0.0.1:$VAULT_PORT"
  tls_disable = 1
}

api_addr     = "http://127.0.0.1:$VAULT_PORT"
cluster_addr = "http://127.0.0.1:$((VAULT_PORT + 1))"

# 日志级别: trace, debug, info, warn, error
log_level = "info"
EOF

  chown "$VAULT_USER:$VAULT_USER" "$VAULT_CONFIG_DIR/vault.hcl"
  chmod 640 "$VAULT_CONFIG_DIR/vault.hcl"
  success "配置文件写入完成"
}

# -------- 配置 systemd --------
setup_systemd() {
  info "配置 systemd 服务..."

  cat > /etc/systemd/system/vault.service << EOF
[Unit]
Description=HashiCorp Vault - Secret Management Tool
Documentation=https://developer.hashicorp.com/vault/docs
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=$VAULT_CONFIG_DIR/vault.hcl

[Service]
User=$VAULT_USER
Group=$VAULT_USER
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
Capabilities=CAP_IPC_LOCK+ep
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
NoNewPrivileges=yes
ExecStart=$VAULT_BIN server -config=$VAULT_CONFIG_DIR/vault.hcl
ExecReload=/bin/kill -HUP \$MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
LimitNOFILE=65536
LimitMEMLOCK=infinity

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vault > /dev/null 2>&1
  systemctl restart vault

  sleep 2
  if systemctl is-active --quiet vault; then
    success "Vault 服务启动成功"
  else
    error "Vault 服务启动失败，请运行: journalctl -u vault -n 50"
  fi
}

# -------- 初始化 Vault --------
init_vault() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"

  # 等待 Vault 就绪
  info "等待 Vault 就绪..."
  for i in {1..15}; do
    if curl -s "$VAULT_ADDR/v1/sys/health" > /dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  # 检查是否已初始化
  INIT_STATUS=$(curl -s "$VAULT_ADDR/v1/sys/init" | jq -r '.initialized' 2>/dev/null)
  if [ "$INIT_STATUS" = "true" ]; then
    warn "Vault 已初始化，跳过此步骤"
    VAULT_ALREADY_INITIALIZED="true"
    return
  fi

  VAULT_ALREADY_INITIALIZED="false"

  info "初始化 Vault..."
  INIT_OUTPUT=$(vault operator init -format=json 2>/dev/null)

  # 解析密钥
  UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[0]')
  UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[1]')
  UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[2]')
  UNSEAL_KEY_4=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[3]')
  UNSEAL_KEY_5=$(echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[4]')
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

  # 保存到文件（权限 600）
  KEYS_FILE="/root/.vault_keys"
  cat > "$KEYS_FILE" << EOF
# =======================================================
# ⚠️  HashiCorp Vault 初始化密钥 - 请妥善保管！
# ⚠️  请立即备份此文件到安全位置后删除！
# 生成时间: $(date)
# =======================================================

Unseal Key 1: $UNSEAL_KEY_1
Unseal Key 2: $UNSEAL_KEY_2
Unseal Key 3: $UNSEAL_KEY_3
Unseal Key 4: $UNSEAL_KEY_4
Unseal Key 5: $UNSEAL_KEY_5

Root Token: $ROOT_TOKEN

# 解封命令（服务器重启后需要执行）：
# export VAULT_ADDR='http://127.0.0.1:$VAULT_PORT'
# vault operator unseal <Key 1>
# vault operator unseal <Key 2>
# vault operator unseal <Key 3>
EOF
  chmod 600 "$KEYS_FILE"

  # 自动解封
  info "自动解封 Vault..."
  vault operator unseal "$UNSEAL_KEY_1" > /dev/null
  vault operator unseal "$UNSEAL_KEY_2" > /dev/null
  vault operator unseal "$UNSEAL_KEY_3" > /dev/null

  # 登录并启用 KV
  vault login "$ROOT_TOKEN" > /dev/null 2>&1
  vault secrets enable -path=secret kv-v2 > /dev/null 2>&1

  success "Vault 初始化完成"
}

# -------- 写入自动解封脚本 --------
setup_unseal_script() {
  KEYS_FILE="/root/.vault_keys"
  
  # 升级场景：密钥文件不存在
  if [ ! -f "$KEYS_FILE" ]; then
    if [ "$VAULT_ALREADY_INITIALIZED" = "true" ]; then
      warn "升级模式：密钥文件不存在，跳过自动解封配置"
      info "如需配置自动解封，请手动编辑 /usr/local/bin/vault-unseal.sh"
      return
    fi
  fi

  info "创建开机自动解封脚本..."

  KEY1=$(grep "Unseal Key 1:" "$KEYS_FILE" | awk '{print $NF}')
  KEY2=$(grep "Unseal Key 2:" "$KEYS_FILE" | awk '{print $NF}')
  KEY3=$(grep "Unseal Key 3:" "$KEYS_FILE" | awk '{print $NF}')

  cat > /usr/local/bin/vault-unseal.sh << EOF
#!/bin/bash
# Vault 自动解封脚本
export VAULT_ADDR='http://127.0.0.1:$VAULT_PORT'

# 等待 Vault 服务启动
sleep 5

# 检查是否需要解封
SEALED=\$(curl -s \$VAULT_ADDR/v1/sys/health | jq -r '.sealed' 2>/dev/null)
if [ "\$SEALED" = "true" ]; then
  vault operator unseal $KEY1
  vault operator unseal $KEY2
  vault operator unseal $KEY3
  echo "\$(date): Vault 解封完成" >> /var/log/vault-unseal.log
fi
EOF
  chmod 700 /usr/local/bin/vault-unseal.sh

  # 注册开机任务
  cat > /etc/systemd/system/vault-unseal.service << EOF
[Unit]
Description=Vault Auto Unseal
After=vault.service
Requires=vault.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vault-unseal.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable vault-unseal > /dev/null 2>&1
  success "开机自动解封已配置"
}

# -------- 配置防火墙 --------
setup_firewall() {
  info "检查防火墙..."
  # Vault 只监听 127.0.0.1，不需要开放端口
  # 通过 Nginx 反代访问，无需额外配置
  success "防火墙无需配置（Vault 仅监听本地）"
}

# -------- 打印最终信息 --------
print_summary() {
  KEYS_FILE="/root/.vault_keys"
  
  echo ""
  echo -e "${GREEN}============================================${NC}"
  
  # 区分新安装和升级
  if [ "$VAULT_ALREADY_INITIALIZED" = "true" ]; then
    echo -e "${GREEN}   ✅  HashiCorp Vault 升级完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}📋 升级信息：${NC}"
    echo -e "  当前版本：${BLUE}$VAULT_VERSION${NC}"
    echo -e "  服务状态：${BLUE}$(systemctl is-active vault)${NC}"
    echo ""
    echo -e "${YELLOW}💡 提示：${NC}"
    echo -e "  升级不会改变原有的 Token 和 Unseal Keys"
    echo -e "  请使用原有的密钥进行操作"
  else
    ROOT_TOKEN=$(grep "Root Token:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
    echo -e "${GREEN}   ✅  HashiCorp Vault 部署完成！${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${YELLOW}📋 重要信息：${NC}"
    echo -e "  密钥文件位置：${BLUE}/root/.vault_keys${NC}"
    echo -e "  Root Token：${BLUE}$ROOT_TOKEN${NC}"
    echo ""
    echo -e "${RED}⚠️  警告：请立即备份 /root/.vault_keys 文件到安全位置！${NC}"
  fi
  
  echo ""
  echo -e "${YELLOW}🌐 宝塔面板配置反向代理：${NC}"
  echo -e "  目标地址：${BLUE}http://127.0.0.1:$VAULT_PORT${NC}"
  echo ""
  echo -e "${YELLOW}📦 常用命令：${NC}"
  echo -e "  export VAULT_ADDR='http://127.0.0.1:$VAULT_PORT'"
  echo -e "  vault login                        # 登录"
  echo -e "  vault kv put secret/myapp KEY=val  # 存入密钥"
  echo -e "  vault kv get secret/myapp          # 读取密钥"
  echo -e "  systemctl status vault             # 查看状态"
  echo ""
}

# -------- 自动解封 Vault --------
auto_unseal_vault() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  # 检查是否 sealed
  SEALED=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null | jq -r '.sealed' 2>/dev/null)
  
  if [ "$SEALED" != "true" ]; then
    return 0  # 未密封，无需解封
  fi
  
  info "检测到 Vault 处于密封状态，尝试自动解封..."
  
  # 方式1：从 /root/.vault_keys 读取 unseal keys
  KEYS_FILE="/root/.vault_keys"
  if [ -f "$KEYS_FILE" ]; then
    KEY1=$(grep "Unseal Key 1:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
    KEY2=$(grep "Unseal Key 2:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
    KEY3=$(grep "Unseal Key 3:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
    
    if [ -n "$KEY1" ] && [ -n "$KEY2" ] && [ -n "$KEY3" ]; then
      vault operator unseal "$KEY1" > /dev/null 2>&1
      vault operator unseal "$KEY2" > /dev/null 2>&1
      vault operator unseal "$KEY3" > /dev/null 2>&1
      
      # 验证解封结果
      SEALED=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null | jq -r '.sealed' 2>/dev/null)
      if [ "$SEALED" = "false" ]; then
        success "自动解封成功"
        return 0
      fi
    fi
  fi
  
  # 方式2：尝试执行 unseal 脚本
  if [ -x "/usr/local/bin/vault-unseal.sh" ]; then
    info "尝试执行 vault-unseal.sh..."
    /usr/local/bin/vault-unseal.sh > /dev/null 2>&1
    
    SEALED=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null | jq -r '.sealed' 2>/dev/null)
    if [ "$SEALED" = "false" ]; then
      success "自动解封成功"
      return 0
    fi
  fi
  
  error "自动解封失败，请手动执行: vault operator unseal <key>"
}

# -------- 自动登录 Vault --------
auto_login_vault() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  # 检查 Vault 是否运行
  if ! curl -s "$VAULT_ADDR/v1/sys/health" > /dev/null 2>&1; then
    error "Vault 服务未运行，请先启动 Vault"
  fi
  
  # 先检查并自动解封
  auto_unseal_vault
  
  # 已登录则直接返回
  if vault token lookup > /dev/null 2>&1; then
    return 0
  fi
  
  info "尝试自动登录..."
  
  # 方式1：检查 ~/.vault-token 文件
  if [ -f "$HOME/.vault-token" ]; then
    TOKEN=$(cat "$HOME/.vault-token" 2>/dev/null)
    if [ -n "$TOKEN" ] && vault login "$TOKEN" > /dev/null 2>&1; then
      success "通过 ~/.vault-token 自动登录成功"
      return 0
    fi
  fi
  
  # 方式2：检查 /root/.vault_keys 文件
  KEYS_FILE="/root/.vault_keys"
  if [ -f "$KEYS_FILE" ]; then
    TOKEN=$(grep "Root Token:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
    if [ -n "$TOKEN" ] && vault login "$TOKEN" > /dev/null 2>&1; then
      success "通过 .vault_keys 自动登录成功"
      return 0
    fi
  fi
  
  # 方式3：手动输入
  warn "无法自动获取 Token，请手动输入"
  read -p "请输入 Root Token: " TOKEN
  if [ -z "$TOKEN" ]; then
    error "Token 不能为空"
  fi
  vault login "$TOKEN" > /dev/null 2>&1 || error "登录失败"
}

# -------- 创建 admin 超管策略 --------
create_admin_policy() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  info "创建 admin 超管策略..."
  
  # 自动登录
  auto_login_vault
  
  # 创建 admin policy（完全超管权限）
  cat > /tmp/admin-policy.hcl << 'EOF'
# Admin 超管策略 - 拥有所有权限
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

  vault policy write admin /tmp/admin-policy.hcl
  rm -f /tmp/admin-policy.hcl
  
  success "admin 策略创建成功"
  echo ""
  echo -e "${YELLOW}使用方法：${NC}"
  echo -e "  # 创建使用 admin 策略的 Token"
  echo -e "  vault token create -policy=admin"
  echo ""
  echo -e "  # 或创建 userpass 用户并绑定 admin 策略"
  echo -e "  vault auth enable userpass"
  echo -e "  vault write auth/userpass/users/admin password=<密码> policies=admin"
  echo ""
}

# -------- 创建管理员用户 --------
create_admin_user() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  info "创建管理员用户..."
  
  # 自动登录
  auto_login_vault
  
  # 确保 admin 策略存在
  if ! vault policy read admin > /dev/null 2>&1; then
    warn "admin 策略不存在，正在创建..."
    cat > /tmp/admin-policy.hcl << 'EOF'
# Admin 超管策略 - 拥有所有权限
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
    vault policy write admin /tmp/admin-policy.hcl > /dev/null 2>&1
    rm -f /tmp/admin-policy.hcl
    success "admin 策略已创建"
  fi
  
  # 启用 userpass 认证（如果未启用）
  if ! vault auth list 2>/dev/null | grep -q "userpass/"; then
    info "启用 userpass 认证方式..."
    vault auth enable userpass > /dev/null 2>&1
    success "userpass 认证已启用"
  fi
  
  echo ""
  echo -e "${YELLOW}创建管理员账户${NC}"
  echo ""
  
  # 输入用户名
  read -p "请输入用户名 (默认: admin): " ADMIN_USER
  ADMIN_USER=${ADMIN_USER:-admin}
  
  # 检查用户是否已存在
  if vault read auth/userpass/users/"$ADMIN_USER" > /dev/null 2>&1; then
    echo ""
    warn "用户 '$ADMIN_USER' 已存在"
    echo -e "  ${BLUE}[1]${NC} 更新密码"
    echo -e "  ${BLUE}[2]${NC} 取消操作"
    echo ""
    read -p "请选择 [1/2]: " UPDATE_CHOICE
    
    if [ "$UPDATE_CHOICE" != "1" ]; then
      info "操作已取消"
      return
    fi
  fi
  
  # 输入密码
  while true; do
    read -sp "请输入密码: " ADMIN_PASS
    echo ""
    
    if [ -z "$ADMIN_PASS" ]; then
      warn "密码不能为空，请重新输入"
      continue
    fi
    
    if [ ${#ADMIN_PASS} -lt 6 ]; then
      warn "密码长度至少 6 位，请重新输入"
      continue
    fi
    
    read -sp "请确认密码: " ADMIN_PASS_CONFIRM
    echo ""
    
    if [ "$ADMIN_PASS" != "$ADMIN_PASS_CONFIRM" ]; then
      warn "两次密码不一致，请重新输入"
      continue
    fi
    
    break
  done
  
  # 创建用户
  vault write auth/userpass/users/"$ADMIN_USER" \
    password="$ADMIN_PASS" \
    policies="admin" > /dev/null 2>&1
  
  if [ $? -eq 0 ]; then
    echo ""
    success "管理员用户创建成功！"
    echo ""
    echo -e "${YELLOW}账户信息：${NC}"
    echo -e "  用户名：${BLUE}$ADMIN_USER${NC}"
    echo -e "  策略：${BLUE}admin（超管权限）${NC}"
    echo ""
    echo -e "${YELLOW}登录方式：${NC}"
    echo -e "  # 命令行登录"
    echo -e "  vault login -method=userpass username=$ADMIN_USER"
    echo ""
    echo -e "  # API 登录"
    echo -e "  curl -X POST \$VAULT_ADDR/v1/auth/userpass/login/$ADMIN_USER -d '{\"password\":\"<密码>\"}'"
    echo ""
  else
    error "用户创建失败"
  fi
}

# -------- 配置 CORS 跨域支持 --------
setup_cors() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  info "配置 CORS 跨域支持..."
  
  # 自动登录
  auto_login_vault
  
  echo ""
  echo -e "${YELLOW}CORS 配置选项：${NC}"
  echo -e "  ${BLUE}[1]${NC} 允许所有来源（开发环境推荐）"
  echo -e "  ${BLUE}[2]${NC} 指定允许的域名（生产环境推荐）"
  echo -e "  ${BLUE}[3]${NC} 禁用 CORS"
  echo ""
  read -p "请选择 [1/2/3] (默认: 1): " CORS_CHOICE
  CORS_CHOICE=${CORS_CHOICE:-1}
  
  case $CORS_CHOICE in
    1)
      vault write sys/config/cors \
        allowed_origins="*" \
        allowed_headers="X-Vault-Token,Content-Type,Authorization"
      success "CORS 已配置：允许所有来源"
      ;;
    2)
      read -p "请输入允许的域名（多个用逗号分隔，如 https://example.com,https://app.example.com）: " CORS_ORIGINS
      if [ -z "$CORS_ORIGINS" ]; then
        error "域名不能为空"
      fi
      vault write sys/config/cors \
        allowed_origins="$CORS_ORIGINS" \
        allowed_headers="X-Vault-Token,Content-Type,Authorization"
      success "CORS 已配置：$CORS_ORIGINS"
      ;;
    3)
      vault delete sys/config/cors
      success "CORS 已禁用"
      ;;
    *)
      warn "无效选择"
      return
      ;;
  esac
  
  echo ""
  info "当前 CORS 配置："
  vault read sys/config/cors 2>/dev/null || echo "  (无配置)"
  echo ""
}

# -------- 查看 Vault 状态 --------
show_status() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  echo ""
  echo -e "${YELLOW}Vault 服务状态：${NC}"
  systemctl status vault --no-pager -l 2>/dev/null | head -20 || echo "  服务未安装"
  
  echo ""
  echo -e "${YELLOW}Vault 健康检查：${NC}"
  HEALTH=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null)
  if [ -n "$HEALTH" ]; then
    echo "$HEALTH" | jq . 2>/dev/null || echo "$HEALTH"
  else
    echo "  无法连接到 Vault"
  fi
  echo ""
}

# -------- 执行安装/升级 --------
do_install() {
  check_root
  check_system
  install_deps
  get_latest_version
  install_vault
  setup_dirs
  write_config
  setup_systemd
  init_vault
  setup_unseal_script
  setup_firewall
  print_summary
}

# -------- 显示主菜单 --------
show_menu() {
  echo ""
  echo -e "${GREEN}============================================${NC}"
  echo -e "${GREEN}   HashiCorp Vault 管理工具${NC}"
  echo -e "${GREEN}============================================${NC}"
  echo ""
  echo -e "  ${BLUE}[1]${NC} 安装 / 升级 Vault"
  echo -e "  ${BLUE}[2]${NC} 解封 Vault"
  echo -e "  ${BLUE}[3]${NC} 创建 admin 超管策略"
  echo -e "  ${BLUE}[4]${NC} 添加管理员用户"
  echo -e "  ${BLUE}[5]${NC} 配置 CORS 跨域支持"
  echo -e "  ${BLUE}[6]${NC} 查看 Vault 状态"
  echo -e "  ${BLUE}[0]${NC} 退出"
  echo ""
}

# -------- 手动解封菜单 --------
menu_unseal() {
  export VAULT_ADDR="http://127.0.0.1:$VAULT_PORT"
  
  echo ""
  info "Vault 解封操作"
  
  # 检查当前状态
  HEALTH=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null)
  if [ -z "$HEALTH" ]; then
    error "无法连接到 Vault 服务，请确认服务已启动"
  fi
  
  SEALED=$(echo "$HEALTH" | jq -r '.sealed' 2>/dev/null)
  
  if [ "$SEALED" = "false" ]; then
    success "Vault 当前已解封，无需操作"
    echo ""
    return
  fi
  
  echo -e "${YELLOW}Vault 当前处于密封状态${NC}"
  echo ""
  echo -e "  ${BLUE}[1]${NC} 自动解封（从 .vault_keys 读取）"
  echo -e "  ${BLUE}[2]${NC} 手动输入 Unseal Keys"
  echo ""
  read -p "请选择 [1/2] (默认: 1): " UNSEAL_CHOICE
  UNSEAL_CHOICE=${UNSEAL_CHOICE:-1}
  
  case $UNSEAL_CHOICE in
    1)
      # 自动解封
      KEYS_FILE="/root/.vault_keys"
      if [ ! -f "$KEYS_FILE" ]; then
        error "密钥文件 $KEYS_FILE 不存在，请使用手动解封"
      fi
      
      KEY1=$(grep "Unseal Key 1:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
      KEY2=$(grep "Unseal Key 2:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
      KEY3=$(grep "Unseal Key 3:" "$KEYS_FILE" 2>/dev/null | awk '{print $NF}')
      
      if [ -z "$KEY1" ] || [ -z "$KEY2" ] || [ -z "$KEY3" ]; then
        error "无法从密钥文件读取 Unseal Keys"
      fi
      
      info "正在解封..."
      vault operator unseal "$KEY1" > /dev/null 2>&1
      vault operator unseal "$KEY2" > /dev/null 2>&1
      vault operator unseal "$KEY3" > /dev/null 2>&1
      ;;
    2)
      # 手动输入
      info "请输入 3 个 Unseal Keys（需要 5 个中的任意 3 个）"
      echo ""
      read -p "Unseal Key 1: " KEY1
      vault operator unseal "$KEY1" 2>&1 | grep -E "(Sealed|Progress)"
      
      read -p "Unseal Key 2: " KEY2
      vault operator unseal "$KEY2" 2>&1 | grep -E "(Sealed|Progress)"
      
      read -p "Unseal Key 3: " KEY3
      vault operator unseal "$KEY3" 2>&1 | grep -E "(Sealed|Progress)"
      ;;
    *)
      warn "无效选择"
      return
      ;;
  esac
  
  # 验证结果
  echo ""
  SEALED=$(curl -s "$VAULT_ADDR/v1/sys/health" 2>/dev/null | jq -r '.sealed' 2>/dev/null)
  if [ "$SEALED" = "false" ]; then
    success "Vault 解封成功！"
  else
    error "解封失败，请检查 Unseal Keys 是否正确"
  fi
  echo ""
}

# -------- 主流程 --------
main() {
  while true; do
    show_menu
    read -p "请选择操作 [0-6]: " MENU_CHOICE
    
    case $MENU_CHOICE in
      1)
        do_install
        ;;
      2)
        check_root
        menu_unseal
        ;;
      3)
        check_root
        create_admin_policy
        ;;
      4)
        check_root
        create_admin_user
        ;;
      5)
        check_root
        setup_cors
        ;;
      6)
        show_status
        ;;
      0)
        echo ""
        info "再见！"
        exit 0
        ;;
      *)
        warn "无效选择，请重新输入"
        ;;
    esac
    
    echo ""
    read -p "按 Enter 返回主菜单..." _
  done
}

main "$@"
