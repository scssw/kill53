#!/bin/bash
#Set PATH
unset check
for i in `echo $PATH | sed 's/:/\n/g'`
do
        if [[ ${i} == "/usr/local/bin" ]];then
                check="yes"
        fi
done
if [[ -z ${check} ]];then
        echo "export PATH=${PATH}:/usr/local/bin" >> ~/.bashrc
        . ~/.bashrc
fi

#Check Root
[ $(id -u) != "0" ] && { echo "Error: You must be root to run this script"; exit 1; }
#Check OS
if [ -n "$(grep 'Aliyun Linux release' /etc/issue)" -o -e /etc/redhat-release ];then
    OS=CentOS
    [ -n "$(grep ' 7\.' /etc/redhat-release)" ] && CentOS_RHEL_version=7
    [ -n "$(grep ' 6\.' /etc/redhat-release)" -o -n "$(grep 'Aliyun Linux release6 15' /etc/issue)" ] && CentOS_RHEL_version=6
    [ -n "$(grep ' 5\.' /etc/redhat-release)" -o -n "$(grep 'Aliyun Linux release5' /etc/issue)" ] && CentOS_RHEL_version=5
elif [ -n "$(grep 'Amazon Linux AMI release' /etc/issue)" -o -e /etc/system-release ];then
    OS=CentOS
    CentOS_RHEL_version=6
elif [ -n "$(grep bian /etc/issue)" -o "$(lsb_release -is 2>/dev/null)" == 'Debian' ];then
    OS=Debian
    [ ! -e "$(which lsb_release)" ] && { apt-get -y update; apt-get -y install lsb-release; clear; }
    Debian_version=$(lsb_release -sr | awk -F. '{print $1}')
elif [ -n "$(grep Deepin /etc/issue)" -o "$(lsb_release -is 2>/dev/null)" == 'Deepin' ];then
    OS=Debian
    [ ! -e "$(which lsb_release)" ] && { apt-get -y update; apt-get -y install lsb-release; clear; }
    Debian_version=$(lsb_release -sr | awk -F. '{print $1}')
elif [ -n "$(grep Ubuntu /etc/issue)" -o "$(lsb_release -is 2>/dev/null)" == 'Ubuntu' -o -n "$(grep 'Linux Mint' /etc/issue)" ];then
    OS=Ubuntu
    [ ! -e "$(which lsb_release)" ] && { apt-get -y update; apt-get -y install lsb-release; clear; }
    Ubuntu_version=$(lsb_release -sr | awk -F. '{print $1}')
    [ -n "$(grep 'Linux Mint 18' /etc/issue)" ] && Ubuntu_version=16
else
    echo "Does not support this OS, Please contact the author! "
    kill -9 $$
fi

StopInstall(){
    echo -e "\n安装中断,开始清理文件!"
    sleep 1s
    rm -rf /usr/local/bin/ssr
    rm -rf /usr/local/SSR-Bash-Python
    rm -rf /usr/local/shadowsocksr
    rm -rf ${PWD}/libsodium*
    rm -rf /etc/init.d/ssr-bash-python
    rm -rf /usr/local/AR-B-P-B
    if [[ ${OS} == CentOS  ]];then
        sed -n -i 's#/etc/init.d/ssr-bash-python#d' /etc/rc.d/rc.local
    fi
    if [[ ${OS} == CentOS && ${CentOS_RHEL_version} == 7  ]];then
        systemctl stop iptables.service
        systemctl restart firewalld.service
        systemctl disable iptables.service
        systemctl enable firewalld.service
    fi
    checkcron=$(crontab -l 2>/dev/null | grep "timelimit.sh")
    if [[ ! -z ${checkcron} ]];then
        crontab -l > ~/crontab.bak 1>/dev/null 2>&1
        sed -i "/timelimit.sh/d" ~/crontab.bak 1>/dev/null 2>&1
        crontab ~/crontab.bak 1>/dev/null 2>&1
        rm -rf ~/crontab.bak
    fi
    rm -rf $0
    echo "清理完成!"
}

#Get Current Directory
workdir=$(pwd)

#Install Basic Tools
if [ ! -e /usr/local/bin/ssr ];then
if [[ $1 == "uninstall" ]];then
    echo "你在开玩笑吗？你都没有安装怎么卸载呀！"
    exit 1
fi
echo "开始部署"
trap 'StopInstall 2>/dev/null && exit 0' 2
sleep 2s
if [[ ${OS} == Ubuntu ]];then
    apt-get update
    apt-get -y install python screen
    apt-get install python-pip -y
    apt-get install git -y
    #apt-get install language-pack-zh-hans -y
    apt-get -y install bc vnstat
    #apt-get -y install build-essential
    #apt-get install net-tools -y
fi
if [[ ${OS} == CentOS ]];then
    yum install python screen curl -y
    yum install python-setuptools -y && easy_install pip -y
    yum install git -y
    yum install bc -y
    yum install vnstat -y
    #yum install net-tools -y
    yum groupinstall "Development Tools" -y
    yum install vixie-cron crontabs -y
fi
if [[ ${OS} == Debian ]];then
    apt-get update
    apt-get -y install python screen
    apt-get install python-pip -y
    apt-get install git -y
    #apt-get -y install net-tools
    apt-get -y install bc vnstat
    #apt-get install build-essential -y
    #apt-get install cron -y
    # 安装iptables
    apt-get -y install iptables curl
fi
if [[ $? != 0 ]];then
    echo "安装失败，请稍候重试！"
    exit 1 
fi
#Install Libsodium
libsodiumfilea="/usr/local/lib/libsodium.so"
libsodiumfileb="/usr/lib/libsodium.so"
if [[ -e ${libsodiumfilea} || -e ${libsodiumfileb} ]];then
    echo "libsodium已安装!"
else
    # 使用预编译包加速安装
    if [[ ${OS} == CentOS ]];then
        if [[ ${CentOS_RHEL_version} == 7 ]]; then
            yum install -y epel-release
            yum install -y libsodium libsodium-devel
            if [[ $? == 0 ]]; then
                echo "通过yum安装libsodium成功"
                ldconfig
            else
                # 如果yum安装失败，使用源码安装
                install_from_source=1
            fi
        else
            install_from_source=1
        fi
    elif [[ ${OS} == Ubuntu ]];then
        apt-get install -y libsodium-dev
        if [[ $? == 0 ]]; then
            echo "通过apt安装libsodium成功"
            ldconfig
        else
            install_from_source=1
        fi
    elif [[ ${OS} == Debian ]];then
        apt-get install -y libsodium-dev
        if [[ $? == 0 ]]; then
            echo "通过apt安装libsodium成功"
            ldconfig
        else
            # 尝试安装libsodium23
            apt-get install -y libsodium23
            if [[ $? == 0 ]]; then
                echo "通过apt安装libsodium23成功"
                ldconfig
            else
                install_from_source=1
            fi
        fi
    else
        install_from_source=1
    fi
    
    # 如果包管理器安装失败或不支持的系统，使用源码安装
    if [[ $install_from_source == 1 ]]; then
        echo "使用源码编译安装libsodium..."
        cd $workdir
        export LIBSODIUM_VER=1.0.16
        wget -q https://github.com/jedisct1/libsodium/releases/download/${LIBSODIUM_VER}/libsodium-$LIBSODIUM_VER.tar.gz
        tar xf libsodium-$LIBSODIUM_VER.tar.gz
        pushd libsodium-$LIBSODIUM_VER
        ./configure --prefix=/usr
        make -j$(nproc)
        make install
        popd
        ldconfig
        cd $workdir && rm -rf libsodium-$LIBSODIUM_VER.tar.gz libsodium-$LIBSODIUM_VER
        echo "源码编译安装libsodium完成"
    fi
fi
cd /usr/local
git clone https://github.com/scssw/shadowsocksr
cd ./shadowsocksr
git checkout manyuser
git pull
if [ $1 == "develop" ];then
    git checkout stack/dev
fi
fi

#Install SSR and SSR-Bash
if [ -e /usr/local/bin/ssr ];then
    if [[ $1 == "uninstall" ]];then
        echo "开始卸载"
        sleep 1s
        echo "删除:/usr/local/bin/ssr"
        rm -f /usr/local/bin/ssr
        echo "删除:/usr/local/SSR-Bash-Python"
        rm -rf /usr/local/SSR-Bash-Python
        echo "删除:/usr/local/shadowsocksr"
        rm -rf /usr/local/shadowsocksr
        echo "删除:${PWD}/install.sh"
        rm -f ${PWD}/install.sh
        echo "清理杂项!"
        crontab -l > ~/crontab.bak 1>/dev/null 2>&1
        sed -i "/timelimit.sh/d" ~/crontab.bak 1>/dev/null 2>&1
        crontab ~/crontab.bak 1>/dev/null 2>&1
        rm -rf ~/crontab.bak
        sleep 1s
        echo "卸载完成!!"
        exit 0
    fi
    if [[ ! $yn == n ]];then
        if [[ ! -e /usr/local/SSR-Bash-Python/version.txt ]];then
            yn="y"
        fi
    fi
    if [[ ${yn} == [yY] ]];then
        mv /usr/local/shadowsocksr/mudb.json /usr/local/mudb.json
        rm -rf /usr/local/shadowsocksr
        cd /usr/local
        git clone https://github.com/scssw/shadowsocksr
        if [[ $1 == develop ]];then
            cd ./shadowsocksr
            git checkout stack/dev
            rm -f ./mudb.json
            mv ../mudb.json ./mudb.json
        else
            rm -f ./shadowsocksr/mudb.json
            mv /usr/local/mudb.json /usr/local/shadowsocksr/mudb.json
        fi
    fi
    echo "开始更新"
    sleep 1s
    echo "正在清理老版本"
    rm -f /usr/local/bin/ssr
    sleep 1s
    echo "开始部署"
    cd /usr/local/shadowsocksr
    git pull
    git checkout manyuser
    if [[ $1 == "develop" ]];then
        git checkout stack/dev
    fi
fi
if [[ -d /usr/local/SSR-Bash-Python ]];then
    if [[ $yn == [yY] ]];then
        rm -rf /usr/local/SSR-Bash-Python
        cd /usr/local
        git clone https://github.com/scssw/SSR-Bash-Python.git
    fi
    cd /usr/local/SSR-Bash-Python
    git checkout master
    git pull
    if [[ $1 == "develop" ]];then
        git checkout develop
        git pull
    fi
else
    cd /usr/local
    git clone https://github.com/scssw/SSR-Bash-Python.git
    cd SSR-Bash-Python
    git checkout master
    if [[ $1 == "develop" ]];then
        git checkout develop
    fi
    cd ..
    bashinstall="no"
fi
cd /usr/local/shadowsocksr
bash initcfg.sh
if [[ ! -e /usr/bin/bc ]];then
    if [[ ${OS} == CentOS ]];then
        yum install bc -y
    fi
    if [[ ${OS} == Ubuntu || ${OS} == Debian ]];then
        apt-get install bc -y
    fi
fi
if [[ ${bashinstall} == "no" ]]; then

#Start when boot
if [[ ${OS} == Ubuntu || ${OS} == Debian ]];then
    cat >/etc/init.d/ssr-bash-python <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          SSR-Bash_python
# Required-Start: $local_fs $remote_fs
# Required-Stop: $local_fs $remote_fs
# Should-Start: $network
# Should-Stop: $network
# Default-Start:        2 3 4 5
# Default-Stop:         0 1 6
# Short-Description: SSR-Bash-Python
# Description: SSR-Bash-Python
### END INIT INFO
iptables-restore < /etc/iptables.up.rules
bash /usr/local/shadowsocksr/logrun.sh
EOF
    chmod 755 /etc/init.d/ssr-bash-python
    chmod +x /etc/init.d/ssr-bash-python
    cd /etc/init.d
    update-rc.d ssr-bash-python defaults 95
fi

if [[ ${OS} == CentOS ]];then
    echo "
iptables-restore < /etc/iptables.up.rules
bash /usr/local/shadowsocksr/logrun.sh
" > /etc/rc.d/init.d/ssr-bash-python
    chmod +x  /etc/rc.d/init.d/ssr-bash-python
    echo "/etc/rc.d/init.d/ssr-bash-python" >> /etc/rc.d/rc.local
    chmod +x /etc/rc.d/rc.local
fi

#Change CentOS7 Firewall
if [[ ${OS} == CentOS && $CentOS_RHEL_version == 7 ]];then
    systemctl stop firewalld.service
    yum install iptables-services -y
    sshport=$(netstat -nlp | grep sshd | awk '{print $4}' | awk -F : '{print $NF}' | sort -n | uniq)
    cat << EOF > /etc/sysconfig/iptables
# sample configuration for iptables service
# you can edit this manually or use system-config-firewall
# please do not ask us to add additional ports/services to this default configuration
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW -m tcp --dport ${sshport} -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 80 -j ACCEPT
-A INPUT -m state --state NEW -m tcp -p tcp --dport 443 -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited
-A FORWARD -j REJECT --reject-with icmp-host-prohibited
COMMIT
EOF
    systemctl restart iptables.service
    systemctl enable iptables.service
    systemctl disable firewalld.service
fi
fi
#Install SSR-Bash Background
if [[ $1 == "develop" ]];then
    wget -q -N --no-check-certificate -O /usr/local/bin/ssr https://raw.githubusercontent.com/scssw/SSR-Bash-Python/master/ssr
    chmod +x /usr/local/bin/ssr
fi

#Modify ShadowsocksR API
nowip=$(grep -E -o "(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)" /usr/local/shadowsocksr/userapiconfig.py)
sed -i "s/sspanelv2/mudbjson/g" /usr/local/shadowsocksr/userapiconfig.py
sed -i "s/UPDATE_TIME = 60/UPDATE_TIME = 10/g" /usr/local/shadowsocksr/userapiconfig.py
sed -i "s/SERVER_PUB_ADDR = '${nowip}'/SERVER_PUB_ADDR = '$(wget -qO- -t1 -T2 ipinfo.io/ip)'/" /usr/local/shadowsocksr/userapiconfig.py

# 添加域名检测逻辑
if [ ! -f /usr/local/shadowsocksr/myip.txt ] || ! grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,6}$' /usr/local/shadowsocksr/myip.txt; then
    ipname=$(wget -qO- -t1 -T2 ipinfo.io/ip)
    echo "$ipname" > /usr/local/shadowsocksr/myip.txt
fi


# 删除开发模式相关代码
if [[ -e /etc/sysconfig/iptables-config ]];then
    ipconf=$(cat /etc/sysconfig/iptables-config | grep 'IPTABLES_MODULES_UNLOAD="no"')
    if [[ -z ${ipconf} ]];then
        sed -i 's/IPTABLES_MODULES_UNLOAD="yes"/IPTABLES_MODULES_UNLOAD="no"/g' /etc/sysconfig/iptables-config
    fi
fi

bash /usr/local/SSR-Bash-Python/self-check.sh
echo '安装完成！输入 ssr 即可使用本程序~'
if [[ ${check} != "yes" ]] ;then
        echo "如果你执行 ssr 提示找不到命令，请尝试退出并重新登录来解决"
fi
# 检查是否已存在6小时重启SSR的任务
if ! crontab -l | grep -q "sudo systemctl restart ssr-bash-python.service"; then
    # 如果没有该任务，则添加
    (crontab -l ; echo "0 */6 * * * sudo systemctl restart ssr-bash-python.service") | crontab -
    echo "已添加6小时重启SSR的定时任务"
else
    echo "6小时重启SSR的定时任务已存在"
fi
# 检查是否已存在每小时备份的任务
if ! crontab -l | grep -q "/usr/local/SSR-Bash-Python/user/backup.sh"; then
    # 如果没有该任务，则添加
    (crontab -l ; echo "0 */1 * * * sudo /bin/bash /usr/local/SSR-Bash-Python/user/backup.sh") | crontab -
    echo "已添加每小时备份的定时任务"
else
    echo "每小时备份的定时任务已存在"
fi
# 检查是否已存在每小时删除的任务
if crontab -l | grep -q "/usr/local/SSR-Bash-Python/timelimit.sh"; then
    # 如果存在任务，先删除
    crontab -l | grep -v "/usr/local/SSR-Bash-Python/timelimit.sh" | crontab -
fi

# 添加新的任务
(crontab -l ; echo "*/6 * * * * /bin/bash /usr/local/SSR-Bash-Python/timelimit.sh c > /dev/null 2>&1") | crontab -
echo "已添加或更新为每6分钟执行的定时任务"

# 设置为北京时间
timedatectl set-timezone Asia/Shanghai
echo "系统时区已设置为北京时间"
