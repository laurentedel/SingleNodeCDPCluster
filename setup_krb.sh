#! /bin/bash 
echo "-- Configure and optimize the OS"
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.d/rc.local
echo "echo never > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.d/rc.local
# add tuned optimization https://www.cloudera.com/documentation/enterprise/6/6.2/topics/cdh_admin_performance.html
echo  "vm.swappiness = 1" >> /etc/sysctl.conf
sysctl vm.swappiness=1
timedatectl set-timezone UTC

echo "-- Install Java OpenJDK8 and other tools"
yum install -y java-1.8.0-openjdk-devel vim wget curl git bind-utils rng-tools
yum install -y epel-release
yum install -y python-pip

cp /usr/lib/systemd/system/rngd.service /etc/systemd/system/
systemctl daemon-reload
systemctl start rngd
systemctl enable rngd

echo "-- Installing requirements for Stream Messaging Manager"
yum install -y gcc-c++ make 
curl -sL https://rpm.nodesource.com/setup_10.x | sudo -E bash - 
yum install nodejs -y
npm install forever -g 

# Check input parameters
case "$1" in
        aws)
            echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
            systemctl restart chronyd
            ;;
        azure)
# default root disk in most Azure Centos images is often small so second disk may be needed for /opt
# if you are already using /opt before the CDH install you may need to adjust this step as appropriate
# the temp disk used in the Cloudera Centos image on Azure on /mnt/resource may be an option if not persisting image
#            umount /mnt/resource
#            mount /dev/sdb1 /opt
            echo "server time.windows.com prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
            systemctl restart chronyd
            ;;
        gcp)
            ;;
        *)
            echo $"Usage: $0 {aws|azure|gcp} template-file [docker-device]"
            echo $"example: ./setup.sh azure templates/essential.json"
            echo $"example: ./setup.sh aws template/cml.json /dev/xvdb"
            exit 1
esac

TEMPLATE=$2
DOCKERDEVICE=$3

echo "-- Configure networking"
PUBLIC_IP=`curl https://api.ipify.org/`
hostnamectl set-hostname `hostname -f`
echo "`hostname -I` `hostname`" >> /etc/hosts
sed -i "s/HOSTNAME=.*/HOSTNAME=`hostname`/" /etc/sysconfig/network
systemctl disable firewalld
systemctl stop firewalld
setenforce 0
sed -i 's/SELINUX=.*/SELINUX=disabled/' /etc/selinux/config


echo "-- Install CM and MariaDB"

## CM 7
wget https://archive.cloudera.com/cm7/7.1.3/redhat7/yum/cloudera-manager-trial.repo -P /etc/yum.repos.d/

yum clean all
rm -rf /var/cache/yum/
yum repolist

## CM
yum install -y cloudera-manager-agent cloudera-manager-daemons cloudera-manager-server

## PostgreSQL
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
yum install -y postgresql10-server
sed -i '1 i\host all all 127.0.0.1/32 md5' /var/lib/pgsql/10/data/pg_hba.conf
echo "listen_addresses = '0.0.0.0'" >> /var/lib/pgsql/10/data/postgres.conf
/usr/pgsql-10/bin/postgresql-10-setup initdb
systemctl enable postgresql-10
systemctl start postgresql-10


#echo "-- Install JDBC connector"
#wget https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.46.tar.gz -P ~
#tar zxf ~/mysql-connector-java-5.1.46.tar.gz -C ~
#mkdir -p /usr/share/java/
#cp ~/mysql-connector-java-5.1.46/mysql-connector-java-5.1.46-bin.jar /usr/share/java/mysql-connector-java.jar
#rm -rf ~/mysql-connector-java-5.1.46*

echo "-- Create DBs required by CM"
#mysql -u root < scripts/create_db.sql
sudo -u postgres psql < ./scripts/pgsql_create_db.sql

#echo "-- Secure MariaDB"
#mysql -u root < scripts/secure_mariadb.sql

echo "-- Prepare CM database 'scm'"
/opt/cloudera/cm/schema/scm_prepare_database.sh postgres scm scm cloudera

## PostgreSQL
#yum install -y postgresql-server python-pip
#pip install psycopg2==2.7.5 --ignore-installed
#echo 'LC_ALL="en_US.UTF-8"' >> /etc/locale.conf
#sudo su -l postgres -c "postgresql-setup initdb"
#cat conf/pg_hba.conf > /var/lib/pgsql/data/pg_hba.conf
#cat conf/postgresql.conf > /var/lib/pgsql/data/postgresql.conf
#echo "--Enable and start pgsql"
#systemctl enable postgresql
#systemctl restart postgresql


## PostgreSQL see: https://www.postgresql.org/download/linux/redhat/
#yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm
#yum install -y postgresql96
#yum install -y postgresql96-server
#pip install psycopg2==2.7.5 --ignore-installed

yum -y install python-pip
pip install --upgrade pip
pip install psycopg2==2.7.5 --ignore-installed
echo 'LC_ALL="en_US.UTF-8"' >> /etc/locale.conf

#cat conf/pg_hba.conf > /var/lib/pgsql/9.6/data/pg_hba.conf
#cat conf/postgresql.conf > /var/lib/pgsql/9.6/data/postgresql.conf
#
#echo "--Enable and start pgsql"
#systemctl enable postgresql-9.6
#systemctl start postgresql-9.6
#
#echo "-- Create DBs required by CM"
sudo -u postgres psql <<EOF 
CREATE DATABASE ranger;
CREATE USER ranger WITH PASSWORD 'cloudera';
GRANT ALL PRIVILEGES ON DATABASE ranger TO ranger;
CREATE DATABASE das;
CREATE USER das WITH PASSWORD 'cloudera';
GRANT ALL PRIVILEGES ON DATABASE das TO das;
EOF

echo "-- Enable passwordless root login via rsa key"
ssh-keygen -f ~/myRSAkey -t rsa -N ""
mkdir ~/.ssh
cat ~/myRSAkey.pub >> ~/.ssh/authorized_keys
chmod 400 ~/.ssh/authorized_keys
ssh-keyscan -H `hostname` >> ~/.ssh/known_hosts
sed -i 's/.*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
systemctl restart sshd

echo "-- Start CM, it takes about 2 minutes to be ready"
systemctl start cloudera-scm-server

while [[ -z `curl -s -X GET -u "admin:admin" http://localhost:7180/api/version` ] ;
    do
    echo "waiting 10s for CM to come up..";
    sleep 10;
done

echo "-- Now CM is started and the next step is to automate using the CM API"

pip install --upgrade pip cm_client

sed -i "s/YourHostname/`hostname -f`/g" $TEMPLATE
sed -i "s/YourCDSWDomain/cdsw.$PUBLIC_IP.nip.io/g" $TEMPLATE
sed -i "s/YourPrivateIP/`hostname -I | tr -d '[:space:]'`/g" $TEMPLATE
sed -i "s#YourDockerDevice#$DOCKERDEVICE#g" $TEMPLATE

sed -i "s/YourHostname/`hostname -f`/g" scripts/create_cluster_krb.py

python scripts/create_cluster_krb.py $TEMPLATE
