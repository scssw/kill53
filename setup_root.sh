#!/bin/bash
echo "设置你的ROOT密码"
passwd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
service sshd restart
echo "ROOT登录设置完毕！"
