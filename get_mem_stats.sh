#!/bin/bash
#set -o xtrace

#Parameter Check
if [ $# != 2 ]; then
    echo "======== Invalid Parameter!"
    echo "======== Usage:$0 ./csv-file-name key[all | other]"
    exit 1
fi

output_file=$1
key=$2

sleep 2

#Get pid array
if [[ $key == "all" ]]; then
    pid_array=`ps -A | grep -v CMD | awk '{print $1}'`
else
    pid_array=`ps -A | grep $key | awk '{print $1}'`
fi

for pid in $pid_array; do
    pid_name=`ps -p $pid | grep -v CMD | awk '{print $4}'`
    pid_mem=`cat /proc/$pid/status | grep VmRSS | cut -d : -f 2 | tr -cd "[0-9]"`
    if [[ $pid_mem != "" ]]; then
        echo  "$pid_name,$pid_mem" >> $output_file
    fi
done
