#!/bin/bash

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
   echo "此脚本必须以root用户运行" 
   exit 1
fi

echo "开始安装nftables-nat-rust..."

# 检测系统类型
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu系统
    echo "检测到Debian/Ubuntu系统"
    apt-get update
    apt-get install -y nftables curl
    systemctl stop ufw
    systemctl disable ufw
    systemctl stop iptables
    systemctl disable iptables
else
    # CentOS/RHEL系统
    echo "检测到CentOS/RHEL系统"
    # 关闭firewalld
    systemctl stop firewalld
    systemctl disable firewalld
    # 安装nftables
    yum install -y nftables curl
fi

# 关闭selinux
setenforce 0 2>/dev/null
if [ -f /etc/selinux/config ]; then
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config
fi

# 开启端口转发
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
    curl -sSLf https://us.arloor.dev/https://github.com/arloor/nftables-nat-rust/releases/download/v1.0.0/dnat -o /tmp/nat
}
install /tmp/nat /usr/local/bin/nat

# 创建必要的目录和文件
mkdir -p /opt/nat
touch /opt/nat/env

# 创建systemd服务
echo "创建systemd服务..."
cat > /lib/systemd/system/nat.service <<EOF
[Unit]
Description=dnat-service
After=network-online.target
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
echo "# 端口转发配置文件" > /etc/nat.conf

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
    fi
    
    read -p "是否继续添加转发规则？[y/N]: " continue_add
    if [[ ! "$continue_add" =~ ^[Yy]$ ]]; then
        break
    fi
    
    read -p "请选择转发类型 [1/2]: " forward_type
done

# 设置服务开机启动
echo "设置服务..."
systemctl daemon-reload
systemctl enable nat
systemctl start nat

echo "安装完成！"
echo "当前转发规则如下："
cat /etc/nat.conf
echo ""
echo "你可以使用以下命令管理服务："
echo "  systemctl status nat  # 查看服务状态"
echo "  systemctl restart nat # 重启服务"
echo "  systemctl stop nat    # 停止服务"
echo "  cat /opt/nat/nat.log  # 查看日志"
echo "  vim /etc/nat.conf     # 编辑转发规则" 