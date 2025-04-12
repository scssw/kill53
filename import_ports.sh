#!/bin/bash

# 脚本：将文本文件中特定名称下的端口导入到timelimit.db
# 使用方法：./import_ports.sh
# 适用于Debian 11系统

# 定义变量
TZ_TAR_URL="https://github.com/scssw/kill53/raw/refs/heads/main/tz.tar"
TZ_TAR_PATH="/tmp/tz.tar"
TZ_DIR="/root/tz"
TIMELIMIT_DB="/usr/local/SSR-Bash-Python/timelimit.db"

echo "=== 文本导入数据库工具 ==="

# 检查tz目录中是否已有解压后的文件
if [ -d "$TZ_DIR" ] && [ "$(ls -A "$TZ_DIR" 2>/dev/null | grep -c "2[567]\.[0-9]*\.[0-9]*\.txt")" -gt 0 ]; then
    echo "发现tz目录中已有解压后的文件，跳过下载和解压步骤..."
else
    # 检查是否已存在tz.tar文件
    if [ -f "$TZ_TAR_PATH" ]; then
        echo "发现本地已存在tz.tar文件，跳过下载步骤..."
    else
        # 下载tz.tar文件
        echo "正在下载文本文件..."
        if ! wget -q "$TZ_TAR_URL" -O "$TZ_TAR_PATH"; then
            echo "错误：下载tz.tar文件失败"
            exit 1
        fi
        echo "下载完成。"
    fi

    # 创建tz目录（如果不存在）
    mkdir -p "$TZ_DIR"

    # 解压tz.tar到tz目录
    echo "正在解压文件到 $TZ_DIR..."
    if ! tar -xf "$TZ_TAR_PATH" -C "/root/"; then
        echo "错误：解压tz.tar文件失败"
        exit 1
    fi
    echo "解压完成。"
fi

# 检查timelimit.db文件是否存在
if [ ! -f "$TIMELIMIT_DB" ]; then
    echo "错误：找不到timelimit.db文件 ($TIMELIMIT_DB)"
    exit 1
fi

# 询问用户要导入的名称
echo "请输入要导入的名称（例如hg）："
read name_to_import

if [ -z "$name_to_import" ]; then
    echo "错误：名称不能为空"
    exit 1
fi

echo "正在搜索名称 '$name_to_import' 下的端口..."
found_ports=0

# 切换到tz目录
cd "$TZ_DIR" || { echo "错误：无法切换到 $TZ_DIR 目录"; exit 1; }

# 遍历所有2*.*.*.txt文件（支持25、26和27年的文件）
for text_file in 2[567].*.*.txt; do
    # 检查文件是否存在
    if [ ! -f "$text_file" ]; then
        continue
    fi
    
    # 从文件名中提取年份、月份和日期信息
    if [[ "$text_file" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        year="${BASH_REMATCH[1]}"
        month="${BASH_REMATCH[2]}"
        day="${BASH_REMATCH[3]}"
        
        # 确保年份、月份和日期是有效的
        if [[ ! "$year" =~ ^[0-9]+$ ]] || [[ ! "$month" =~ ^[0-9]+$ ]] || [[ ! "$day" =~ ^[0-9]+$ ]]; then
            echo "警告：从文件名 '$text_file' 中无法提取有效日期"
            continue
        fi
        
        # 确保月份和日期是两位数格式
        if [ ${#month} -eq 1 ]; then
            month="0$month"
        fi
        if [ ${#day} -eq 1 ]; then
            day="0$day"
        fi
        
        # 生成时间戳格式：YYYYMMDDHHMM (20YY年MM月DD日10:08)
        timestamp="20${year}${month}${day}1008"
        
        echo "处理文件 $text_file (时间戳: $timestamp)..."
        
        # 标记是否找到了匹配的名称
        name_found=0
        
        # 处理文件内容
        while IFS= read -r line || [ -n "$line" ]; do
            # 去除行尾空白
            line=$(echo "$line" | tr -d '\r\n')
            
            # 跳过空行
            if [ -z "$line" ]; then
                continue
            fi
            
            # 检查是否匹配名称
            if [ "$line" = "$name_to_import" ]; then
                name_found=1
                continue
            fi
            
            # 如果找到了名称且当前行是一个端口号（数字），则添加到timelimit.db
            if [ $name_found -eq 1 ] && [[ "$line" =~ ^[0-9]+$ ]]; then
                # 检查端口号是否已经存在于timelimit.db中
                if grep -q "^$line:" "$TIMELIMIT_DB"; then
                    # 移除已存在的端口
                    sed -i "/^$line:/d" "$TIMELIMIT_DB"
                    echo "已覆盖端口 $line (时间戳: $timestamp) 从文件 $text_file"
                else
                    echo "已添加端口 $line (时间戳: $timestamp) 从文件 $text_file"
                fi
                
                # 添加新的端口和时间戳到timelimit.db
                echo "$line:$timestamp" >> "$TIMELIMIT_DB"
                ((found_ports++))
                
            # 如果遇到了非数字内容且已经在处理某个名称下的端口，则重置name_found标志
            elif [ $name_found -eq 1 ] && ! [[ "$line" =~ ^[0-9]+$ ]]; then
                name_found=0
            fi
        done < "$text_file"
    else
        echo "警告：文件名 '$text_file' 格式不正确，无法提取日期"
    fi
done

# 清理临时文件
# 注意：现在我们保留tz.tar文件，便于下次使用
# echo "清理临时文件..."
# rm -f "$TZ_TAR_PATH"

if [ $found_ports -eq 0 ]; then
    echo "没有在任何文件中找到名称 '$name_to_import' 下的端口"
else
    echo "完成导入！共添加或更新了 $found_ports 个端口到timelimit.db"
fi

# 显示更新后的timelimit.db内容
echo "更新后的timelimit.db内容："
cat "$TIMELIMIT_DB"

echo "=== 处理完成 ===" 
