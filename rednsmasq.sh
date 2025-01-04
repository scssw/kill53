#!/bin/bash

# 创建新的 dnsmasq.conf 内容
cat <<EOF | sudo tee /etc/dnsmasq.conf > /dev/null
# 禁止测速
address=/fast.com/127.0.0.1
address=/.fast.com/127.0.0.1

# Netflix 专用 DNS
server=/netflix.ca/156.229.167.246
server=/netflix.com/156.229.167.246
server=/netflix.net/156.229.167.246
server=/netflixinvestor.com/156.229.167.246
server=/netflixtechblog.com/156.229.167.246
server=/nflxext.com/156.229.167.246
server=/nflximg.com/156.229.167.246
server=/nflximg.net/156.229.167.246
server=/nflxsearch.net/156.229.167.246
server=/nflxso.net/156.229.167.246
server=/nflxvideo.net/156.229.167.246
server=/netflixdnstest0.com/156.229.167.246
server=/netflixdnstest1.com/156.229.167.246
server=/netflixdnstest2.com/156.229.167.246
server=/netflixdnstest3.com/156.229.167.246
server=/netflixdnstest4.com/156.229.167.246
server=/netflixdnstest5.com/156.229.167.246
server=/netflixdnstest6.com/156.229.167.246
server=/netflixdnstest7.com/156.229.167.246
server=/netflixdnstest8.com/156.229.167.246
server=/netflixdnstest9.com/156.229.167.246
server=/cinemax.com/156.229.167.246
server=/forthethrone.com/156.229.167.246
# ChatGPT DNS解锁
server=/openai.com/156.229.167.246
server=/chatgpt.com/156.229.167.246
server=/chat.com/156.229.167.246
server=/oaistatic.com/156.229.167.246
server=/oaiusercontent.com/156.229.167.246
server=/chat.comopenai.com.cdn.cloudflare.net/156.229.167.246
server=/openaiapi-site.azureedge.net/156.229.167.246
server=/openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net/156.229.167.246
server=/openaicomproductionae4b.blob.core.windows.net/156.229.167.246
server=/production-openaicom-storage.azureedge.net/156.229.167.246
server=/byteoversea.com/156.229.167.246
server=/ibytedtos.com/156.229.167.246
server=/ipstatp.com/156.229.167.246
server=/muscdn.com/156.229.167.246
server=/musical.ly/156.229.167.246

# 迪士尼+ 域名通过解锁 DNS 解析
server=/disneyplus.com/156.229.167.246
server=/dssott.com/156.229.167.246
server=/bamgrid.com/156.229.167.246
server=/akamaized.net/156.229.167.246

# 其他域名通过 Google DNS 解析
server=8.8.8.8
server=1.1.1.1

# 配置目录
conf-dir=/etc/dnsmasq.d
EOF

# 重启 dnsmasq 服务
sudo systemctl restart dnsmasq

echo "dnsmasq 配置已替换并生效！"
