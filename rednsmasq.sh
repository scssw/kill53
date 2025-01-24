#!/bin/bash

# 创建新的 dnsmasq.conf 内容
cat <<EOF | sudo tee /etc/dnsmasq.conf > /dev/null
# 禁止测速
address=/fast.com/127.0.0.1
address=/.fast.com/127.0.0.1

# Netflix 专用 DNS
server=/netflix.ca/109.176.203.10
server=/netflix.com/109.176.203.10
server=/netflix.net/109.176.203.10
server=/netflixinvestor.com/109.176.203.10
server=/netflixtechblog.com/109.176.203.10
server=/nflxext.com/109.176.203.10
server=/nflximg.com/109.176.203.10
server=/nflximg.net/109.176.203.10
server=/nflxsearch.net/109.176.203.10
server=/nflxso.net/109.176.203.10
server=/nflxvideo.net/109.176.203.10
server=/netflixdnstest0.com/109.176.203.10
server=/netflixdnstest1.com/109.176.203.10
server=/netflixdnstest2.com/109.176.203.10
server=/netflixdnstest3.com/109.176.203.10
server=/netflixdnstest4.com/109.176.203.10
server=/netflixdnstest5.com/109.176.203.10
server=/netflixdnstest6.com/109.176.203.10
server=/netflixdnstest7.com/109.176.203.10
server=/netflixdnstest8.com/109.176.203.10
server=/netflixdnstest9.com/109.176.203.10
server=/cinemax.com/109.176.203.10
server=/forthethrone.com/109.176.203.10

# 迪士尼+ 域名通过解锁 DNS 解析
server=/disneyplus.com/109.176.203.10
server=/dssott.com/109.176.203.10
server=/bamgrid.com/109.176.203.10
server=/akamaized.net/109.176.203.10

# Gemini DNS解锁
server=/gemini.google.com/142.171.209.200
server=/proactivebackend-pa.googleapis.com/142.171.209.200
server=/alkalimakersuite-pa.clients6.google.com/142.171.209.200
server=/aistudio.google.com/142.171.209.200
server=/generativelanguage.googleapis.com/142.171.209.200

# 其他域名通过 Google DNS 解析
server=8.8.8.8
server=1.1.1.1


# 配置目录
conf-dir=/etc/dnsmasq.d
EOF

# 重启 dnsmasq 服务
sudo systemctl restart dnsmasq

echo "dnsmasq 配置已替换并生效！"
