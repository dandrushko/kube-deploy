#!/bin/bash
wget -O - https://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.11/SALTSTACK-GPG-KEY.pub | sudo apt-key add -
echo "deb http://repo.saltstack.com/apt/ubuntu/16.04/amd64/2016.11 xenial main" > /etc/apt/sources.list.d/salt.list
apt update
apt-get install -y salt-minion
rm /etc/salt/minion_id
rm -f /etc/salt/pki/minion/minion_master.pub
echo "id: $(hostname).kube-deploy.local" > /etc/salt/minion
echo "master: 192.168.10.100" >> /etc/salt/minion
service salt-minion restart
