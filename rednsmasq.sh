#!/bin/bash

# 创建新的 dnsmasq.conf 内容
cat <<EOF | sudo tee /etc/dnsmasq.conf > /dev/null
# 禁止测速
address=/fast.com/127.0.0.1
address=/.fast.com/127.0.0.1

# Netflix 专用 DNS
server=/netflix.ca/107.173.39.53
server=/netflix.com/107.173.39.53
server=/netflix.net/107.173.39.53
server=/netflixinvestor.com/107.173.39.53
server=/netflixtechblog.com/107.173.39.53
server=/nflxext.com/107.173.39.53
server=/nflximg.com/107.173.39.53
server=/nflximg.net/107.173.39.53
server=/nflxsearch.net/107.173.39.53
server=/nflxso.net/107.173.39.53
server=/nflxvideo.net/107.173.39.53
server=/netflixdnstest0.com/107.173.39.53
server=/netflixdnstest1.com/107.173.39.53
server=/netflixdnstest2.com/107.173.39.53
server=/netflixdnstest3.com/107.173.39.53
server=/netflixdnstest4.com/107.173.39.53
server=/netflixdnstest5.com/107.173.39.53
server=/netflixdnstest6.com/107.173.39.53
server=/netflixdnstest7.com/107.173.39.53
server=/netflixdnstest8.com/107.173.39.53
server=/netflixdnstest9.com/107.173.39.53
server=/cinemax.com/107.173.39.53
server=/forthethrone.com/107.173.39.53

# 迪士尼+ 域名通过解锁 DNS 解析
server=/disneyplus.com/107.173.39.53
server=/dssott.com/107.173.39.53
server=/bamgrid.com/107.173.39.53
server=/akamaized.net/107.173.39.53

# Gemini DNS解锁
server=/gemini.google.com/107.173.39.53
server=/proactivebackend-pa.googleapis.com/107.173.39.53
server=/alkalimakersuite-pa.clients6.google.com/107.173.39.53
server=/aistudio.google.com/107.173.39.53
server=/generativelanguage.googleapis.com/107.173.39.53

# 其他域名通过 Google DNS 解析
server=8.8.8.8
server=1.1.1.1


# 配置目录
conf-dir=/etc/dnsmasq.d
EOF

# 重启 dnsmasq 服务
sudo systemctl restart dnsmasq

echo "dnsmasq 配置已替换并生效！"
