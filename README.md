# Single Node CDP PVC-Base Cluster 

This script has been modified to handle installation of the Security&Governance workshop (aka Hortonia bank) on a YCloud instance that you can find here: https://community.cloudera.com/t5/Community-Articles/How-to-setup-Cloudera-Security-Governance-GDPR-Worldwide/ta-p/297315

It automatically sets up a CDP PVC-Base Trial cluster on a single VM with the services preconfigured in a template file. It supports both clusters with or without kerberos.
This cluster is meant to be used for demos, experimenting, training, and workshops so it is only one node and does not have TLS enabled.

## Presentation 

It gives the ability to demonstrate stuff like
* Demo tags/attributes and lineage in Atlas
* Ranger policies across HDFS, Hive/Impala, Hbase, Kafka, SparkSQL to showcase:
  - Tag based policies across CDP components
  - Row level filtering in Hive columns
  - Dynamic tag based masking in Hive/Impala 
* Atlas capabilities like 
  - Classifications (tags) and attributes
  - Tag propagation
  - Data lineage
  - Business glossary:categories and terms
* GDPR Scenarios around consent and data erasure via Hive ACID


## Deploy

1. Instanciate a 32CPU/64GB RAM CentOS 7 VM on [cloudcat](https://cloudcat.infra.cloudera.com) (you need to be on VPN)
![image](https://user-images.githubusercontent.com/7782997/196439300-c4e66ae9-5cbc-4992-b45d-e0d86c0ce8e6.png)

It takes less than 2 minutes.

2. SSH into it (password is `cloudera`)
```
ssh root@ccycloud.[SHORT_NAME].root.hwx.site
```

3. Install the stuff
```
yum install -y git 
git clone -b rhel8 https://github.com/laurentedel/SingleNodeCDPCluster.git && cd SingleNodeCDPCluster
./setup_gov.sh templates/wwbank_krb_simplified.json

```

It will:
* install a KDC
* install CM packages with everything needeed (7mn)
* deploy a CDP Private Cloud Base 7.1.7 stack (15mn + 8mn restart)
* deploy all the governance scripting (Hive tables, Ranger policies, etc) (15mn)

Thus a total time around 45mn

You can follow the deployment on Cloudera Manager http://ccycloud.[SHORT_NAME].root.hwx.site:7180 (credentials `admin/admin`)

The different UIs (Ranger, Atlas) are usually `admin` or `administrator` with the password `BadPass#1`

## Showtime

You can make some basic requests in Hue or CLI to show some masking rules.

For example
```
# kinit as joe_analyst, US group
kinit -kt /etc/security/keytabs/joe_analyst.keytab joe_analyst/$(hostname -f)@CLOUDERA.COM
# will show redacted address, password
beeline --color -e "SELECT surname, streetaddress, country, age, password, nationalid, ccnumber, mrn, birthday FROM worldwidebank.us_customers limit 5;" 2>/dev/null

# will show tag-based DENY (policy EXPIRES_ON), must see in Ranger audits to show
# if you change the EXPIRES_ON value, it will eventually work
beeline --color -e "select fed_tax from finance.tax_2015;" 2>/dev/null

#tag based deny (DATA_QUALITY)
beeline --color -e "select * from cost_savings.claim_savings limit 5;" 2>/dev/null

#
# Now the not redacted version from etl_user
#
kinit -kt /etc/security/keytabs/etl_user.keytab etl_user/$(hostname -f)@CLOUDERA.COM
beeline --color -e "SELECT surname, streetaddress, country, age, password, nationalid, ccnumber, mrn, birthday FROM worldwidebank.us_customers limit 5;" 2>/dev/null
```
