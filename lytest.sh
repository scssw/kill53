#!/bin/bash

# ========= 配置部分 =========
# 定义目标IP和名称
target_names="China_Telecom China_Unicom China_Mobile"
target_China_Telecom="220.167.102.34"
target_China_Unicom="112.85.238.89"
target_China_Mobile="120.196.165.24"
# ===========================

check_dependencies() {
  for cmd in traceroute whois; do
    if ! command -v $cmd &>/dev/null; then
      echo "[!] 正在安装 $cmd..."
      if [ -f /etc/debian_version ]; then
        sudo apt-get install -y $cmd
      elif [ -f /etc/redhat-release ]; then
        sudo yum install -y $cmd
      else
        echo "[!] 无法自动安装，请手动安装 $cmd"
        exit 1
      fi
    fi
  done
}

get_as_info() {
  ip=$1
  whois $ip 2>/dev/null | grep -Ei 'AS|OrgName|descr|netname' | head -n 1 | sed 's/^/    → /'
}

analyze_route() {
  name=$1
  ip=$2
  direct_connect=true
  previous_as=""
  # 初始化路由信息
  route_info_hop_count=0
  route_info_valid_hops=0
  route_info_total_latency=0
  route_info_backbone_route=""
  route_info_quality_route=""
  last_hop_number=0

  echo -e "\n==============【$name】=============="
  echo "目标 IP: $ip"
  echo "--------------------------------------"
  
  # 使用临时文件存储traceroute结果
  trace_output=$(mktemp)
  traceroute -n -w 2 -q 3 -m 30 $ip > "$trace_output"
  
  # 获取最后一跳的跳数（从最后一行提取）
  last_line=$(grep -E '^[[:space:]]*[0-9]+' "$trace_output" | tail -n 1)
  if [[ $last_line =~ ^[[:space:]]*([0-9]+) ]]; then
    last_hop_number=${BASH_REMATCH[1]}
  fi
  
  while IFS= read -r line; do
    # 检查是否为跳数行（包含数字开头）
    if [[ $line =~ ^[[:space:]]*[0-9]+ ]]; then
      ((route_info_hop_count++))
      if [[ $line =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; then
        ((route_info_valid_hops++))
        hop_ip=$(echo $line | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1)
        # 获取所有延迟值
        latencies=($(echo $line | grep -Eo '[0-9]+\.[0-9]+ ms' | cut -d' ' -f1))
        
        # 累加所有延迟值
        for latency in "${latencies[@]}"; do
          if [[ -n $latency ]]; then
            route_info_total_latency=$(echo "${route_info_total_latency} + $latency" | bc)
          fi
        done
        
        if [[ $hop_ip == 10.* || $hop_ip == 192.168.* || $hop_ip == 172.16.* ]]; then
          echo "  ${route_info_hop_count}. $hop_ip  [内网地址]"
        else
          as_info=$(get_as_info $hop_ip)
          current_as=$(echo "$as_info" | grep -Eo 'AS[0-9]+' | head -n1)
          
          if [[ $previous_as != "" && $current_as != "" && $current_as != $previous_as ]]; then
            direct_connect=false
          fi
          previous_as=$current_as
          
          echo "  ${route_info_hop_count}. $hop_ip"
          echo "$as_info"
        fi
      fi
    fi
  done < "$trace_output"
  
  # 计算总延迟
  if [[ ${route_info_valid_hops} -gt 0 ]]; then
    route_info_total_latency=$(echo "scale=2; ${route_info_total_latency}" | bc)
  fi
  
  echo "--------------------------------------"
  echo "总延迟: ${route_info_total_latency} ms"
  
  # 线路质量分析
  if [ "$direct_connect" = true ]; then
    echo "✅ 检测到直连路由"
    route_info_quality_route="直连"
  fi
  
  if grep -q '219.158' "$trace_output"; then
    echo "⚠️ 检测到使用了联通 169 骨干网"
    route_info_backbone_route="${route_info_backbone_route} 联通169"
  fi
  if grep -q '202.97' "$trace_output"; then
    echo "✅ 检测到进入电信 163 骨干网"
    route_info_backbone_route="${route_info_backbone_route} 电信163"
  fi
  if grep -q '59.43' "$trace_output"; then
    echo "✅ 检测到使用了电信 CN2 优质线路"
    route_info_quality_route="${route_info_quality_route} CN2"
  fi
  if grep -q '223.120' "$trace_output"; then
    echo "✅ 检测到使用了移动 CMI 线路"
    route_info_quality_route="${route_info_quality_route} CMI"
  fi
  if grep -qE '香港|HK|Singapore|海外' "$trace_output"; then
    echo "⚠️ 可能绕路至境外"
  fi
  if grep -q '202.77' "$trace_output"; then
    echo "✅ 检测到使用了电信 CN2 GT 线路"
    route_info_quality_route="${route_info_quality_route} CN2-GT"
  fi
  if grep -qE 'softbank|IIJ' "$trace_output"; then
    echo "✅ 检测到软银/IIJ优质线路"
    route_info_quality_route="${route_info_quality_route} 软银/IIJ"
  fi
  
  # 存储路由信息用于总结
  eval "${name//' '/_}_info_hop_count='$route_info_hop_count'"
  eval "${name//' '/_}_info_total_latency='$route_info_total_latency'"
  eval "${name//' '/_}_info_backbone_route='$route_info_backbone_route'"
  eval "${name//' '/_}_info_quality_route='$route_info_quality_route'"
  
  rm -f "$trace_output"
}

# 定义颜色代码
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
NC="\033[0m" # 恢复默认颜色

print_summary() {
  echo -e "\n============== 路由分析总结 =============="
  for name in $target_names; do
    echo -e "\n【${name/_/ }】"
    eval "hop_count=\"\${${name}_info_hop_count}\""
    eval "total_latency=\"\${${name}_info_total_latency}\""
    eval "quality_route=\"\${${name}_info_quality_route}\""
    eval "backbone_route=\"\${${name}_info_backbone_route}\""
    
    echo "总延迟: $total_latency ms"
    
    if [[ -n "$quality_route" ]]; then
      # 为优质线路添加绿色显示
      echo -e "${GREEN}优质线路: $quality_route${NC}"
    fi
    if [[ -n "$backbone_route" ]]; then
      # 检查骨干网络是否包含两个或更多网络（通过检查空格数量）
      space_count=$(echo "$backbone_route" | tr -cd ' ' | wc -c)
      if [[ $space_count -ge 2 ]]; then
        # 有两个或更多骨干网络，使用黄色显示
        echo -e "${YELLOW}骨干网络: $backbone_route${NC}"
      else
        echo "骨干网络: $backbone_route"
      fi
    fi
  done
  echo -e "\n======================================"
}

main() {
  check_dependencies
  for name in $target_names; do
    target_ip="target_$name"
    analyze_route "${name/_/ }" "${!target_ip}"
  done
  print_summary
}

main
