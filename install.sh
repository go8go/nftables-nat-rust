#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root用户运行" 
   exit 1
fi

echo "开始安装nftables-nat-rust..."

# 清理可能存在的包管理器锁
cleanup_locks() {
    echo "清理包管理器锁..."
    rm -f /var/lib/rpm/.rpm.lock
    rm -f /var/lib/rpm/__db.*
    rm -f /var/lib/dpkg/lock*
    rm -f /var/cache/apt/archives/lock
    rm -f /var/lib/apt/lists/lock
    killall -9 yum dnf apt-get 2>/dev/null || true
}

# 检测系统类型
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu系统
    echo "检测到Debian/Ubuntu系统"
    cleanup_locks
    apt-get update || { echo "apt-get update 失败，请检查网络或手动运行: apt-get update"; exit 1; }
    apt-get install -y nftables curl || { echo "安装软件包失败，请检查系统状态"; exit 1; }
    systemctl stop ufw || true
    systemctl disable ufw || true
    systemctl stop iptables || true
    systemctl disable iptables || true
else
    # CentOS/RHEL系统
    echo "检测到CentOS/RHEL系统"
    # 关闭firewalld
    systemctl stop firewalld || true
    systemctl disable firewalld || true
    # 清理并安装nftables
    cleanup_locks
    yum clean all
    rm -rf /var/cache/yum
    yum install -y nftables curl || { echo "安装软件包失败，请检查系统状态"; exit 1; }
fi

# 启动nftables服务
echo "启动nftables服务..."
systemctl start nftables || true
systemctl enable nftables || true

# 关闭selinux
echo "配置SELinux..."
setenforce 0 2>/dev/null || true
if [ -f /etc/selinux/config ]; then
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
fi

# 开启端口转发
echo "配置端口转发..."
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i '/^net.ipv4.ip_forward=0/'d /etc/sysctl.conf
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

# 下载最新版本的nat程序
echo "下载nat程序..."
curl -sSLf https://github.com/arloor/nftables-nat-rust/releases/download/v1.0.0/dnat -o /tmp/nat || {
    echo "下载失败，尝试备用地址..."
    curl -sSLf https://us.arloor.dev/https://github.com/arloor/nftables-nat-rust/releases/download/v1.0.0/dnat -o /tmp/nat || {
        echo "下载nat程序失败，请检查网络连接"
        exit 1
    }
}
install /tmp/nat /usr/local/bin/nat || { echo "安装nat程序失败"; exit 1; }

# 创建必要的目录和文件
echo "创建必要的目录和文件..."
mkdir -p /opt/nat || { echo "创建目录失败"; exit 1; }
touch /opt/nat/env || { echo "创建env文件失败"; exit 1; }

# 创建systemd服务
echo "创建systemd服务..."
cat > /lib/systemd/system/nat.service <<EOF || { echo "创建服务文件失败"; exit 1; }
[Unit]
Description=dnat-service
After=network-online.target nftables.service
Wants=network-online.target

[Service]
WorkingDirectory=/opt/nat
EnvironmentFile=/opt/nat/env
ExecStart=/usr/local/bin/nat /etc/nat.conf
LimitNOFILE=100000
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF

# 交互式配置转发规则
echo "开始配置转发规则..."
echo "请选择转发类型："
echo "1) 单端口转发 (SINGLE)"
echo "2) 端口范围转发 (RANGE)"
read -p "请输入选择 [1/2]: " forward_type

# 创建配置文件
echo "# 端口转发配置文件" > /etc/nat.conf || { echo "创建配置文件失败"; exit 1; }

configure_and_test_rule() {
    local first_rule=true
    while true; do
        if [ "$forward_type" == "1" ]; then
            read -p "请输入本地端口: " local_port
            read -p "请输入目标端口: " remote_port
            read -p "请输入目标地址(域名或IP): " target_addr
            read -p "是否指定协议(tcp/udp)？留空则同时转发TCP和UDP [tcp/udp/]: " protocol
            
            if [ -n "$protocol" ]; then
                echo "SINGLE,$local_port,$remote_port,$target_addr,$protocol" >> /etc/nat.conf
            else
                echo "SINGLE,$local_port,$remote_port,$target_addr" >> /etc/nat.conf
            fi
            
            # 如果是第一条规则，进行测试
            if [ "$first_rule" = true ]; then
                echo "正在应用第一条规则并测试..."
                
                # 启动服务
                systemctl daemon-reload || { echo "重载systemd失败"; exit 1; }
                systemctl enable nat || { echo "设置开机启动失败"; exit 1; }
                systemctl start nat || { echo "启动服务失败"; exit 1; }
                
                # 等待服务启动
                sleep 2
                
                # 检查服务状态
                if ! systemctl is-active nat >/dev/null 2>&1; then
                    echo "警告: nat服务未能正常启动，请检查日志:"
                    journalctl -u nat --no-pager -n 50
                    echo "是否继续配置？[y/N]"
                    read -p "输入y继续，输入其他退出: " continue_config
                    if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
                        exit 1
                    fi
                fi
                
                # 检查nftables规则
                echo "当前nftables规则："
                nft list ruleset
                
                # 检查端口是否已经开启监听
                echo "检查端口状态："
                if command -v netstat >/dev/null 2>&1; then
                    netstat -tunlp | grep "$local_port"
                elif command -v ss >/dev/null 2>&1; then
                    ss -tunlp | grep "$local_port"
                fi
                
                echo "规则已应用，请测试端口转发是否生效..."
                echo "您可以使用以下命令测试："
                echo "  curl -v telnet://$target_addr:$remote_port"
                echo "  nc -zv $target_addr $remote_port"
                
                read -p "转发规则是否正常工作？[y/N]: " rule_works
                if [[ ! "$rule_works" =~ ^[Yy]$ ]]; then
                    echo "请检查以下内容："
                    echo "1. 查看服务日志: journalctl -u nat -f"
                    echo "2. 检查目标地址是否可访问: ping $target_addr"
                    echo "3. 检查nftables规则: nft list ruleset"
                    echo "4. 检查防火墙状态"
                    exit 1
                fi
            fi
            first_rule=false
        else
            read -p "请输入本地起始端口: " local_start_port
            read -p "请输入本地结束端口: " local_end_port
            read -p "请输入目标地址(域名或IP): " target_addr
            read -p "是否指定协议(tcp/udp)？留空则同时转发TCP和UDP [tcp/udp/]: " protocol
            
            if [ -n "$protocol" ]; then
                echo "RANGE,$local_start_port,$local_end_port,$target_addr,$protocol" >> /etc/nat.conf
            else
                echo "RANGE,$local_start_port,$local_end_port,$target_addr" >> /etc/nat.conf
            fi
            
            # 如果是第一条规则，进行测试
            if [ "$first_rule" = true ]; then
                echo "正在应用第一条规则并测试..."
                systemctl daemon-reload || { echo "重载systemd失败"; exit 1; }
                systemctl enable nat || { echo "设置开机启动失败"; exit 1; }
                systemctl start nat || { echo "启动服务失败"; exit 1; }
                
                # 等待服务启动
                sleep 2
                
                # 检查服务状态
                if ! systemctl is-active nat >/dev/null 2>&1; then
                    echo "警告: nat服务未能正常启动，请检查日志:"
                    journalctl -u nat --no-pager -n 50
                    echo "是否继续配置？[y/N]"
                    read -p "输入y继续，输入其他退出: " continue_config
                    if [[ ! "$continue_config" =~ ^[Yy]$ ]]; then
                        exit 1
                    fi
                fi
                
                # 检查nftables规则
                echo "当前nftables规则："
                nft list ruleset
                
                echo "规则已应用，请测试端口转发是否生效..."
                read -p "转发规则是否正常工作？[y/N]: " rule_works
                if [[ ! "$rule_works" =~ ^[Yy]$ ]]; then
                    echo "请检查以下内容："
                    echo "1. 查看服务日志: journalctl -u nat -f"
                    echo "2. 检查目标地址是否可访问: ping $target_addr"
                    echo "3. 检查nftables规则: nft list ruleset"
                    echo "4. 检查防火墙状态"
                    exit 1
                fi
            fi
            first_rule=false
        fi
        
        read -p "是否继续添加转发规则？[y/N]: " continue_add
        if [[ ! "$continue_add" =~ ^[Yy]$ ]]; then
            break
        fi
        
        read -p "请选择转发类型 [1/2]: " forward_type
    done
}

# 运行配置和测试函数
configure_and_test_rule

echo "安装完成！"
echo "当前转发规则如下："
cat /etc/nat.conf
echo ""
echo "你可以使用以下命令管理服务："
echo "  systemctl status nat  # 查看服务状态"
echo "  systemctl restart nat # 重启服务"
echo "  systemctl stop nat    # 停止服务"
echo "  cat /opt/nat/nat.log  # 查看日志"
echo "  journalctl -u nat -f  # 实时查看服务日志"
echo "  nft list ruleset      # 查看当前nftables规则"
echo "  vim /etc/nat.conf     # 编辑转发规则" 