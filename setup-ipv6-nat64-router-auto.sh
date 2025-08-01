#!/bin/bash
set -e

echo "=== Arch Linux IPv6-only PPPoE 主路由自动部署脚本 ==="

### 变量区（请修改 PPPoE 用户密码，其他一般不用改） ###
LAN_IPV4=192.168.0.1
LAN_SUBNET=192.168.0.0/24
LAN_IFACE=br0
LAN_MEMBERS=("eth0" "eth2" "eth3")
WAN_IFACE=eth1
PPPOE_USER="your_pppoe_user"
PPPOE_PASS="your_pppoe_password"

echo "[1/10] 安装必要软件..."
pacman -Syu --noconfirm
pacman -S --noconfirm ppp rp-pppoe bridge-utils systemd-networkd systemd-resolved unbound nftables base-devel dkms

if ! command -v yay >/dev/null 2>&1; then
  echo "请先安装 AUR 辅助工具 yay，再重新运行此脚本。"
  exit 1
fi
yay -S --noconfirm jool-dkms firewall4

echo "[2/10] 启用系统服务 systemd-networkd, systemd-resolved..."
systemctl enable --now systemd-networkd
systemctl enable --now systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "[3/10] 创建桥接接口配置..."
cat >/etc/systemd/network/br0.netdev <<EOF
[NetDev]
Name=br0
Kind=bridge
EOF

cat >/etc/systemd/network/br0.network <<EOF
[Match]
Name=br0

[Network]
Address=${LAN_IPV4}/24
IPv6SendRA=yes
DHCPServer=yes

[DHCPServer]
EmitRouterAdvertisements=yes
DNS=${LAN_IPV4}
EOF

for iface in "${LAN_MEMBERS[@]}"; do
cat >/etc/systemd/network/${iface}.network <<EOF
[Match]
Name=${iface}

[Network]
Bridge=${LAN_IFACE}
EOF
done

echo "[4/10] 配置 PPPoE 拨号..."
mkdir -p /etc/ppp/peers

cat >/etc/ppp/peers/pppoe <<EOF
plugin rp-pppoe.so ${WAN_IFACE}
noipv4
ipv6 ,
user "${PPPOE_USER}"
noauth
defaultroute
usepeerdns
persist
EOF

cat >/etc/ppp/pap-secrets <<EOF
"${PPPOE_USER}" * "${PPPOE_PASS}"
EOF
chmod 600 /etc/ppp/pap-secrets

cat >/etc/systemd/system/pppoe.service <<EOF
[Unit]
Description=PPPoE IPv6 Connection
After=network.target

[Service]
ExecStart=/usr/bin/pppd call pppoe
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now pppoe.service

echo "[5/10] 等待 PPPoE 拨号接口 ppp0 up 并获取 IPv6 PD..."

for i in {1..30}; do
  if ip -6 route show dev ppp0 | grep -q '/6[04]'; then
    break
  fi
  echo "等待第 $i 秒：ppp0 获取 IPv6 PD 中..."
  sleep 1
done

PREFIX60=$(ip -6 route show dev ppp0 | grep -E '/6[04]' | grep -oE '([0-9a-f:]+:+)+/[6][04]' | head -n1)

if [[ -z "$PREFIX60" ]]; then
  echo "❌ 错误：未检测到 PPPoE 接口 ppp0 上的 IPv6 前缀，请确认运营商是否支持 DHCPv6-PD。"
  exit 1
fi

echo "✅ 探测到 IPv6 PD 前缀：$PREFIX60"

# 自动推导第一个 /64 子网
LAN_IPV6_PREFIX64=$(echo "$PREFIX60" | sed 's|/60|/64|')

echo "✅ 使用 LAN IPv6 /64 子网：$LAN_IPV6_PREFIX64"

echo "[6/10] 修改 LAN 桥接接口配置添加 IPv6 地址..."

sed -i "/\[Network\]/a Address=${LAN_IPV6_PREFIX64}" /etc/systemd/network/br0.network

echo "[7/10] 开启内核转发..."

cat >/etc/sysctl.d/forwarding.conf <<EOF
net.ipv6.conf.all.forwarding = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

echo "[8/10] 配置并启动 Jool NAT64..."

modprobe jool

cat >/usr/local/bin/jool-init.sh <<EOF
#!/bin/bash
modprobe jool
jool instance add "main" --netfilter --pool6 64:ff9b::/96
jool -i main pool4 add --dynamic 192.168.255.0/24
jool -i main nat64 enable
EOF
chmod +x /usr/local/bin/jool-init.sh

cat >/etc/systemd/system/jool-init.service <<EOF
[Unit]
Description=Jool NAT64 Initialization
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/jool-init.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now jool-init.service

echo "[9/10] 配置 Unbound DNS64..."

cat >/etc/unbound/unbound.conf <<EOF
server:
    interface: ${LAN_IPV4}
    access-control: ${LAN_SUBNET} allow
    do-ip6: yes
    do-ip4: yes
    prefer-ip6: yes

    module-config: "dns64 validator iterator"
    dns64-prefix: 64:ff9b::/96

    forward-zone:
        name: "."
        forward-addr: 2001:4860:4860::8888
        forward-addr: 2606:4700:4700::1111
EOF

systemctl enable --now unbound

echo "[10/10] 配置 firewall4 防火墙..."

mkdir -p /etc/firewall4

cat >/etc/firewall4/config <<EOF
config interface 'lan'
	option device 'br0'
	option proto 'static'
	option ipaddr '${LAN_IPV4}'
	option netmask '255.255.255.0'

config interface 'wan'
	option device 'ppp0'
	option proto 'none'

config zone
	option name 'lan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'
	option network 'lan'

config zone
	option name 'wan'
	option input 'DROP'
	option output 'ACCEPT'
	option forward 'DROP'
	option masq '1'
	option mtu_fix '1'
	option network 'wan'

config forwarding
	option src 'lan'
	option dest 'wan'
EOF

systemctl enable --now firewall4

echo -e "\n🎉 完成！\n请连接 LAN 设备测试 IPv6 地址和 IPv4 NAT64 通畅。\n"