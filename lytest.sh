#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BG_BLUE='\033[48;5;42m'
CYAN='\033[1;36m'  # 亮青色
NC='\033[0m' # No Color

# 测试目标IP
declare -A targets=(
  ["China Telecom"]="220.167.102.34"
  ["China Unicom"]="112.85.238.89"
  ["China Mobile"]="120.196.165.24"
)

# 检查是否安装了必要的工具
check_dependencies() {
    if ! command -v traceroute &> /dev/null; then
        echo -e "${RED}错误: 未安装 traceroute${NC}"
        echo "正在安装 traceroute..."
        apt-get update && apt-get install -y traceroute
    fi
}

# 分析路由结果
analyze_route() {
    local route_output="$1"
    local carrier="$2"
    
    echo -e "\n${BG_BLUE}[${carrier} 路由分析]${NC}"
    
    # 检查是否直连
    local is_direct=true
    if echo "$route_output" | grep -q "hk\|jp\|sg\|us\|kr\|tw"; then
        is_direct=false
    fi
    
    # 检查骨干网类型
    local backbone=""
    local is_cn2=false
    local is_softbank=false
    local is_iij=false
    local is_cmi=false
    
    # 检测骨干网变换
    local backbone_changes=()
    if echo "$route_output" | grep -q "59.43"; then
        backbone_changes+=("电信CN2")
        is_cn2=true
    fi
    if echo "$route_output" | grep -q "202.97"; then
        backbone_changes+=("电信163")
    fi
    if echo "$route_output" | grep -q "219.158"; then
        backbone_changes+=("联通169")
    fi
    if echo "$route_output" | grep -q "223.120"; then
        backbone_changes+=("移动CMI")
        is_cmi=true
    fi
    if echo "$route_output" | grep -q "221.111\|210.171.224\|210.171.225\|210.171.226\|210.171.227"; then
        backbone_changes+=("SoftBank")
        is_softbank=true
    fi
    if echo "$route_output" | grep -q "210.130\|210.131\|210.132\|210.133"; then
        backbone_changes+=("IIJ")
        is_iij=true
    fi
    
    # 设置主要骨干网类型
    if [ ${#backbone_changes[@]} -gt 0 ]; then
        backbone=${backbone_changes[-1]}
    fi
    
    # 检查延迟
    local avg_delay=$(echo "$route_output" | grep -o "[0-9]*\.[0-9]* ms" | tail -n 1 | cut -d' ' -f1)
    
    # 输出分析结果
    echo -e "${CYAN}[路由质量分析]${NC}"
    echo -e "去程是否直连: $([ "$is_direct" = true ] && echo -e "${GREEN}[是]${NC}" || echo -e "${RED}[否]${NC}")"
    echo -e "骨干网类型: ${YELLOW}[$backbone]${NC}"
    
    # 显示骨干网变换
    if [ ${#backbone_changes[@]} -gt 1 ]; then
        echo -e "骨干网变换: ${YELLOW}[${backbone_changes[*]}]${NC}"
    fi
    
    # 显示特殊线路
    if [ "$is_cn2" = true ]; then
        echo -e "特殊线路: ${GREEN}[CN2]${NC}"
    fi
    if [ "$is_softbank" = true ]; then
        echo -e "特殊线路: ${GREEN}[SoftBank]${NC}"
    fi
    if [ "$is_iij" = true ]; then
        echo -e "特殊线路: ${GREEN}[IIJ]${NC}"
    fi
    if [ "$is_cmi" = true ]; then
        echo -e "特殊线路: ${GREEN}[CMI]${NC}"
    fi
    
    echo -e "平均延迟: ${YELLOW}[$avg_delay ms]${NC}"
    
    # 综合评估
    echo -e "\n${CYAN}[综合评估]${NC}"
    if [ "$is_direct" = true ] && [ -n "$backbone" ]; then
        if [ "$is_cn2" = true ] || [ "$is_softbank" = true ] || [ "$is_iij" = true ]; then
            echo -e "${GREEN}[优质线路]${NC}"
        else
            echo -e "${YELLOW}[一般线路]${NC}"
        fi
    else
        echo -e "${RED}[较差线路]${NC}"
    fi
    
    # 保存结果到数组
    results+=("$carrier|$backbone|$avg_delay|$is_direct|${backbone_changes[*]}")
}

# 主函数
main() {
    check_dependencies
    local results=()
    
    echo -e "${GREEN}[开始三网路由检测]${NC}\n"
    
    for carrier in "${!targets[@]}"; do
        ip=${targets[$carrier]}
        echo -e "${YELLOW}[正在检测 ${carrier} (${ip}) 的路由]${NC}"
        
        # 执行traceroute并保存结果
        route_output=$(traceroute -n -m 30 $ip)
        echo "$route_output"
        
        # 分析路由结果
        analyze_route "$route_output" "$carrier"
        echo "----------------------------------------"
    done
    
    # 输出汇总结果
    echo -e "\n${BG_BLUE}[三网路由检测汇总]${NC}"
    echo -e "${CYAN}运营商\t\t骨干网\t\t延迟\t\t直连\t\t骨干网变换${NC}"
    echo "---------------------------------------------------------------------------------"
    for result in "${results[@]}"; do
        IFS='|' read -r carrier backbone delay is_direct backbone_changes <<< "$result"
        # 格式化输出，使用printf确保对齐
        printf "%-15s %-17s %-16s %-20s %s\n" \
            "$carrier" \
            "$backbone" \
            "$delay ms" \
            "$([ "$is_direct" = true ] && echo -e "${GREEN}是${NC}" || echo -e "${RED}否${NC}")" \
            "$backbone_changes"
    done
}

# 运行主函数
main 
