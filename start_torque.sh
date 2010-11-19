#!/bin/bash
#
# Copyright 2010 Dominique Belhachemi
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# uncomment the following line to enable debugging
set -ex


usage()
{
    cat << EOF

usage: $0 options

This script starts the torque environment.

OPTIONS:

   -h | --help             Show this message
   -n | --torque-nodes     nodes              e.g. "192.168.0.14,192.168.0.14"
   -s | --torque-server    torque server ip   e.g. "192.168.0.13"
   -k | --key              key file
   -v | --verbose          verbose mode
   -m | --with-mpi         with MPI support
        --nfs-server       NFS server

example: start_torque.sh --verbose -s="192.168.0.13" -n="192.168.0.14,192.168.0.17,192.168.0.45" -k="~/.euca/mykey.priv"

EOF
}


function get_hostname_from_ip {
    IP=$1
    HOSTNAME=`nslookup $IP | grep "name =" | awk '{print $4}'`
    # remove the trailing . from HOSTNAME (I get this from nslookup)
    HOSTNAME=${HOSTNAME%.}
    return 0
}

function get_ip_from_hostname {
    HOSTNAME=$1
    IP=`nslookup $HOSTNAME | grep Address | grep -v '#' | cut -f 2 -d ' '`
    return 0
}

function install_package {
    PACKAGE=$1

    if [ "`dpkg-query -W -f='${Status}\n' $PACKAGE`" != "install ok installed" ] ; then
        $SUDO apt-get -o Dpkg::Options::="--force-confnew" --force-yes -y install $PACKAGE
        #aptitude -y install $PACKAGE
        if [ $? -ne 0 ] ; then
            echo "aptitude install $PACKAGE failed"
        fi
    else
        echo "package $PACKAGE is already installed"
    fi
}



# default
VERBOSE=0
IN_INSTANCE=0
MPI=0

# For Debian
SUPERUSER=root
SUDO=

# For Ubuntu
#SUPERUSER=ubuntu
#SUDO=sudo

OverwriteDNS=0

#e.g. guest, ubuntu
OTHERUSER=guest

UseAmazonEucalyptus=1


# values are "public" and "private"
INTERFACE="private"


if [ $UseAmazonEucalyptus -eq 1 ]; then
    echo Script running on `hostname` : `/sbin/ifconfig eth0 | grep "inet addr" | awk '{print $2}' | sed 's/addr\://'` \(Amazon/Eucalyptus\)
else
    echo Script running on `hostname` : `/sbin/ifconfig vboxnet0 | grep "inet addr" | awk '{print $2}' | sed 's/addr\://'` \(VirtualBox\)
fi

if [ $IN_INSTANCE -eq 1 ] ; then
   install_package dnsutils
fi

# parse arguments
for i in $*
do
    case $i in
        -s=*|--torque-server=*)
            # remove option from string
            OPTION_S=`echo $i | sed 's/[-a-zA-Z0-9]*=//'`

            # for now provide only IPs, TODO: is_valid_IP($OPTION_S)
            if [ 1 ] ; then
                PUBLIC_TORQUE_SERVER_IP=$OPTION_S
                get_hostname_from_ip $PUBLIC_TORQUE_SERVER_IP
                PUBLIC_TORQUE_SERVER_HOSTNAME=$HOSTNAME
            else
                PUBLIC_TORQUE_SERVER_HOSTNAME=$OPTION_S
                get_ip_from_hostname $PUBLIC_TORQUE_SERVER_HOSTNAME
                PUBLIC_TORQUE_SERVER_IP=$IP
            fi
            echo PUBLIC_TORQUE_SERVER: $PUBLIC_TORQUE_SERVER_IP $PUBLIC_TORQUE_SERVER_HOSTNAME
            ;;
        -n=*|--torque-nodes=*)
            # remove option from string
            OPTION_N=`echo $i | sed 's/[-a-zA-Z0-9]*=//'`
            PUBLIC_TORQUE_NODES=`echo $OPTION_N | sed 's/\,/ /g'`
            for PUBLIC_TORQUE_NODE in `echo $PUBLIC_TORQUE_NODES`
            do
                # for now provide only IPs, TODO: is_valid_IP($OPTION_S)
                if [ 1 ] ; then
                    PUBLIC_TORQUE_NODE_IP=$PUBLIC_TORQUE_NODE
                    get_hostname_from_ip $PUBLIC_TORQUE_NODE_IP
                    PUBLIC_TORQUE_NODE_HOSTNAME=$HOSTNAME
                else
                    PUBLIC_TORQUE_NODE_HOSTNAME=$PUBLIC_TORQUE_NODE
                    get_ip_from_hostname $PUBLIC_TORQUE_NODE_HOSTNAME
                    PUBLIC_TORQUE_NODE_IP=$IP
                fi
                echo PUBLIC_TORQUE_NODE_IP: $PUBLIC_TORQUE_NODE_IP
                echo PUBLIC_TORQUE_NODE_HOSTNAME: $PUBLIC_TORQUE_NODE_HOSTNAME
                PUBLIC_TORQUE_NODES_IP="$PUBLIC_TORQUE_NODES_IP $PUBLIC_TORQUE_NODE_IP"
                PUBLIC_TORQUE_NODES_HOSTNAME="$PUBLIC_TORQUE_NODES_HOSTNAME $PUBLIC_TORQUE_NODE_HOSTNAME"
            done
            echo PUBLIC_TORQUE_NODES_IP: $PUBLIC_TORQUE_NODES_IP
            echo PUBLIC_TORQUE_NODES_HOSTNAME: $PUBLIC_TORQUE_NODES_HOSTNAME
            ;;
        -k=*|--key=*)
            # remove option from string
            KEY=`echo $i | sed 's/[-a-zA-Z0-9]*=//'`
            echo $KEY
            ;;
        --verbose)
            VERBOSE=1
            ;;
        -i|--in-instance)
            IN_INSTANCE=1
            ;;
        -m=*|--with-mpi=*)
            MPI=0
            ;;
        --nfs-server=*)
            NFS_PUBLIC_SERVER_IP=`echo $i | sed 's/[-a-zA-Z0-9]*=//'`
            ;;
        *)
            echo "unknown option"
            ;;
    esac
done


if [[ -z $PUBLIC_TORQUE_NODES_IP ]] || [[ -z $PUBLIC_TORQUE_SERVER_IP ]]
then
    usage
    exit 1
fi


# generate script
cat > keygen_in_instance.sh << EOF
#!/bin/bash
#$SUDO -u $OTHERUSER mkdir -p /home/$OTHERUSER/.ssh/
su -u $OTHERUSER -c 'mkdir -p /home/$OTHERUSER/.ssh/'
if [ ! -f /home/$OTHERUSER/.ssh/id_rsa ]; then
    #$SUDO -u $OTHERUSER ssh-keygen -t rsa -N "" -f /home/$OTHERUSER/.ssh/id_rsa
    su $OTHERUSER -c 'ssh-keygen -t rsa -N "" -f /home/$OTHERUSER/.ssh/id_rsa'
fi
EOF
chmod 755 keygen_in_instance.sh


# join server and nodes
if [[ $PUBLIC_TORQUE_NODES_IP == *$PUBLIC_TORQUE_SERVER_IP* ]]
then
    ALL_INSTANCES_PUBLIC_IP="$PUBLIC_TORQUE_NODES_IP"
    ALL_INSTANCES_PUBLIC_HOSTNAME="$PUBLIC_TORQUE_NODES_HOSTNAME"
else
    ALL_INSTANCES_PUBLIC_IP="$PUBLIC_TORQUE_SERVER_IP $PUBLIC_TORQUE_NODES_IP"
    ALL_INSTANCES_PUBLIC_HOSTNAME="$PUBLIC_TORQUE_SERVER_HOSTNAME $PUBLIC_TORQUE_NODES_HOSTNAME"
fi
echo ALL_INSTANCES_PUBLIC_IP: $ALL_INSTANCES_PUBLIC_IP
echo ALL_INSTANCES_PUBLIC_HOSTNAME: $ALL_INSTANCES_PUBLIC_HOSTNAME


# BEGIN execution on master #################################################
if [ $IN_INSTANCE -eq 0 ] ; then

    # copy setup-torque-script to instances
    for NODE_IP in `echo $ALL_INSTANCES_PUBLIC_IP`
    do
        echo $NODE_IP

        # make this host known to ~/.ssh/known_hosts on master
        ssh -i $KEY -o StrictHostKeychecking=no $SUPERUSER@$NODE_IP echo private hostname: '`hostname`'

        # copy main script to instance
        scp -p -i $KEY start_torque.sh $SUPERUSER@$NODE_IP:~/

        if [ $MPI == 1 ] ; then
            # copy test mpi script to instance
            scp -p -i $KEY compileMPI.sh helloworld.c $SUPERUSER@$NODE_IP:~/
        fi

        # execute main script in instance to setup torque, TODO, this list is acomma separted list, I should improve it
        INST_PUBLIC_TORQUE_NODES_IP=`echo $PUBLIC_TORQUE_NODES_IP | sed 's/ /\,/g'`
        ssh -X -i $KEY $SUPERUSER@$NODE_IP "~/start_torque.sh" -s=\"$PUBLIC_TORQUE_SERVER_IP\" -n=\"$INST_PUBLIC_TORQUE_NODES_IP\" -i -m=$MPI --nfs-server="$NFS_PUBLIC_SERVER_IP"

    done

    #### The script above added all necessary user to all nodes, now the keys can be distributed

    # TODO, copying the script is probably not necessary, each instance can generate it themself
    for NODE_IP in `echo $ALL_INSTANCES_PUBLIC_IP`
    do
        # copy keygen_in_instance script to instance and execute to generate keys in instances - for user $OTHERUSER

        # copy to $SUPERUSER, but execute as super user under the name $OTHERUSER
        scp -p -i $KEY keygen_in_instance.sh $SUPERUSER@$NODE_IP:~/

        # ececute
        ssh -X -i $KEY $SUPERUSER@$NODE_IP "bash ~/keygen_in_instance.sh" #TODO
    done


    for SRC_NODE_IP in `echo $ALL_INSTANCES_PUBLIC_IP`
    do
        # distribute this key to all other nodes
        for DST_NODE_IP in `echo $ALL_INSTANCES_PUBLIC_IP`
        do
            echo $DST_NODE_IP

            # copy from src to dst
            scp -p -i $KEY $SUPERUSER@$SRC_NODE_IP:/home/$OTHERUSER/.ssh/id_rsa.pub /tmp/id_rsa.pub

            # direct copy from src to dst not possible, why not?
            scp -p -i $KEY /tmp/id_rsa.pub $SUPERUSER@$DST_NODE_IP:/tmp/id_rsa.pub

            ssh -X -i $KEY $SUPERUSER@$DST_NODE_IP "cat /tmp/id_rsa.pub | $SUDO tee -a /home/$OTHERUSER/.ssh/authorized_keys"

        done
        #execute, connect to other server generate entry in known_hosts of $OTHERUSER
        ssh -X -i $KEY $SUPERUSER@$SRC_NODE_IP /tmp/hosts.sh
    done


    # on master don't execute commands for instances
    exit 0
fi
# END   execution on master #################################################











# BEGIN execution in instance ###############################################

echo in instance : `hostname`

export DEBIAN_FRONTEND="noninteractive"
export APT_LISTCHANGES_FRONTEND="none"
CURL="/usr/bin/curl"

#API_VERSION="2008-02-01"
#METADATA_URL="http://169.254.169.254/$API_VERSION/meta-data"

METADATA_URL="http://169.254.169.254/latest/meta-data/"

# those variables are needed for the locales package
export LANGUAGE=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# for dialog frontend
export PATH=$PATH:/sbin:/usr/sbin:/usr/local/sbin
export TERM=linux

DATE=`date '+%Y%m%d'`
NUMBER_PROCESSORS=`cat /proc/cpuinfo | grep processor | wc -l`

# clean-up
$SUDO dpkg --configure -a


# update package source information
$SUDO apt-get -o Dpkg::Options::="--force-confnew" --force-yes -y update
if [ $? -ne 0 ] ; then
    echo "aptitude update failed"
fi

# install lsb-release
install_package lsb-release

# get some information about the Operating System
DISTRIBUTOR=`lsb_release -i | awk '{print $3}'`
CODENAME=`lsb_release -c | awk '{print $2}'`
echo $DISTRIBUTOR $CODENAME


# for Eucalyptus if hostnames are not set properly
if [ $OverwriteDNS -eq 1 ] ; then
    PUBLIC_TORQUE_SERVER_HOSTNAME=ip-`echo $PUBLIC_TORQUE_SERVER_IP | sed 's/\./-/g'`
    echo $PUBLIC_TORQUE_SERVER_IP $PUBLIC_TORQUE_SERVER_HOSTNAME

    PRIVATE_TORQUE_SERVER_HOSTNAME=ip-`echo $PRIVATE_TORQUE_SERVER_IP | sed 's/\./-/g'`
    echo $PRIVATE_TORQUE_SERVER_IP $PRIVATE_TORQUE_SERVER_HOSTNAME

    PUBLIC_INSTANCE_IP=`/sbin/ifconfig eth0 | grep "inet addr" | awk '{print $2}' | sed 's/addr\://'`
    PUBLIC_INSTANCE_HOSTNAME=ip-`echo $PUBLIC_INSTANCE_IP | sed 's/\./-/g'`
    PRIVATE_INSTANCE_HOSTNAME=ip-`echo $PRIVATE_INSTANCE_IP | sed 's/\./-/g'`
fi



# get private interface IP and HOSTNAME from Torque server
get_ip_from_hostname $PUBLIC_TORQUE_SERVER_HOSTNAME
PRIVATE_TORQUE_SERVER_IP=$IP
get_hostname_from_ip $PRIVATE_TORQUE_SERVER_IP
PRIVATE_TORQUE_SERVER_HOSTNAME=$HOSTNAME
echo PRIVATE_TORQUE_SERVER: $PRIVATE_TORQUE_SERVER_IP $PRIVATE_TORQUE_SERVER_HOSTNAME

# get private interface IPs and HOSTNAMEs from Nodes
for PUBLIC_TORQUE_NODE_HOSTNAME in `echo $PUBLIC_TORQUE_NODES_HOSTNAME`
do
    get_ip_from_hostname $PUBLIC_TORQUE_NODE_HOSTNAME
    PRIVATE_TORQUE_NODE_IP=$IP
    get_hostname_from_ip $PRIVATE_TORQUE_NODE_IP
    PRIVATE_TORQUE_NODE_HOSTNAME=$HOSTNAME
    echo PRIVATE_TORQUE_NODES: $PRIVATE_TORQUE_NODE_IP $PRIVATE_TORQUE_NODE_HOSTNAME

    # add to list
    PRIVATE_TORQUE_NODES_IP="$PRIVATE_TORQUE_NODES_IP $PRIVATE_TORQUE_NODE_IP"
    PRIVATE_TORQUE_NODES_HOSTNAME="$PRIVATE_TORQUE_NODES_HOSTNAME $PRIVATE_TORQUE_NODE_HOSTNAME"
done
echo PRIVATE_TORQUE_NODES: $PRIVATE_TORQUE_NODES_IP $PRIVATE_TORQUE_NODES_HOSTNAME

# join server and nodes
if [[ $PRIVATE_TORQUE_NODES_IP == *$PRIVATE_TORQUE_SERVER_IP* ]]
then
    ALL_INSTANCES_PRIVATE_IP="$PRIVATE_TORQUE_NODES_IP"
    ALL_INSTANCES_PRIVATE_HOSTNAME="$PRIVATE_TORQUE_NODES_HOSTNAME"
else
    ALL_INSTANCES_PRIVATE_IP="$PRIVATE_TORQUE_SERVER_IP $PRIVATE_TORQUE_NODES_IP"
    ALL_INSTANCES_PRIVATE_HOSTNAME="$PRIVATE_TORQUE_SERVER_HOSTNAME $PRIVATE_TORQUE_NODES_HOSTNAME"
fi
echo ALL_INSTANCES_PRIVATE_IP: $ALL_INSTANCES_PRIVATE_IP
echo ALL_INSTANCES_PRIVATE_HOSTNAME: $ALL_INSTANCES_PRIVATE_HOSTNAME


# get instance information
PUBLIC_INSTANCE_IP=`curl -s $METADATA_URL/public-ipv4`
PUBLIC_INSTANCE_HOSTNAME=`curl -s $METADATA_URL/public-hostname`
echo $PUBLIC_INSTANCE_IP $PUBLIC_INSTANCE_HOSTNAME

PRIVATE_INSTANCE_IP=`/sbin/ifconfig eth0 | grep "inet addr" | awk '{print $2}' | sed 's/addr\://'`
get_hostname_from_ip $PRIVATE_TORQUE_SERVER_IP
PRIVATE_INSTANCE_HOSTNAME=$HOSTNAME
echo $PRIVATE_INSTANCE_IP $PRIVATE_INSTANCE_HOSTNAME


#using PUBLIC or PRIVATE interface
if [ $INTERFACE == "public" ] ; then
    INSTANCE_IP=$PUBLIC_INSTANCE_IP
    INSTANCE_HOSTNAME=$PUBLIC_INSTANCE_HOSTNAME
    TORQUE_SERVER_IP=$PUBLIC_TORQUE_SERVER_IP
    TORQUE_SERVER_HOSTNAME=$PUBLIC_TORQUE_SERVER_HOSTNAME
    NODES_IP=$PUBLIC_TORQUE_NODES_IP
    NODES_HOSTNAME=$PUBLIC_TORQUE_NODES_HOSTNAME
    ALL_INSTANCES_IP=$ALL_INSTANCES_PUBLIC_IP
    ALL_INSTANCES_HOSTNAME=$ALL_INSTANCES_PUBLIC_HOSTNAME
else
    if [ $INTERFACE == "private" ] ; then
        INSTANCE_IP=$PRIVATE_INSTANCE_IP
        INSTANCE_HOSTNAME=$PRIVATE_INSTANCE_HOSTNAME
        TORQUE_SERVER_IP=$PRIVATE_TORQUE_SERVER_IP
        TORQUE_SERVER_HOSTNAME=$PRIVATE_TORQUE_SERVER_HOSTNAME
        NODES_IP=$PRIVATE_TORQUE_NODES_IP
        NODES_HOSTNAME=$PRIVATE_TORQUE_NODES_HOSTNAME
        ALL_INSTANCES_IP=$ALL_INSTANCES_PRIVATE_IP
        ALL_INSTANCES_HOSTNAME=$ALL_INSTANCES_PRIVATE_HOSTNAME
    else
        echo "please specify private or public interface"
    fi
fi


## fix /tmp directory in debian eucalyptus image
#chmod 777 /tmp
# using Google's nameserver
#echo "nameserver 8.8.8.8" >> /etc/resolv.conf


## add user to all nodes
if id $OTHERUSER > /dev/null 2>&1
then
    echo "user exist!"
else
    $SUDO adduser $OTHERUSER --disabled-password --gecos ""
fi


# for torque on Ubuntu
if [ $DISTRIBUTOR == Ubuntu ] ; then
    echo "deb http://us-east-1.ec2.archive.ubuntu.com/ubuntu/ $CODENAME multiverse" | $SUDO tee -a /etc/apt/sources.list
fi

#echo "deb http://ftp.us.debian.org/debian sid main" > /etc/apt/sources.list
#echo "deb http://ftp.us.debian.org/debian squeeze main" > /etc/apt/sources.list
#echo "deb http://security.debian.org/ squeeze/updates main" >> /etc/apt/sources.list

# update package source information
$SUDO apt-get -o Dpkg::Options::="--force-confnew" --force-yes -y update
if [ $? -ne 0 ] ; then
    echo "aptitude update failed"
fi

# get rid of some error messages because of missing locales package
install_package locales
$SUDO rm -f /etc/locale.gen
echo "en_US.UTF-8 UTF-8" | $SUDO tee -a /etc/locale.gen
$SUDO locale-gen

# install portmap for NFS
install_package portmap
install_package nfs-common


# install nmap
install_package nmap
nmap localhost -p 1-20000


# install ntpdate
install_package ntpdate
###ntpdate pool.ntp.org
$SUDO ntpdate ntp.ubuntu.com


# install OpenMPI packages
#if [ $MPI == 1 ] ; then
#    install_package "linux-headers-2.6.35-22-virtual"
#fi

# install OpenMPI packages
if [ $MPI == 1 ] ; then
    install_package "libopenmpi-dev"
    install_package "openmpi-bin"

    #compile MPI test program
    bash compileMPI.sh
fi
exit 0

# make hostnames known to all the TORQUE nodes and server/scheduler
if [ $OverwriteDNS -eq 1 ] ; then

    if [ $INTERFACE == "private" ] ; then
        for NODE_IP in `echo $PRIVATE_NODES_IP`
        do
            NODE_HOSTNAME=ip-`echo $NODE_IP | sed 's/\./-/g'`
            echo "$NODE_IP   $NODE_HOSTNAME" >> /etc/hosts
        done
    fi


    if [ $INTERFACE == "public" ] ; then
        for NODE_IP in `echo $PUBLIC_NODES_IP`
        do
            NODE_HOSTNAME=ip-`echo $NODE_IP | sed 's/\./-/g'`
            if [ $INSTANCE_IP != $TORQUE_SERVER_IP ] || [ $NODE_IP != $TORQUE_SERVER_IP ]; then
                if ! egrep -q "$NODE_IP|$NODE_HOSTNAME" /etc/hosts ; then
                    echo "$NODE_IP   $NODE_HOSTNAME" >> /etc/hosts
                fi
            fi
        done
    fi

    # on TORQUE server
    if [ $INSTANCE_IP == $TORQUE_SERVER_IP ]; then
        #this one is for the scheduler, if using the public interface
        if ! egrep -q "127.0.1.1|$PUBLIC_INSTANCE_HOSTNAME" /etc/hosts ; then
            echo "127.0.1.1 $PUBLIC_INSTANCE_HOSTNAME" >> /etc/hosts
        fi

    #echo "$PRIVATE_INSTANCE_IP $PRIVATE_INSTANCE_HOSTNAME" >> /etc/hosts
    else
        if ! egrep -q "$TORQUE_SERVER_IP|$TORQUE_SERVER_HOSTNAME" /etc/hosts ; then
            echo "$TORQUE_SERVER_IP $TORQUE_SERVER_HOSTNAME" >> /etc/hosts
        fi
    fi

    # need to set a hostname before installing torque packages
    $SUDO rm -f /etc/hostname
    echo $INSTANCE_HOSTNAME | tee -a /etc/hostname # preserve hostname if rebooting is necessary
    $SUDO hostname $INSTANCE_HOSTNAME # immediately change
    #getent hosts `hostname`
    #PUBLIC_INSTANCE_HOSTNAME=`curl -s $METADATA_URL/public-hostname`
fi


if [ $MPI -eq 1 ] ; then
    $SUDO mkdir -p /etc/torque
    $SUDO rm -f /etc/torque/hostfile
    $SUDO touch /etc/torque/hostfile
    for NODE_HOSTNAME in `echo $NODES_HOSTNAME`
    do
        if ! egrep -q "$NODE_HOSTNAME" /etc/torque/hostfile ; then
            # todo: numer_procs?
            echo "$NODE_HOSTNAME slots=1" | $SUDO tee -a /etc/torque/hostfile
        fi
    done
fi


# install torque packages
if [ $INSTANCE_IP == $TORQUE_SERVER_IP ]; then
    install_package "torque-server torque-scheduler torque-client"

    #NFS
    #install_package "nfs-kernel-server"
fi


if [[ $NODES_IP ==  *$INSTANCE_IP* ]]; then
    install_package "torque-mom torque-client"
fi


# create script to distribute host keys
rm -f /tmp/hosts.sh
for ALL_INSTANCE_IP in `echo $ALL_INSTANCES_IP`
do
    echo "($SUDO su - $OTHERUSER -c \"ssh -t -t -o StrictHostKeychecking=no $OTHERUSER@$ALL_INSTANCE_IP echo ''\")& wait" >> /tmp/hosts.sh
done
# torque is communicating via the hostname
for ALL_INSTANCE_HOSTNAME in `echo $ALL_INSTANCES_HOSTNAME`
do
    echo "($SUDO su - $OTHERUSER -c \"ssh -t -t -o StrictHostKeychecking=no $OTHERUSER@$ALL_INSTANCE_HOSTNAME echo ''\")& wait" >> /tmp/hosts.sh
done
chmod 755 /tmp/hosts.sh



$SUDO rm -f /etc/torque/server_name
echo $TORQUE_SERVER_HOSTNAME | $SUDO tee -a /etc/torque/server_name

# if you don't create this file you will get errors like: qsub: Bad UID for job execution MSG=ruserok failed validating guest/guest from domU-12-31-38-04-1D-C5.compute-1.internal
$SUDO rm -f /etc/hosts.equiv
$SUDO touch /etc/hosts.equiv
for NODE_HOSTNAME in `echo $NODES_HOSTNAME`
do
    if ! egrep -q "$NODE_HOSTNAME" /etc/hosts.equiv ; then
        echo -ne "$NODE_HOSTNAME\n" | $SUDO tee -a /etc/hosts.equiv
    fi
done

## for TORQUE mom
if [[ $NODES_IP == *$INSTANCE_IP* ]]; then

    # kill running process
    if [ ! -z "$(pgrep pbs_mom)" ] ; then
        echo `$SUDO killall -s KILL pbs_mom`
    fi

    # get rid of old logs
    $SUDO rm -f /var/spool/torque/mom_logs/*

    # create new configuration
    $SUDO rm -f /var/spool/torque/mom_priv/config
    echo "\$timeout 120" | $SUDO tee -a /var/spool/torque/mom_priv/config # more options possible (NFS...)
    echo "\$loglevel 5"  | $SUDO tee -a /var/spool/torque/mom_priv/config # more options possible (NFS...)

    # try to start torque-mom (pbs_mom) up to 3 times
    for i in {1..3}
    do
        if [ -z "$(pgrep pbs_mom)" ] ; then
            # pbs_mom is not running
            $SUDO /etc/init.d/torque-mom start
            sleep 1
        else
            # pbs_mom is running
            break
        fi
    done

    # debug
    $SUDO touch /var/spool/torque/mom_logs/$DATE
    $SUDO cat /var/spool/torque/mom_logs/$DATE
fi


## for TORQUE server
if [ $INSTANCE_IP == $TORQUE_SERVER_IP ]; then

    ##NFS server
    #$SUDO mkdir -p /data
    #$SUDO rm -f /etc/exports
    #$SUDO touch /etc/exports
    #for NODE_HOSTNAME in `echo $NODES_HOSTNAME`
    #do
    #    echo -ne "/data $NODE_HOSTNAME(rw,sync,no_subtree_check)\n" | $SUDO tee -a /etc/exports
    #done
    #$SUDO exportfs -ar

    #TORQUE server
    $SUDO rm -f /var/spool/torque/server_priv/nodes
    $SUDO touch /var/spool/torque/server_priv/nodes
    for NODE_HOSTNAME in `echo $NODES_HOSTNAME`
    do
        echo -ne "$NODE_HOSTNAME np=$NUMBER_PROCESSORS\n" | $SUDO tee -a /var/spool/torque/server_priv/nodes
    done

    # TODO: workaround for Debian bug #XXXXXX
    $SUDO /etc/init.d/torque-server stop
    sleep 6
    $SUDO /etc/init.d/torque-server start

    # TODO: workaround for Debian bug #XXXXXX, also catch return code with echo
    echo `$SUDO killall pbs_sched`
    sleep 2
    $SUDO /etc/init.d/torque-scheduler start

#   $SUDO /etc/init.d/torque-server restart
#   $SUDO /etc/init.d/torque-scheduler restart


    $SUDO qmgr -c "s s scheduling=true"
    $SUDO qmgr -c "c q batch queue_type=execution"
    $SUDO qmgr -c "s q batch started=true"
    $SUDO qmgr -c "s q batch enabled=true"
    $SUDO qmgr -c "s q batch resources_default.nodes=1"
    $SUDO qmgr -c "s q batch resources_default.walltime=3600"
    # had to set this for MPI, TODO: double check
    $SUDO qmgr -c "s q batch resources_min.nodes=1"
    $SUDO qmgr -c "s s default_queue=batch"
    # let all nodes submit jobs, not only the server
    $SUDO qmgr -c "s s allow_node_submit=true"
    #$SUDO qmgr -c "set server submit_hosts += $TORQUE_SERVER_IP"
    #$SUDO qmgr -c "set server submit_hosts += $INSTANCE_IP"

    # adding extra nodes
    #$SUDO qmgr -c "create node $INSTANCE_HOSTNAME"

    #debug
    cat /var/spool/torque/server_logs/$DATE
    qstat -q
    pbsnodes -a
    cat /etc/torque/server_name
fi


## for TORQUE worker node
if [[ $NODES_IP == *$INSTANCE_IP* ]]; then
    #NFS
    if ! egrep -q "$NFS_PUBLIC_SERVER_IP" /etc/fstab ; then
        echo -ne "$NFS_PUBLIC_SERVER_IP:/data  /mnt/data  nfs  defaults  0  0\n" | $SUDO tee -a /etc/fstab
    fi
    $SUDO mkdir -p /mnt/data
    $SUDO mount /mnt/data -v
fi

# END   execution in instance ###############################################
exit 0
