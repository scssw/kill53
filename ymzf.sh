#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

sh_ver="1.1.1"

Green_font_prefix="\033[32m" && Cyan_font_prefix="\033[44m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Green_font_prefix}[注意]${Font_color_suffix}"


check_iptables(){
	iptables_exist=$(iptables -V)
	[[ ${iptables_exist} = "" ]] && echo -e "${Error} 没有安装iptables，请检查 !" && exit 1
}
check_sys(){
	if [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif cat /etc/issue | grep -q -E -i "debian"; then
		release="debian"
	elif cat /etc/issue | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
	elif cat /proc/version | grep -q -E -i "debian"; then
		release="debian"
	elif cat /proc/version | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
    fi
	#bit=`uname -m`
}
install_iptables(){
	iptables_exist=$(iptables -V)
	if [[ ${iptables_exist} != "" ]]; then
		echo -e "${Info} 已经安装iptables，继续..."
	else
		echo -e "${Info} 检测到未安装 iptables，开始安装..."
		if [[ ${release}  == "centos" ]]; then
			yum update
			yum install -y iptables
		else
			apt-get update
			apt-get install -y iptables
		fi
		iptables_exist=$(iptables -V)
		if [[ ${iptables_exist} = "" ]]; then
			echo -e "${Error} 安装iptables失败，请检查 !" && exit 1
		else
			echo -e "${Info} iptables 安装完成 !"
		fi
	fi
	echo -e "${Info} 开始配置 iptables !"
	Set_iptables
	echo -e "${Info} iptables 配置完毕 !"
}
Set_forwarding_port(){
	read -e -p "请输入 iptables 欲转发至的 远程端口 [1-65535] (支持端口段 如 2333-6666, 被转发服务器):" forwarding_port
	[[ -z "${forwarding_port}" ]] && echo "取消..." && exit 1
	echo && echo -e "	欲转发端口 : ${Red_font_prefix}${forwarding_port}${Font_color_suffix}" && echo
}
Set_forwarding_ip(){
	read -e -p "请输入 iptables 欲转发至的 远程IP或域名(被转发服务器):" forwarding_ip
	[[ -z "${forwarding_ip}" ]] && echo "取消..." && exit 1
	
	# 检查是否为域名，如果是则解析为IP
	if [[ ! $forwarding_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
		echo -e "${Info} 检测到输入的是域名，正在解析为IP..."
		forwarding_ip_resolved=$(host -t A "$forwarding_ip" | grep "has address" | head -n 1 | awk '{print $4}')
		if [[ -z "${forwarding_ip_resolved}" ]]; then
			echo -e "${Error} 域名解析失败，请检查域名是否正确！"
			exit 1
		else
			echo -e "${Info} 域名 ${forwarding_ip} 解析结果: ${forwarding_ip_resolved}"
			forwarding_domain="${forwarding_ip}"
			forwarding_ip="${forwarding_ip_resolved}"
			
			# 询问是否启用动态域名解析
			echo -e "检测到您输入的是域名，是否启用动态域名解析？[Y/n]"
			echo -e "${Tip} 启用后将每3分钟自动解析域名并更新转发规则，适用于目标IP会变化的情况"
			read -e -p "(默认: Y):" enable_dynamic_dns
			[[ -z "${enable_dynamic_dns}" ]] && enable_dynamic_dns="y"
			if [[ ${enable_dynamic_dns} == [Yy] ]]; then
				dynamic_dns="true"
			else
				dynamic_dns="false"
			fi
		fi
	fi
	
	echo && echo -e "	欲转发服务器IP : ${Red_font_prefix}${forwarding_ip}${Font_color_suffix}" && echo
}
Set_local_port(){
	echo -e "请输入 iptables 本地监听端口 [1-65535] (支持端口段 如 2333-6666)"
	read -e -p "(默认端口: ${forwarding_port}):" local_port
	[[ -z "${local_port}" ]] && local_port="${forwarding_port}"
	echo && echo -e "	本地监听端口 : ${Red_font_prefix}${local_port}${Font_color_suffix}" && echo
}
Set_local_ip(){
	read -e -p "请输入 本服务器的 网卡IP(注意是网卡绑定的IP，而仅仅是公网IP，回车自动检测外网IP):" local_ip
	if [[ -z "${local_ip}" ]]; then
		local_ip=$(wget -qO- -t1 -T2 ipinfo.io/ip)
		if [[ -z "${local_ip}" ]]; then
			echo "${Error} 无法检测到本服务器的公网IP，请手动输入"
			read -e -p "请输入 本服务器的 网卡IP(注意是网卡绑定的IP，而仅仅是公网IP):" local_ip
			[[ -z "${local_ip}" ]] && echo "取消..." && exit 1
		fi
	fi
	echo && echo -e "	本服务器IP : ${Red_font_prefix}${local_ip}${Font_color_suffix}" && echo
}
Set_forwarding_type(){
	echo -e "请输入数字 来选择 iptables 转发类型:
 1. TCP
 2. UDP
 3. TCP+UDP\n"
	read -e -p "(默认: TCP+UDP):" forwarding_type_num
	[[ -z "${forwarding_type_num}" ]] && forwarding_type_num="3"
	if [[ ${forwarding_type_num} == "1" ]]; then
		forwarding_type="TCP"
	elif [[ ${forwarding_type_num} == "2" ]]; then
		forwarding_type="UDP"
	elif [[ ${forwarding_type_num} == "3" ]]; then
		forwarding_type="TCP+UDP"
	else
		forwarding_type="TCP+UDP"
	fi
}
Set_Config(){
	Set_forwarding_port
	Set_forwarding_ip
	Set_local_port
	Set_local_ip
	Set_forwarding_type
	echo && echo -e "——————————————————————————————
	请检查 iptables 端口转发规则配置是否有误 !\n
	本地监听端口    : ${Green_font_prefix}${local_port}${Font_color_suffix}
	服务器 IP\t: ${Green_font_prefix}${local_ip}${Font_color_suffix}\n
	欲转发的端口    : ${Green_font_prefix}${forwarding_port}${Font_color_suffix}
	欲转发 IP\t: ${Green_font_prefix}${forwarding_ip}${Font_color_suffix}
	转发类型\t: ${Green_font_prefix}${forwarding_type}${Font_color_suffix}
——————————————————————————————\n"
	read -e -p "请按任意键继续，如有配置错误请使用 Ctrl+C 退出。" var
}
Add_forwarding(){
	check_iptables
	Set_Config
	local_port=$(echo ${local_port} | sed 's/-/:/g')
	forwarding_port_1=$(echo ${forwarding_port} | sed 's/-/:/g')
	if [[ ${forwarding_type} == "TCP" ]]; then
		Add_iptables "tcp"
	elif [[ ${forwarding_type} == "UDP" ]]; then
		Add_iptables "udp"
	elif [[ ${forwarding_type} == "TCP+UDP" ]]; then
		Add_iptables "tcp"
		Add_iptables "udp"
	fi
	Save_iptables
	
	# 如果启用了动态域名解析，则创建定时任务
	if [[ "${dynamic_dns}" == "true" && ! -z "${forwarding_domain}" ]]; then
	    # 为每个域名创建唯一的脚本文件名
	    script_name="update_iptables_ddns_${forwarding_domain//[^a-zA-Z0-9]/_}.sh"
	    
    # 创建更新脚本 - 注意这里不能有缩进
    cat > /usr/local/bin/${script_name} << 'EOF'
#!/bin/bash
# 动态域名解析更新脚本 - 由ipzf.sh创建
# 域名: ${forwarding_domain}
# 本地端口: ${local_port}
# 远程端口: ${forwarding_port}
# 转发类型: ${forwarding_type}

# 设置PATH环境变量，确保能找到iptables命令
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# 检查iptables命令是否存在
if ! command -v iptables &> /dev/null; then
    echo "[错误] iptables命令未找到，请先安装iptables"
    # 尝试自动安装iptables
    if [ -f /etc/redhat-release ]; then
        echo "[信息] 检测到CentOS系统，尝试安装iptables..."
        yum install -y iptables
    elif [ -f /etc/debian_version ]; then
        echo "[信息] 检测到Debian/Ubuntu系统，尝试安装iptables..."
        apt-get update
        apt-get install -y iptables
    else
        echo "[错误] 无法确定系统类型，请手动安装iptables后再运行此脚本"
        exit 1
    fi
    
    # 再次检查是否安装成功
    if ! command -v iptables &> /dev/null; then
        echo "[错误] iptables安装失败，请手动安装后再运行此脚本"
        exit 1
    else
        echo "[信息] iptables安装成功，继续执行脚本"
    fi
fi

# 检查host命令是否存在
if ! command -v host &> /dev/null; then
    echo "[错误] host命令未找到，请先安装bind-utils或dnsutils"
    # 尝试自动安装host命令
    if [ -f /etc/redhat-release ]; then
        echo "[信息] 检测到CentOS系统，尝试安装bind-utils..."
        yum install -y bind-utils
    elif [ -f /etc/debian_version ]; then
        echo "[信息] 检测到Debian/Ubuntu系统，尝试安装dnsutils..."
        apt-get update
        apt-get install -y dnsutils
    else
        echo "[错误] 无法确定系统类型，请手动安装bind-utils或dnsutils后再运行此脚本"
        exit 1
    fi
    
    # 再次检查是否安装成功
    if ! command -v host &> /dev/null; then
        echo "[错误] host命令安装失败，尝试使用nslookup作为替代"
        # 尝试使用nslookup作为替代
        if command -v nslookup &> /dev/null; then
            echo "[信息] 将使用nslookup代替host命令"
            # 使用nslookup解析域名
            new_ip=$(nslookup "${forwarding_domain}" | grep -A1 'Name:' | grep 'Address:' | tail -n1 | awk '{print $2}')
            if [[ -z "${new_ip}" ]]; then
                echo "[错误] 域名解析失败: ${forwarding_domain}"
                exit 1
            fi
        else
            echo "[错误] 无法解析域名，请手动安装host或nslookup命令"
            exit 1
        fi
    else
        echo "[信息] host命令安装成功，继续执行脚本"
        # 解析域名获取新IP
        new_ip=$(host -t A "${forwarding_domain}" | grep "has address" | head -n 1 | awk '{print $4}')
        if [[ -z "${new_ip}" ]]; then
            echo "[错误] 域名解析失败: ${forwarding_domain}"
            exit 1
        fi
    fi
else
    # 解析域名获取新IP
    new_ip=$(host -t A "${forwarding_domain}" | grep "has address" | head -n 1 | awk '{print $4}')
    if [[ -z "${new_ip}" ]]; then
        echo "[错误] 域名解析失败: ${forwarding_domain}"
        exit 1
    fi
fi

# 获取当前转发规则中的IP
try_get_current_ip() {
    current_ip=$(iptables -t nat -vnL PREROUTING 2>/dev/null | grep "${local_port}" | grep "dpt:${local_port//:/}" | head -n 1 | awk -F "to:" '{print $2}' | cut -d: -f1)
    return $?
}

# 尝试执行iptables命令
if ! try_get_current_ip; then
    echo "[警告] 执行iptables命令失败，可能是权限不足或规则不存在"
    # 检查是否以root权限运行
    if [ "$(id -u)" != "0" ]; then
        echo "[错误] 此脚本需要root权限运行，请使用sudo或切换到root用户"
        exit 1
    fi
fi

if [[ -z "${current_ip}" ]]; then
    echo "[警告] 未找到与端口 ${local_port} 相关的转发规则"
    echo "[信息] 将尝试创建新的转发规则而不是更新现有规则"
    # 继续执行，但将使用新IP创建规则而不是更新
    create_new_rule=true
else
    create_new_rule=false
fi

# 安全执行iptables命令的函数
execute_iptables() {
    if ! "$@" 2>/dev/null; then
        echo "[错误] 执行命令失败: $@"
        echo "[信息] 请检查iptables是否正确安装和配置"
        return 1
    fi
    return 0
}

# 安全保存iptables规则的函数
save_iptables_rules() {
    echo "[信息] 正在保存iptables规则..."
    if [[ -f /etc/redhat-release ]]; then
        if ! service iptables save 2>/dev/null; then
            echo "[警告] 使用service保存iptables规则失败，尝试直接保存到文件"
            if ! iptables-save > /etc/iptables.up.rules 2>/dev/null; then
                echo "[错误] 保存iptables规则失败"
                return 1
            fi
        fi
    else
        if ! iptables-save > /etc/iptables.up.rules 2>/dev/null; then
            echo "[错误] 保存iptables规则失败"
            return 1
        fi
    fi
    echo "[信息] iptables规则保存成功"
    return 0
}

# 如果需要创建新规则或IP变化了，更新规则
if [[ "${create_new_rule}" == "true" || "${current_ip}" != "${new_ip}" ]]; then
    if [[ "${create_new_rule}" == "true" ]]; then
        echo "[信息] 正在为域名 ${forwarding_domain} 创建新的转发规则，IP: ${new_ip}"
    else
        echo "[信息] 域名 ${forwarding_domain} 的IP已变化: ${current_ip} -> ${new_ip}"
        
        # 删除旧规则 - 使用端口和IP匹配，避免删除其他域名的规则
        echo "[信息] 正在删除旧的转发规则..."
        prerouting_rules=$(iptables -t nat -vnL PREROUTING --line-numbers 2>/dev/null | grep "${current_ip}" | grep "dpt:${local_port//:/}" | awk '{print $1}' | sort -r)
        if [[ ! -z "${prerouting_rules}" ]]; then
            for rule_num in $prerouting_rules; do
                if ! execute_iptables iptables -t nat -D PREROUTING $rule_num; then
                    echo "[警告] 删除PREROUTING规则 $rule_num 失败，继续处理其他规则"
                fi
            done
        else
            echo "[警告] 未找到匹配的PREROUTING规则，可能已被删除"
        fi
        
        postrouting_rules=$(iptables -t nat -vnL POSTROUTING --line-numbers 2>/dev/null | grep "${current_ip}" | grep "dpt:${forwarding_port_1//:/}" | awk '{print $1}' | sort -r)
        if [[ ! -z "${postrouting_rules}" ]]; then
            for rule_num in $postrouting_rules; do
                if ! execute_iptables iptables -t nat -D POSTROUTING $rule_num; then
                    echo "[警告] 删除POSTROUTING规则 $rule_num 失败，继续处理其他规则"
                fi
            done
        else
            echo "[警告] 未找到匹配的POSTROUTING规则，可能已被删除"
        fi
    fi
    
    # 添加新规则
    echo "[信息] 正在添加新的转发规则..."
    success=true
    
    if [[ "${forwarding_type}" == "TCP" || "${forwarding_type}" == "TCP+UDP" ]]; then
        if ! execute_iptables iptables -t nat -A PREROUTING -p tcp --dport ${local_port} -j DNAT --to-destination ${new_ip}:${forwarding_port}; then
            echo "[错误] 添加TCP PREROUTING规则失败"
            success=false
        fi
        
        if ! execute_iptables iptables -t nat -A POSTROUTING -p tcp -d ${new_ip} --dport ${forwarding_port_1} -j SNAT --to-source ${local_ip}; then
            echo "[错误] 添加TCP POSTROUTING规则失败"
            success=false
        fi
    fi
    
    if [[ "${forwarding_type}" == "UDP" || "${forwarding_type}" == "TCP+UDP" ]]; then
        if ! execute_iptables iptables -t nat -A PREROUTING -p udp --dport ${local_port} -j DNAT --to-destination ${new_ip}:${forwarding_port}; then
            echo "[错误] 添加UDP PREROUTING规则失败"
            success=false
        fi
        
        if ! execute_iptables iptables -t nat -A POSTROUTING -p udp -d ${new_ip} --dport ${forwarding_port_1} -j SNAT --to-source ${local_ip}; then
            echo "[错误] 添加UDP POSTROUTING规则失败"
            success=false
        fi
    fi
    
    # 保存规则
    if [[ "${success}" == "true" ]]; then
        if save_iptables_rules; then
            echo "[信息] 已成功${create_new_rule:+创建}${create_new_rule:-更新} ${forwarding_domain} 的转发规则"
        else
            echo "[警告] 规则已添加但保存失败，重启后可能会丢失"
        fi
    else
        echo "[错误] 部分或全部规则添加失败，请检查系统日志获取详细信息"
    fi
else
    echo "[信息] 域名 ${forwarding_domain} 的IP未变化，无需更新"
fi
EOF
	
	    # 替换脚本中的变量
	    sed -i "s|\${forwarding_domain}|${forwarding_domain}|g" /usr/local/bin/${script_name}
	    sed -i "s|\${local_port}|${local_port}|g" /usr/local/bin/${script_name}
	    sed -i "s|\${forwarding_port}|${forwarding_port}|g" /usr/local/bin/${script_name}
	    sed -i "s|\${forwarding_port_1}|${forwarding_port_1}|g" /usr/local/bin/${script_name}
	    sed -i "s|\${forwarding_type}|${forwarding_type}|g" /usr/local/bin/${script_name}
	    sed -i "s|\${local_ip}|${local_ip}|g" /usr/local/bin/${script_name}
	    
	    chmod +x /usr/local/bin/${script_name}
	    
	    # 检查crontab中是否已存在该脚本的任务
	    if ! crontab -l 2>/dev/null | grep -q "${script_name}"; then
	        # 添加到crontab，确保只添加一次
	        (crontab -l 2>/dev/null | grep -v "${script_name}"; echo "*/3 * * * * /usr/local/bin/${script_name} >> /var/log/ddns_update.log 2>&1") | crontab -
	    else
	        echo -e "${Info} 定时任务已存在，跳过添加"
	    fi
	    
	    # 立即执行一次脚本测试
	    /usr/local/bin/${script_name}
	    
	    echo -e "${Info} 已设置动态域名解析，系统将每3分钟自动检查并更新 ${forwarding_domain} 的IP"
	    echo -e "${Info} 日志保存在 /var/log/ddns_update.log"
	fi
	
	clear && echo && echo -e "——————————————————————————————
	iptables 端口转发规则配置完成 !\n
	本地监听端口    : ${Green_font_prefix}${local_port}${Font_color_suffix}
	服务器 IP\t: ${Green_font_prefix}${local_ip}${Font_color_suffix}\n
	欲转发的端口    : ${Green_font_prefix}${forwarding_port_1}${Font_color_suffix}
	欲转发 IP\t: ${Green_font_prefix}${forwarding_ip}${Font_color_suffix}"
	[[ ! -z "${forwarding_domain}" ]] && echo -e "	原始域名\t: ${Green_font_prefix}${forwarding_domain}${Font_color_suffix}"
	[[ "${dynamic_dns}" == "true" ]] && echo -e "	动态解析\t: ${Green_font_prefix}已启用 (每3分钟更新)${Font_color_suffix}"
	echo -e "	转发类型\t: ${Green_font_prefix}${forwarding_type}${Font_color_suffix}
——————————————————————————————\n"
}
View_forwarding(){
	check_iptables
	forwarding_text=$(iptables -t nat -vnL PREROUTING|tail -n +3)
	[[ -z ${forwarding_text} ]] && echo -e "${Error} 没有发现 iptables 端口转发规则，请检查 !" && exit 1
	forwarding_total=$(echo -e "${forwarding_text}"|wc -l)
	forwarding_list_all=""
	for((integer = 1; integer <= ${forwarding_total}; integer++))
	do
		forwarding_type=$(echo -e "${forwarding_text}"|awk '{print $4}'|sed -n "${integer}p")
		forwarding_listen=$(echo -e "${forwarding_text}"|awk '{print $11}'|sed -n "${integer}p"|awk -F "dpt:" '{print $2}')
		[[ -z ${forwarding_listen} ]] && forwarding_listen=$(echo -e "${forwarding_text}"| awk '{print $11}'|sed -n "${integer}p"|awk -F "dpts:" '{print $2}')
		forwarding_fork=$(echo -e "${forwarding_text}"| awk '{print $12}'|sed -n "${integer}p"|awk -F "to:" '{print $2}')
		forwarding_list_all=${forwarding_list_all}"${Green_font_prefix}"${integer}".${Font_color_suffix} 类型: ${Green_font_prefix}"${forwarding_type}"${Font_color_suffix} 监听端口: ${Red_font_prefix}"${forwarding_listen}"${Font_color_suffix} 转发IP和端口: ${Red_font_prefix}"${forwarding_fork}"${Font_color_suffix}\n"
	done
	echo && echo -e "当前有 ${Green_background_prefix} "${forwarding_total}" ${Font_color_suffix} 个 iptables 端口转发规则。"
	echo -e ${forwarding_list_all}
}
Del_forwarding(){
	check_iptables
	while true
	do
	View_forwarding
	read -e -p "请输入数字 来选择要删除的 iptables 端口转发规则(默认回车取消):" Del_forwarding_num
	[[ -z "${Del_forwarding_num}" ]] && Del_forwarding_num="0"
	echo $((${Del_forwarding_num}+0)) &>/dev/null
	if [[ $? -eq 0 ]]; then
		if [[ ${Del_forwarding_num} -ge 1 ]] && [[ ${Del_forwarding_num} -le ${forwarding_total} ]]; then
			forwarding_type=$(echo -e "${forwarding_text}"| awk '{print $4}' | sed -n "${Del_forwarding_num}p")
			forwarding_listen=$(echo -e "${forwarding_text}"| awk '{print $11}' | sed -n "${Del_forwarding_num}p" | awk -F "dpt:" '{print $2}' | sed 's/-/:/g')
			[[ -z ${forwarding_listen} ]] && forwarding_listen=$(echo -e "${forwarding_text}"| awk '{print $11}' |sed -n "${Del_forwarding_num}p" | awk -F "dpts:" '{print $2}')
			Del_iptables "${forwarding_type}" "${Del_forwarding_num}"
			Save_iptables
			echo && echo -e "${Info} iptables 端口转发规则删除完成 !" && echo
		else
			echo -e "${Error} 请输入正确的数字 !"
		fi
	else
		break && echo "取消..."
	fi
	done
}
Uninstall_forwarding(){
	check_iptables
	echo -e "确定要清空 iptables 所有端口转发规则 ? [y/N]"
	read -e -p "(默认: n):" unyn
	[[ -z ${unyn} ]] && unyn="n"
	if [[ ${unyn} == [Yy] ]]; then
		forwarding_text=$(iptables -t nat -vnL PREROUTING|tail -n +3)
		[[ -z ${forwarding_text} ]] && echo -e "${Error} 没有发现 iptables 端口转发规则，请检查 !" && exit 1
		forwarding_total=$(echo -e "${forwarding_text}"|wc -l)
		for((integer = 1; integer <= ${forwarding_total}; integer++))
		do
			forwarding_type=$(echo -e "${forwarding_text}"|awk '{print $4}'|sed -n "${integer}p")
			forwarding_listen=$(echo -e "${forwarding_text}"|awk '{print $11}'|sed -n "${integer}p"|awk -F "dpt:" '{print $2}')
			[[ -z ${forwarding_listen} ]] && forwarding_listen=$(echo -e "${forwarding_text}"| awk '{print $11}'|sed -n "${integer}p"|awk -F "dpts:" '{print $2}')
			# echo -e "${forwarding_text} ${forwarding_type} ${forwarding_listen}"
			Del_iptables "${forwarding_type}" "${integer}"
		done
		Save_iptables
		echo && echo -e "${Info} iptables 已清空 所有端口转发规则 !" && echo
	else
		echo && echo "清空已取消..." && echo
	fi
}

# 强制清空所有NAT表规则
Force_Clear_iptables(){
	check_iptables
	echo -e "确定要强制清空 iptables 的所有 NAT 表规则吗？这将删除所有转发规则，包括可能无法通过常规方式删除的规则。[y/N]"
	read -e -p "(默认: n):" unyn
	[[ -z ${unyn} ]] && unyn="n"
	if [[ ${unyn} == [Yy] ]]; then
		# 清空NAT表的所有链
		iptables -t nat -F
		# 如果需要，也可以删除自定义链
		iptables -t nat -X
		# 重置NAT表的所有计数器
		iptables -t nat -Z
		
		Save_iptables
		echo && echo -e "${Info} iptables 的 NAT 表已被强制清空！所有端口转发规则已删除！" && echo
	else
		echo && echo "强制清空已取消..." && echo
	fi
}

# 查看动态域名转发状态
View_DDNS_Forwarding(){
	if crontab -l 2>/dev/null | grep -q "update_iptables_ddns"; then
		echo -e "${Info} 当前已配置的动态域名转发任务："
		echo "------------------------"
		for script in $(find /usr/local/bin -name "update_iptables_ddns_*.sh" 2>/dev/null); do
			if [[ -f "${script}" ]]; then
				domain=$(grep "# 域名:" ${script} | awk -F ": " '{print $2}')
				local_port=$(grep "# 本地端口:" ${script} | awk -F ": " '{print $2}')
				remote_port=$(grep "# 远程端口:" ${script} | awk -F ": " '{print $2}')
				type=$(grep "# 转发类型:" ${script} | awk -F ": " '{print $2}')
				echo -e "域名: ${Green_font_prefix}${domain}${Font_color_suffix}"
				echo -e "本地端口: ${Red_font_prefix}${local_port}${Font_color_suffix}"
				echo -e "远程端口: ${Red_font_prefix}${remote_port}${Font_color_suffix}"
				echo -e "转发类型: ${Green_font_prefix}${type}${Font_color_suffix}"
				echo "------------------------"
			fi
		done
	else
		echo -e "${Error} 未发现动态域名转发任务！"
	fi
}

# 删除动态域名转发
Del_DDNS_Forwarding(){
	# 获取所有动态域名转发任务
	declare -a domains
	declare -a scripts
	index=1

	echo -e "${Info} 当前已配置的动态域名转发任务："
	echo "------------------------"
	for script in $(find /usr/local/bin -name "update_iptables_ddns_*.sh" 2>/dev/null); do
		if [[ -f "${script}" ]]; then
			domain=$(grep "# 域名:" ${script} | awk -F ": " '{print $2}')
			local_port=$(grep "# 本地端口:" ${script} | awk -F ": " '{print $2}')
			remote_port=$(grep "# 远程端口:" ${script} | awk -F ": " '{print $2}')
			type=$(grep "# 转发类型:" ${script} | awk -F ": " '{print $2}')
			echo -e "${Green_font_prefix}${index}.${Font_color_suffix} 域名: ${Green_font_prefix}${domain}${Font_color_suffix}"
			echo -e "   本地端口: ${Red_font_prefix}${local_port}${Font_color_suffix}"
			echo -e "   远程端口: ${Red_font_prefix}${remote_port}${Font_color_suffix}"
			echo -e "   转发类型: ${Green_font_prefix}${type}${Font_color_suffix}"
			echo "------------------------"
			domains[index]=${domain}
			scripts[index]=${script}
			((index++))
		fi
	done

	if [[ ${index} -eq 1 ]]; then
		echo -e "${Error} 未发现动态域名转发任务！"
		return
	fi

	echo
	read -e -p "请输入数字来选择要删除的动态域名转发规则 (1-$((index-1)), 默认取消): " del_num
	if [[ -z "${del_num}" ]]; then
		echo -e "${Info} 已取消删除"
		return
	fi

	if ! [[ "${del_num}" =~ ^[0-9]+$ ]] || [[ ${del_num} -lt 1 ]] || [[ ${del_num} -ge ${index} ]]; then
		echo -e "${Error} 请输入正确的数字！"
		return
	fi

	script_to_del=${scripts[${del_num}]}
	domain_to_del=${domains[${del_num}]}
	if [[ -f "${script_to_del}" ]]; then
		script_name=$(basename ${script_to_del})
		rm -f ${script_to_del}
		# 从crontab中删除
		crontab -l 2>/dev/null | grep -v "${script_name}" | crontab -
		echo -e "${Info} 已删除域名 ${domain_to_del} 的动态转发任务"
	else
		echo -e "${Error} 删除失败，脚本文件不存在"
	fi
}
Add_iptables(){
	# 添加PREROUTING规则
	iptables -t nat -A PREROUTING -p "$1" --dport "${local_port}" -j DNAT --to-destination "${forwarding_ip}":"${forwarding_port}"
	# 添加POSTROUTING规则
	iptables -t nat -A POSTROUTING -p "$1" -d "${forwarding_ip}" --dport "${forwarding_port_1}" -j SNAT --to-source "${local_ip}"
	
	echo "iptables -t nat -A PREROUTING -p $1 --dport ${local_port} -j DNAT --to-destination ${forwarding_ip}:${forwarding_port}"
	echo "iptables -t nat -A POSTROUTING -p $1 -d ${forwarding_ip} --dport ${forwarding_port_1} -j SNAT --to-source ${local_ip}"
	
	# 添加INPUT规则
	iptables -I INPUT -m state --state NEW -m "$1" -p "$1" --dport "${local_port}" -j ACCEPT
}
Del_iptables(){
	iptables -t nat -D POSTROUTING "$2"
	iptables -t nat -D PREROUTING "$2"
	iptables -D INPUT -m state --state NEW -m "$1" -p "$1" --dport "${forwarding_listen}" -j ACCEPT
}
Save_iptables(){
	if [[ ${release} == "centos" ]]; then
		service iptables save
	else
		iptables-save > /etc/iptables.up.rules
	fi
}
Set_iptables(){
	echo -e "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
	sysctl -p
	if [[ ${release} == "centos" ]]; then
		service iptables save
		chkconfig --level 2345 iptables on
	else
		iptables-save > /etc/iptables.up.rules
		echo -e '#!/bin/bash\n/sbin/iptables-restore < /etc/iptables.up.rules' > /etc/network/if-pre-up.d/iptables
		chmod +x /etc/network/if-pre-up.d/iptables
	fi
}
# 修改主菜单部分
check_sys
while true; do
    echo && echo -e " ${Cyan_font_prefix}--Sun_^的端口转发--${Font_color_suffix}
————————————————
 ${Green_font_prefix}1.${Font_color_suffix} 安装iptables
 ${Green_font_prefix}2.${Font_color_suffix} 清空端口转发
 ${Green_font_prefix}6.${Font_color_suffix} 清空NAT表规则
————————————————
 ${Green_font_prefix}3.${Font_color_suffix} 查看端口转发
 ${Green_font_prefix}4.${Font_color_suffix} 添加端口转发
 ${Green_font_prefix}5.${Font_color_suffix} 删除端口转发
————————————————
 ${Green_font_prefix}7.${Font_color_suffix} 查看动态域名转发
 ${Green_font_prefix}8.${Font_color_suffix} 删除动态域名转发
————————————————
直接回车退出脚本" && echo
    read -e -p " 请输入数字 [0-8]:" num
    [[ -z "${num}" ]] && echo "已退出脚本" && exit 1
    
    case "$num" in
        0)
        Update_Shell
        ;;
        1)
        install_iptables
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        2)
        Uninstall_forwarding
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        3)
        View_forwarding
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        4)
        Add_forwarding
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        5)
        Del_forwarding
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        6)
        Force_Clear_iptables
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        7)
        View_DDNS_Forwarding
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        8)
        Del_DDNS_Forwarding
        echo -e "${Info} 操作已完成，按任意键返回主菜单"
        read -n 1
        ;;
        *)
        echo -e "${Error} 请输入正确数字 [0-8]"
        sleep 2
        ;;
    esac
done
