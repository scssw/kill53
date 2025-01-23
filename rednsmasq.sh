#!/bin/bash

# 创建新的 dnsmasq.conf 内容
cat <<EOF | sudo tee /etc/dnsmasq.conf > /dev/null
# 禁止测速
address=/fast.com/127.0.0.1
address=/.fast.com/127.0.0.1

# Netflix 专用 DNS
server=/netflix.ca/5.231.70.121
server=/netflix.com/5.231.70.121
server=/netflix.net/5.231.70.121
server=/netflixinvestor.com/5.231.70.121
server=/netflixtechblog.com/5.231.70.121
server=/nflxext.com/5.231.70.121
server=/nflximg.com/5.231.70.121
server=/nflximg.net/5.231.70.121
server=/nflxsearch.net/5.231.70.121
server=/nflxso.net/5.231.70.121
server=/nflxvideo.net/5.231.70.121
server=/netflixdnstest0.com/5.231.70.121
server=/netflixdnstest1.com/5.231.70.121
server=/netflixdnstest2.com/5.231.70.121
server=/netflixdnstest3.com/5.231.70.121
server=/netflixdnstest4.com/5.231.70.121
server=/netflixdnstest5.com/5.231.70.121
server=/netflixdnstest6.com/5.231.70.121
server=/netflixdnstest7.com/5.231.70.121
server=/netflixdnstest8.com/5.231.70.121
server=/netflixdnstest9.com/5.231.70.121
server=/cinemax.com/5.231.70.121
server=/forthethrone.com/5.231.70.121

# 迪士尼+ 域名通过解锁 DNS 解析
server=/disneyplus.com/5.231.70.121
server=/dssott.com/5.231.70.121
server=/bamgrid.com/5.231.70.121
server=/akamaized.net/5.231.70.121

# Gemini DNS解锁
server=/gemini.google.com/5.231.70.121
server=/proactivebackend-pa.googleapis.com/5.231.70.121
server=/alkalimakersuite-pa.clients6.google.com/5.231.70.121
server=/aistudio.google.com/5.231.70.121
server=/generativelanguage.googleapis.com/5.231.70.121

# 其他域名通过 Google DNS 解析
server=8.8.8.8
server=1.1.1.1


# 配置目录
conf-dir=/etc/dnsmasq.d
EOF

# 重启 dnsmasq 服务
sudo systemctl restart dnsmasq

echo "dnsmasq 配置已替换并生效！"
