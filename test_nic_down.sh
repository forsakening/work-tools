#!/bin/bash
#create @20170808 by zx
#set -o xtrace

host_list=("172.16.55.160" "172.16.55.161" "172.16.55.162")
nic_list=("br_enp8s0f0" "br_enp6s0f0" "br_enp3s0f0")

host_size=${#host_list[@]}

function print_info()
{
    cur_date=`date "+%Y-%m-%d %H:%M:%S"`
    echo -e "\e[1;32m[$cur_date INFO]$1\e[0m"
    echo "[$cur_date INFO]$1" >> /var/log/nic_down.log
}

function print_warn()
{
    cur_date=`date "+%Y-%m-%d %H:%M:%S"`
    echo -e "\e[1;33m[$cur_date WARN]$1\e[0m"
    echo "[$cur_date WARN]$1" >> /var/log/nic_down.log
}

function print_err()
{
    cur_date=`date "+%Y-%m-%d %H:%M:%S"`
    echo -e "\e[1;31m[$cur_date ERROR]$1\e[0m"
    echo "[$cur_date ERROR]$1" >> /var/log/nic_down.log
}

function check_rmq()
{
	controller_info=`ssh $1 "docker ps | grep controller"`
	controller_id=`echo $controller_info | awk '{print $1}'`
    if [[ $controller_id == "" ]];then
        print_info "$1 has no controller node,skip check rmq ..."
        return 0
    fi
    
	rmq_status=`ssh $1 "docker exec $controller_id systemctl status rabbitmq-server | grep running"`
	rmq_running=`echo $rmq_status | awk '{print $2}'`	
	if [[ $rmq_running == "active" ]];then
		print_info "$1 controller rmq is running...."
		return 0
	else
		print_err "$1 controller rmq is not running...."
		return 1
	fi
}

function check_mysql()
{
	controller_info=`ssh $1 "docker ps | grep controller"`
	controller_id=`echo $controller_info | awk '{print $1}'`
    if [[ $controller_id == "" ]];then
        print_info "$1 has no controller node,skip check mysql ..."
        return 0
    fi
    
	my_status=`ssh $1 "docker exec $controller_id /etc/init.d/mysql status | grep running"`
	my_running=`echo $my_status | awk '{print $3}'`
	if [[ $my_running == "running" ]];then
		print_info "$1 controller mysql is running...."
		return 0
	else
		print_err "$1 controller mysql is not running...."
		return 1
	fi	
		
}

function nic_down()
{
	ssh $1 "ifconfig $2 down"
	print_info "$1 $2 is down ... ok!"
	return 0
}

function nic_up()
{	
	ssh $1 "ifconfig $2 up"
	print_info "$1 $2 is up ... ok!"
	return 0
}

function check_service_loop()
{
    for (( i=0; i<${host_size}; i++ ))
	do
        #check rabbitmq
        rmq_ok=0
        while [[ $rmq_ok == 0 ]]
        do
            check_rmq ${host_list[i]}
            if [ $? != 0 ]; then
                sleep 10
            else
                rmq_ok=1
            fi
        done

        #check rabbitmq
        my_ok=0
        while [[ $my_ok == 0 ]]
        do
            check_mysql ${host_list[i]}
            if [ $? != 0 ]; then
                sleep 10
            else
                my_ok=1
            fi
        done
    done
}

function check_evacuate_done()
{
    down_index=$1
    down_host=${host_list[$down_index]}
    down_compute_info=`ssh $down_host "docker ps | grep compute"`
    down_compute_id=`echo $down_compute_info | awk '{print $1}'`
    if [[ $down_compute_id == "" ]];then
        print_info "$1 has no compute node,skip check evacuate ..."
        return 0
    fi
    
    down_compute_hostname=`ssh $down_host docker exec $down_compute_id cat /etc/hostname`

    next_index=`expr $down_index + 1`
    alive_index=$(( $next_index % $host_size ))
    alive_host=${host_list[$alive_index]}

    alive_controller_info=`ssh $alive_host "docker ps | grep controller"`
    alive_controller_id=`echo $alive_controller_info | awk '{print $1}'`
    alive_controller_ip=`ssh $alive_host docker exec $alive_controller_id ifconfig eth1 | grep inet | grep -v inet6 | awk '{print $2}'`

    evacuate_ok=0
    while [[ $evacuate_ok == 0 ]]
    do
        ssh $alive_host "docker exec $alive_controller_id ssh $alive_controller_ip 'source /opt/admin-openrc.sh && nova list --host $down_compute_hostname | wc -l' " > ./nova_num
        nova_num=`cat ./nova_num`
        if [[ $nova_num == 4 ]];then
            evacuate_ok=1
            print_info "$down_compute_hostname evacuate ok !!!"
        else
            print_warn "$down_compute_hostname evacuate still not ok ..."
            sleep 30
        fi
    done
}

function check_evacuate_clean()
{
    down_index=$1
    down_host=${host_list[$down_index]}
    down_compute_info=`ssh $down_host "docker ps | grep compute"`
    down_compute_id=`echo $down_compute_info | awk '{print $1}'`
    if [[ $down_compute_id == "" ]];then
        print_info "$1 has no compute node,skip check evacuate clean ..."
        return 0
    fi
    
    down_compute_ip=`ssh $down_host docker exec $down_compute_id ifconfig eth1 | grep inet | grep -v inet6 | awk '{print $2}'`
    down_compute_hostname=`ssh $down_host docker exec $down_compute_id cat /etc/hostname`

    next_index=`expr $down_index + 1`
    alive_index=$(( $next_index % $host_size ))
    alive_host=${host_list[$alive_index]}

    alive_controller_info=`ssh $alive_host "docker ps | grep controller"`
    alive_controller_id=`echo $alive_controller_info | awk '{print $1}'`
    alive_controller_ip=`ssh $alive_host docker exec $alive_controller_id ifconfig eth1 | grep inet | grep -v inet6 | awk '{print $2}'`
    
    evacuate_clean=0
    while [[ $evacuate_clean == 0 ]]
    do
        #获取被down的主机所在的nova list是否为空
        ssh $alive_host "docker exec $alive_controller_id ssh $alive_controller_ip 'source /opt/admin-openrc.sh && nova list --host $down_compute_hostname | wc -l' " > ./nova_num
        nova_num=`cat ./nova_num`
        
        #插上网线后，获取之前被down的主机所在的compute上的virsh list是否为空
        ssh $alive_host "docker exec $alive_controller_id ssh $down_compute_ip 'source /opt/admin-openrc.sh && virsh list | wc -l' " > ./virsh_num
        virsh_num=`cat ./virsh_num`
        
        if [[ $nova_num == 4 && $virsh_num == 3 ]];then
            evacuate_clean=1
            print_info "$down_compute_hostname evacuate clean ok !!!"
        else
            print_warn "$down_compute_hostname evacuate still not clean ..."
            sleep 30
        fi
    done
}

function do_task()
{
	for (( j=0; j<${host_size}; j++ ))
	do
		check_service_loop
        sleep 30
		nic_down ${host_list[j]} ${nic_list[j]}
        check_evacuate_done $j
        sleep 30
        nic_up ${host_list[j]} ${nic_list[j]}
        sleep 30
        check_evacuate_clean $j
	done 
	return 0
}

while [[ "1" != "0" ]]
do
    do_task 
done
