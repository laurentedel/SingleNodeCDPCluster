#! /bin/bash
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

function step() {
  printf "\342\217\251 Current step: ${GREEN}$1${NC}\n"
}

step "Installing KDC"

export host=$(hostname -f)
export realm=${realm:-CLOUDERA.COM}
export domain=${domain:-cloudera.com}
export kdcpassword=${kdcpassword:-BadPass#1}
TEMPLATE=$1
PUBLIC_IP=`curl -s icanhazip.com`

set -e
sudo yum -y -q install krb5-server krb5-libs krb5-workstation

sudo tee /etc/krb5.conf > /dev/null << EOF
[logging]
 default = FILE:/var/log/krb5libs.log
 kdc = FILE:/var/log/krb5kdc.log
 admin_server = FILE:/var/log/kadmind.log

[libdefaults]
 default_realm = $realm
 dns_lookup_realm = false
 dns_lookup_kdc = false
 ticket_lifetime = 24h
 renew_lifetime = 7d
 forwardable = true
 default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5
 default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5
 permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5 

[realms]
 $realm = {
  kdc = $host
  admin_server = $host
 }

[domain_realm]
 .$domain = $realm
 $domain = $realm
EOF

mv /var/kerberos/krb5kdc/kdc.conf{,.original}
sudo tee /var/kerberos/krb5kdc/kdc.conf > /dev/null << EOF
[kdcdefaults]
 kdc_ports = 88
 kdc_tcp_ports = 88
[realms]
 ${realm} = {
 acl_file = /var/kerberos/krb5kdc/kadm5.acl
 dict_file = /usr/share/dict/words
 admin_keytab = /var/kerberos/krb5kdc/kadm5.keytab
 supported_enctypes = aes256-cts-hmac-sha1-96:normal aes128-cts-hmac-sha1-96:normal arcfour-hmac-md5:normal
 max_renewable_life = 7d
}
EOF

echo $kdcpassword > passwd
echo $kdcpassword >> passwd
sudo kdb5_util create -s < passwd

sudo service krb5kdc start
sudo service kadmin start
sudo chkconfig krb5kdc on
sudo chkconfig kadmin on

sudo kadmin.local -q "addprinc admin/admin" < passwd
sudo kadmin.local -q "addprinc cloudera-scm/admin" < passwd
rm -f passwd

tee /var/kerberos/krb5kdc/kadm5.acl  > /dev/null << EOF
*/admin@$realm	 *
EOF

sudo service krb5kdc restart
sudo service kadmin restart

echo "Waiting to KDC to restart..."
sleep 10

sudo service krb5kdc status
sudo service kadmin status

kadmin.local -q "modprinc -maxrenewlife 7day krbtgt/${realm}@${realm}"
#echo "For testing KDC run below:"
#echo kadmin -p admin/admin -w $kdcpassword -r $realm -q \"get_principal admin/admin\"
#echo kadmin -p cloudera-scm/admin -w $kdcpassword -r $realm -q \"get_principal cloudera-scm/admin\"

start_dir=$PWD
step "Configuring and optimizing the OS"
# only if we don't have a readonly fs
if [ $(grep "[[:space:]]ro[[:space:],]" /proc/mounts | grep sysfs | grep -c "/sys") -eq 0 ]; then
  echo never > /sys/kernel/mm/transparent_hugepage/enabled
  echo never > /sys/kernel/mm/transparent_hugepage/defrag
  echo "echo never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.d/rc.local
  echo "echo never > /sys/kernel/mm/transparent_hugepage/defrag" >> /etc/rc.d/rc.local
  # add tuned optimization https://www.cloudera.com/documentation/enterprise/6/6.2/topics/cdh_admin_performance.html
  echo  "vm.swappiness = 1" >> /etc/sysctl.conf
  sysctl vm.swappiness=1
fi
timedatectl set-timezone UTC

yum install -y -q chrony
systemctl start chronyd
systemctl enable chronyd

step "Installing Java OpenJDK8 and other tools"
yum install -y -q java-1.8.0-openjdk-devel vim wget curl git bind-utils rng-tools
yum install -y -q epel-release
yum install -y -q jq

cp -f /usr/lib/systemd/system/rngd.service /etc/systemd/system/
systemctl daemon-reload
systemctl start rngd
# systemctl enable rngd

step "Configure networking"
PUBLIC_IP=`curl -s icanhazip.com`
hostnamectl set-hostname `hostname -f`
echo "`hostname -I` `hostname`" >> /etc/hosts
#sed -i "s/HOSTNAME=.*/HOSTNAME=`hostname`/" /etc/sysconfig/network
#systemctl disable firewalld
#systemctl stop firewalld
#setenforce 0
#sed -i 's/SELINUX=.*/SELINUX=disabled/' /etc/selinux/config

step "Installing Cloudera Manager and MariaDB"

## CM 7
wget -q https://archive.cloudera.com/cm7/7.4.4/redhat8/yum/cloudera-manager-trial.repo -P /etc/yum.repos.d/

## MariaDB 10.1
curl -LsS https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-10.4"
#yum install MariaDB-server MariaDB-client MariaDB-common MariaDB-devel mariadb-libs

yum clean all
rm -rf /var/cache/yum/
#yum repolist

## CM
yum install -y -d 2 cloudera-manager-agent cloudera-manager-daemons cloudera-manager-server MariaDB-server MariaDB-client

## MariaDB
cat conf/mariadb.config > /etc/my.cnf

systemctl enable mariadb
systemctl start mariadb

step "Install JDBC connector"
wget -q https://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.46.tar.gz -P ~
tar zxf ~/mysql-connector-java-5.1.46.tar.gz -C ~
mkdir -p /usr/share/java/
cp ~/mysql-connector-java-5.1.46/mysql-connector-java-5.1.46-bin.jar /usr/share/java/mysql-connector-java.jar
rm -rf ~/mysql-connector-java-5.1.46*

step "Create DBs required by CM"
mysql -u root < scripts/create_db.sql

step "Secure MariaDB"
mysql -u root < scripts/secure_mariadb.sql

step "Prepare CM database 'scm'"
/opt/cloudera/cm/schema/scm_prepare_database.sh mysql scm scm cloudera

pip install psycopg2==2.7.5 --ignore-installed
echo 'LC_ALL="en_US.UTF-8"' >> /etc/locale.conf

step "Install and configure PostgreSQL"
## PostgreSQL see: https://www.postgresql.org/download/linux/redhat/
yum localinstall -y bin/*.rpm
/usr/pgsql-9.6/bin/postgresql96-setup initdb
cat conf/pg_hba.conf > /var/lib/pgsql/9.6/data/pg_hba.conf
cat conf/postgresql.conf > /var/lib/pgsql/9.6/data/postgresql.conf

# echo "--Enable and start pgsql"
systemctl enable postgresql-9.6
systemctl start postgresql-9.6

echo "-- Create DBs required by CM"
sudo -u postgres psql <<EOF 
CREATE DATABASE ranger;
CREATE USER ranger WITH PASSWORD 'cloudera';
GRANT ALL PRIVILEGES ON DATABASE ranger TO ranger;
CREATE DATABASE das;
CREATE USER das WITH PASSWORD 'cloudera';
GRANT ALL PRIVILEGES ON DATABASE das TO das;
EOF

# install local CSDs
#mv ~/*.jar /opt/cloudera/csd/
#mv /home/centos/*.jar /opt/cloudera/csd/
#chown cloudera-scm:cloudera-scm /opt/cloudera/csd/*
#chmod 644 /opt/cloudera/csd/*

#echo "-- Install local parcels"
#mv ~/*.parcel ~/*.parcel.sha /opt/cloudera/parcel-repo/
#mv /home/centos/*.parcel /home/centos/*.parcel.sha /opt/cloudera/parcel-repo/
#chown cloudera-scm:cloudera-scm /opt/cloudera/parcel-repo/*

step "Enable passwordless root login via rsa key"
ssh-keygen -f ~/myRSAkey -t rsa -N ""
mkdir -p ~/.ssh
cat ~/myRSAkey.pub >> ~/.ssh/authorized_keys
chmod 400 ~/.ssh/authorized_keys
ssh-keyscan -H `hostname` >> ~/.ssh/known_hosts
# sed -i 's/.*PermitRootLogin.*/PermitRootLogin without-password/' /etc/ssh/sshd_config
systemctl restart sshd

step "Start CM, it takes about 2 minutes to be ready"
systemctl start cloudera-scm-server

while [ `curl -s -X GET -u "admin:admin"  http://localhost:7180/api/version >/dev/null; echo $?` != 0 ]; do
  echo -n "."; sleep 5;
done

echo
step "CM started, automate using the CM API"

wget -q https://bootstrap.pypa.io/pip/2.7/get-pip.py
python ./get-pip.py
pip install -q --upgrade cm_client
#echo "-- Kicking off install from ${start_dir}"
cd ${start_dir}
sed -i "s/YourHostname/`hostname -f`/g" $TEMPLATE
sed -i "s/YourCDSWDomain/cdsw.$PUBLIC_IP.nip.io/g" $TEMPLATE
sed -i "s/YourPrivateIP/`hostname -I | tr -d '[:space:]'`/g" $TEMPLATE
sed -i "s#YourDockerDevice#$DOCKERDEVICE#g" $TEMPLATE

sed -i "s/YourHostname/`hostname -f`/g" scripts/create_cluster_krb.py

step "Deploying cluster - Approx 20mn"
python scripts/create_cluster_krb.py $TEMPLATE

step "Stop/Restart cluster for Kerberos configuration"

echo && echo -n "Stopping Cloudera Management Services..."
curl -s -X POST -u admin:admin http://localhost:7180/api/v44/cm/service/commands/stop >/dev/null
while [ "$(curl -s -X GET -u admin:admin "http://localhost:7180/api/v44/cm/service/commands" -H "accept: application/json"  | jq '.items | length')" != "0" ]; do
  echo -n "."
  sleep 10
done

echo && echo -n "Stopping cluster..."
curl -s -X POST -u admin:admin http://localhost:7180/api/v44/clusters/WWBank/commands/stop >/dev/null
while [ "$(curl -s -X GET -u admin:admin "http://localhost:7180/api/v44/clusters/WWBank/commands/" | jq '.items | length')" != "0" ]; do
  echo -n "."
  sleep 10
done

echo && echo -n "Deploying Kerberos client configuration..."
curl -s -X POST -u admin:admin http://localhost:7180/api/v44/clusters/WWBank/commands/deployClusterClientConfig  -H "Content-Type: application/json" -d "{}" >/dev/null
while [ "$(curl -s -X GET -u admin:admin "http://localhost:7180/api/v44/clusters/WWBank/commands/" | jq '.items | length')" != "0" ]; do
  echo -n "."
  sleep 10
done

echo && echo -n "Starting Cloudera Management Services..."
curl -s -X POST -u admin:admin http://localhost:7180/api/v44/cm/service/commands/start >/dev/null
while [ "$(curl -s -X GET -u admin:admin "http://localhost:7180/api/v44/cm/service/commands" -H "accept: application/json"  | jq '.items | length')" != "0" ]; do
  echo -n "."
  sleep 10
done

echo && echo -n "Starting cluster..."
curl -s -X POST -u admin:admin http://localhost:7180/api/v44/clusters/WWBank/commands/start >/dev/null
while [ "$(curl -s -X GET -u admin:admin "http://localhost:7180/api/v44/clusters/WWBank/commands/" | jq '.items | length')" != "0" ]; do
  echo -n "."
  sleep 10
done

echo "Suppressing swapping alert"
curl -s -X PUT -u admin:admin "http://localhost:7180/api/v44/cm/allHosts/config?message=suppress%20swapping%20warning" -H "Content-Type: application/json" -d '{"items":[{"name":"host_health_suppression_host_memory_swapping","value":true}]}' >/dev/null


# Setup worldwide bank demo using script
#echo "Now setuping worldwide bank demo"
#curl -sSL https://raw.githubusercontent.com/abajwa-hw/masterclass/master/ranger-atlas/setup-dc-703.sh | sudo -E bash


step "Setup WorldWideBank demo"
#run on CDP-DC master node
export enable_kerberos=${enable_kerberos:-true}      ## whether kerberos is enabled on cluster
export atlas_host=${atlas_host:-$(hostname -f)}      ##atlas hostname (if not on current host). Override with your own
export ranger_host=${ranger_host:-$(hostname -f)}    ##ranger hostname (if not on current host). Override with your own

#default settings for cloudcat cluster. You can override for your own setup
# export ranger_password=${ranger_password:-admin123}  
# export atlas_pass=${atlas_pass:-admin}
# export kdc_realm=${kdc_realm:-GCE.CLOUDERA.COM}
# export cluster_name=${cluster_name:-cm}

#default settings for AMI cluster
export ranger_password=${ranger_password:-BadPass#1}
export atlas_pass=${atlas_pass:-BadPass#1}
export kdc_realm=${kdc_realm:-CLOUDERA.COM}
#export cluster_name=${cluster_name:-SingleNodeCluster}
export import_hue_queries=${import_hue_queries:-true}
export import_zeppelin_queries=${import_zeppelin_queries:-true}
export host=$(hostname -f)
export cm_api_ver="v44" 
export cm_password="admin"

yum install -y -q git jq nc

cluster_name=$(curl -s -X GET -u admin:${cm_password} http://localhost:7180/api/${cm_api_ver}/clusters/  | jq '.items[0].name' | tr -d '"')
echo "cluster name is: ${cluster_name}"
 
cd /tmp
git clone https://github.com/laurentedel/masterclass 2>/dev/null
cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
chmod +x *.sh
step "create OS users"
./04-create-os-users.sh  
#bug?
useradd rangerlookup

step "Waiting 60s for Ranger usersync..."
sleep 60

ranger_curl="curl -s -u admin:${ranger_password}"
ranger_url="http://${ranger_host}:6080/service"


#create etl role
${ranger_curl} -X POST -H "Content-Type: application/json" -H "Accept: application/json" ${ranger_url}/public/v2/api/roles  -d @- <<EOF
{
   "name":"Admins",
   "description":"",
   "users":[

   ],
   "groups":[
      {
         "name":"etl",
         "isAdmin":false
      }
   ],
   "roles":[

   ]
}
EOF

#Update Hive service def to enable prohibition policies for Hive
${ranger_curl} -s ${ranger_url}/public/v2/api/servicedef/name/hive \
  | jq '.options = {"enableDenyAndExceptionsInPolicies":"true"}' \
  | jq '.policyConditions = [
{
	  "itemId": 1,
	  "name": "resources-accessed-together",
	  "evaluator": "org.apache.ranger.plugin.conditionevaluator.RangerHiveResourcesAccessedTogetherCondition",
	  "evaluatorOptions": {},
	  "label": "Resources Accessed Together?",
	  "description": "Resources Accessed Together?"
},{
	"itemId": 2,
	"name": "not-accessed-together",
	"evaluator": "org.apache.ranger.plugin.conditionevaluator.RangerHiveResourcesNotAccessedTogetherCondition",
	"evaluatorOptions": {},
	"label": "Resources Not Accessed Together?",
	"description": "Resources Not Accessed Together?"
}
]' > hive.json

${ranger_curl} -s -o /dev/null -i \
  -X PUT -H "Accept: application/json" -H "Content-Type: application/json" \
  -d @hive.json ${ranger_url}/public/v2/api/servicedef/name/hive
sleep 10

echo 
#Import Ranger policies
step "Importing Ranger policies..."
cd ../Scripts/cdp-policies

resource_policies=$(ls Ranger_Policies_ALL_*.json)
tag_policies=$(ls Ranger_Policies_TAG_*.json)

#import resource based policies
${ranger_curl} -X POST -H "Content-Type: multipart/form-data" -H "Content-Type: application/json" -F "file=@${resource_policies}" -H "Accept: application/json"  -F "servicesMapJson=@servicemapping-all.json" "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=hdfs,tag,hbase,yarn,hive,knox,kafka,atlas,solr"

#import tag based policies
${ranger_curl} -X POST -H "Content-Type: multipart/form-data" -H "Content-Type: application/json" -F "file=@${tag_policies}" -H "Accept: application/json"  -F "servicesMapJson=@servicemapping-tag.json" "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=tag"

cd ../../HortoniaMunichSetup

step "Sleeping for 45s..."
sleep 45

step "Creating users in KDC and keytabs"
kadmin.local -q "addprinc -randkey joe_analyst/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey kate_hr/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey log_monitor/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey diane_csr/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey jermy_contractor/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey mark_bizdev/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey john_finance/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey ivanna_eu_hr/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"
kadmin.local -q "addprinc -randkey etl_user/$(hostname -f)@${kdc_realm}" 2>/dev/null | grep --color=never "created"

mkdir -p /etc/security/keytabs
cd /etc/security/keytabs
kadmin.local -q "xst -k joe_analyst.keytab joe_analyst/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k log_monitor.keytab log_monitor/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k diane_csr.keytab diane_csr/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k jermy_contractor.keytab jermy_contractor/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k mark_bizdev.keytab mark_bizdev/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k john_finance.keytab john_finance/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k ivanna_eu_hr.keytab ivanna_eu_hr/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k kate_hr.keytab kate_hr/$(hostname -f)@${kdc_realm}" >/dev/null
kadmin.local -q "xst -k etl_user.keytab etl_user/$(hostname -f)@${kdc_realm}" >/dev/null
chmod +r *.keytab
cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup


kinit -kt /etc/security/keytabs/etl_user.keytab  etl_user/$(hostname -f)@${kdc_realm}
hdfs dfs -mkdir -p /apps/hive/share/udfs/
hdfs dfs -put /opt/cloudera/parcels/CDH/lib/hive/lib/hive-exec.jar /apps/hive/share/udfs/
hdfs  dfs -chown -R hive:hadoop  /apps

step "Importing data..."

cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
./05-create-hdfs-user-folders.sh
./06-copy-data-to-hdfs-dc.sh
# hdfs dfs -ls -R /hive_data

step "Create hive tables..."
beeline -n etl_user -f ./data/HiveSchema-dc.hsql 2>/dev/null
beeline -n etl_user -f ./data/TransSchema-cloud.hsql 2>/dev/null

if [ "${import_hue_queries}" = true  ]; then
   echo "import sample Hue queries..."
   #these were previously exported via: mysqldump -u hue -pcloudera hue desktop_document2 > desktop_document2.sql
   mysql -u hue -pcloudera hue < ./data/desktop_document2.sql
   setfacl -m user:hue:r /etc/shadow     ## enable PAM auth for Hue
fi

sleep 5 

if [ "${import_zeppelin_queries}" = true  ]; then
   echo "importing zeppelin notebooks..."
   cd /var/lib/zeppelin/notebook
   mkdir 2EKX5F5MF
   cp "/tmp/masterclass/ranger-atlas/Notebooks-CDP/Demos _ Security _ WorldWideBank _ Joe-Analyst.json"  ./2EKX5F5MF/note.json

   mkdir 2EMPR5K29
   cp "/tmp/masterclass/ranger-atlas/Notebooks-CDP/Demos _ Security _ WorldWideBank _ Ivanna EU HR.json" ./2EMPR5K29/note.json

   mkdir 2EKHXD4H3
   cp "/tmp/masterclass/ranger-atlas/Notebooks-CDP/Demos _ Security _ WorldWideBank _ etl_user.json" ./2EKHXD4H3/note.json

   mkdir 2EZM9PAXV
   cp "/tmp/masterclass/ranger-atlas/Notebooks-CDP/Demos _ Hive ACID.json" ./2EZM9PAXV/note.json

   mkdir 2EXWA1114
   cp "/tmp/masterclass/ranger-atlas/Notebooks-CDP/Demos _ Hive Merge.json" ./2EXWA1114/note.json

   chown -R  zeppelin:zeppelin /var/lib/zeppelin/notebook 
   
   echo && echo -n "restarting Zeppelin..."
   curl -s -X POST -u admin:${cm_password} http://localhost:7180/api/${cm_api_ver}/clusters/${cluster_name}/services/zeppelin/commands/restart >/dev/null
   sleep 10
   while ! $(nc -z localhost 8885); do echo -n "."; sleep 10; done

   intpr_dir="/tmp/masterclass/ranger-atlas/Scripts/interpreters"
   cd ${intpr_dir}
   echo "In Zeppelin, create shell and jdbc interpreter settings via API from ${PWD}"
   echo "login to zeppelin and grab cookie..."
   id=`curl -s -i --data "userName=etl_user&password=BadPass#1" -X POST http://$(hostname -f):8885/api/login | grep HttpOnly  | tail -1 | grep -Eo 'JSESSIONID=[0-9A-Za-z-]+'`
   #echo "Session id:${id}"
   sleep 1
   echo "Create shell interpreter setting..."
   #echo "curl -v --cookie $id -X POST http://$(hostname -f):8885/api/interpreter/setting -d @${intpr_dir}/shell.json"
   curl -s --cookie $id -X POST http://$(hostname -f):8885/api/interpreter/setting -d @${intpr_dir}/shell.json >/dev/null
   sleep 1
   echo "Create jdbc interpreter setting...."
   hivejar=$(ls /opt/cloudera/parcels/CDH/jars/hive-jdbc-3*-standalone.jar)
   sed -i.bak "s|__hivejar__|${hivejar}|g" ${intpr_dir}/jdbc.json
   #echo "curl -v --cookie $id -X POST http://$(hostname -f):8885/api/interpreter/setting -d @${intpr_dir}/jdbc.json"
   curl -s --cookie $id -X POST http://$(hostname -f):8885/api/interpreter/setting -d @${intpr_dir}/jdbc.json >/dev/null
   sleep 1
   #echo "listing all interpreters settings - jdbc and sh should now be included..."
   #echo "curl -v --cookie $id http://$(hostname -f):8885/api/interpreter/setting | python -m json.tool | grep id"
   #curl -s --cookie $id http://$(hostname -f):8885/api/interpreter/setting | python -m json.tool | grep id
   
   echo && echo -n "restarting Zeppelin..."
   curl -s -X POST -u admin:${cm_password} http://localhost:7180/api/${cm_api_ver}/clusters/${cluster_name}/services/zeppelin/commands/restart >/dev/null
   sleep 10
   while ! $(nc -z localhost 8885); do echo -n "."; sleep 10; done

   setfacl -m user:zeppelin:r /etc/shadow   ## enable PAM auth for zeppelin
fi


cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
sed -i.bak "s/21000/31000/g" env_atlas.sh
sed -i.bak "s/localhost/${atlas_host}/g" env_atlas.sh
sed -i.bak "s/ATLAS_PASS=admin/ATLAS_PASS=${atlas_pass}/g" env_atlas.sh

echo
step "import Atlas tags"
./01-atlas-import-classification.sh

step "create Hbase tables and Kafka topics"
./08-create-hbase-kafka-dc.sh

step "Sleeping for 60s..."
sleep 60
step "associate Hive/Hbase/Kafka/HDFS entities with tags (needed for tag based policies)"
./09-associate-entities-with-tags-dc.sh


#If NiFi is install, attempt to install the demo NiFi flow
if [ -d "/var/lib/nifi/" ] && [ -n "$(ls /var/lib/nifi/)" ]
then
    export cluster_name=$(curl -X GET -u admin:admin http://localhost:7180/api/v40/clusters/  | jq '.items[0].name' | tr -d '"')
    echo "Setting up Nifi / Atlas. cluster_name:${cluster_name} kdc_realm:${kdc_realm} host:${host}"
    cp /tmp/masterclass/ranger-atlas/HortoniaMunichSetup/data/atlas-application.properties /tmp
    sed -i "s/cdp.cloudera.com/${host}/g; s/CLOUDERA.COM/${kdc_realm}/g; s/WWBank/${cluster_name}/g;" /tmp/atlas-application.properties
    chown nifi:nifi /tmp/atlas-application.properties

    cd /var/lib/nifi/
    mv flow.xml.gz flow.xml.gz.orig
    cp /tmp/masterclass/ranger-atlas/HortoniaMunichSetup/data/flow.xml .
    sed -i "s/cdp.cloudera.com/${host}/g; s/CLOUDERA.COM/${kdc_realm}/g; s/WWBank/${cluster_name}/g;" flow.xml
    gzip flow.xml
    chown nifi:nifi flow.xml.gz  

    nifi_keytab=$(find /var/run/cloudera-scm-agent/process/ -name nifi.keytab | tail -1)
    cp ${nifi_keytab} /tmp
    chown nifi:nifi /tmp/nifi.keytab
fi

echo 
step "restarting CMS service..."
curl -s -X POST -u admin:${cm_password} http://localhost:7180/api/${cm_api_ver}/cm/service/commands/restart >/dev/null
sleep 10
while ! $(nc -z localhost 9996); do echo -n "."; sleep 10; done

echo

((sec=SECONDS%60, SECONDS/=60, min=SECONDS%60))
printf "\360\237\225\223 Total time: ${GREEN}%02d'%02d\"" $min $sec
printf "${NC}\n"

step "Setup complete!"

echo && echo "You can access Cloudera Manager on http://$(hostname):7180"
exit 0

-------------------------
#Sample queries (run as joe_analyst)
kinit -kt /etc/security/keytabs/joe_analyst.keytab joe_analyst/$(hostname -f)@${kdc_realm}
beeline

#masking
SELECT surname, streetaddress, country, age, password, nationalid, ccnumber, mrn, birthday FROM worldwidebank.us_customers limit 5

#prohibition
select zipcode, insuranceid, bloodtype from worldwidebank.ww_customers

#tag based deny (EXPIRED_ON)
select fed_tax from finance.tax_2015

#tag based deny (DATA_QUALITY)
select * from cost_savings.claim_savings limit 5


#sparksql
kinit -kt /etc/security/keytabs/joe_analyst.keytab joe_analyst/$(hostname -f)@${kdc_realm}
spark-shell --jars /opt/cloudera/parcels/CDH/jars/hive-warehouse-connector-assembly*.jar     --conf spark.sql.hive.hiveserver2.jdbc.url="jdbc:hive2://$(hostname -f):10000/default;"    --conf "spark.sql.hive.hiveserver2.jdbc.url.principal=hive/$(hostname -f)@${kdc_realm}"    --conf spark.security.credentials.hiveserver2.enabled=false

import com.hortonworks.hwc.HiveWarehouseSession
import com.hortonworks.hwc.HiveWarehouseSession._
val hive = HiveWarehouseSession.session(spark).build()

hive.execute("SELECT surname, streetaddress, country, age, password, nationalid, ccnumber, mrn, birthday FROM worldwidebank.us_customers").show(10)
hive.execute("select zipcode, insuranceid, bloodtype from worldwidebank.ww_customers").show(10)
hive.execute("select * from cost_savings.claim_savings").show(10)


#GA build CM configs:
# 1. HDFS > Enable Ranger plugin for HDFS
# 2. HDFS > add etl group to admins by dfs.permissions.superusergroup=etl
# 3. Kafka > offsets.topic.replication.factor = 1
# 4. Hbase > Enable Atlas Hook=true
# 5. Ranger > ranger.tagsync.atlas.hdfs.instance.cm.ranger.service=cm_hdfs
# 6. Hue > auth_backend=desktop.auth.backend.PamBackend
# 7. HDFS > core-site saftey > hadoop.proxyuser.zeppelin.groups=*, hadoop.proxyuser.zeppelin.hosts=*
