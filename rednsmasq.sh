#!/bin/bash

# 创建新的 dnsmasq.conf 内容
cat <<EOF | sudo tee /etc/dnsmasq.conf > /dev/null
# 禁止测速
address=/fast.com/127.0.0.1
address=/.fast.com/127.0.0.1

# Netflix 专用 DNS
server=/netflix.ca/45.39.199.32
server=/netflix.com/45.39.199.32
server=/netflix.net/45.39.199.32
server=/netflixinvestor.com/45.39.199.32
server=/netflixtechblog.com/45.39.199.32
server=/nflxext.com/45.39.199.32
server=/nflximg.com/45.39.199.32
server=/nflximg.net/45.39.199.32
server=/nflxsearch.net/45.39.199.32
server=/nflxso.net/45.39.199.32
server=/nflxvideo.net/45.39.199.32
server=/netflixdnstest0.com/45.39.199.32
server=/netflixdnstest1.com/45.39.199.32
server=/netflixdnstest2.com/45.39.199.32
server=/netflixdnstest3.com/45.39.199.32
server=/netflixdnstest4.com/45.39.199.32
server=/netflixdnstest5.com/45.39.199.32
server=/netflixdnstest6.com/45.39.199.32
server=/netflixdnstest7.com/45.39.199.32
server=/netflixdnstest8.com/45.39.199.32
server=/netflixdnstest9.com/45.39.199.32
server=/cinemax.com/45.39.199.32
server=/forthethrone.com/45.39.199.32

# 迪士尼+ 域名通过解锁 DNS 解析
server=/disneyplus.com/45.39.199.32
server=/dssott.com/45.39.199.32
server=/bamgrid.com/45.39.199.32
server=/akamaized.net/45.39.199.32

# 其他域名通过 Google DNS 解析
server=8.8.8.8
server=1.1.1.1

# 配置目录
conf-dir=/etc/dnsmasq.d
EOF

# 重启 dnsmasq 服务
sudo systemctl restart dnsmasq

echo "dnsmasq 配置已替换并生效！"
