# -*- coding: utf-8 -*-
from __future__ import print_function
import time
import cm_client
from cm_client.rest import ApiException
from collections import namedtuple
from pprint import pprint
import json
import sys
import subprocess

class Colors:
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    GRAY = "\033[90m"
    RED = "\033[31m"
    RESET = "\033[0m"

def wait(cmd, timeout=None):
    print(cmd.name)
    SYNCHRONOUS_COMMAND_ID = -1
    if cmd.id == SYNCHRONOUS_COMMAND_ID:
        return cmd

    SLEEP_SECS = 5
    if timeout is None:
        deadline = None
    else:
        deadline = time.time() + timeout

    try:
        cmd_api_instance = cm_client.CommandsResourceApi(api_client)
        while True:
            cmd = cmd_api_instance.read_command(long(cmd.id))
            # pprint(cmd.name)
            print('.',end='')
             
            if not cmd.active:
                print(" - " + cmd.result_message)
                return cmd

            if deadline is not None:
                now = time.time()
                if deadline < now:
                    return cmd
                else:
                    time.sleep(min(SLEEP_SECS, deadline - now))
            else:
                time.sleep(SLEEP_SECS)
    except ApiException as e:
        print("Exception when calling ClouderaManagerResourceApi->import_cluster_template: %s\n" % e)


cm_client.configuration.username = 'admin'
cm_client.configuration.password = 'admin'
api_client = cm_client.ApiClient("http://localhost:7180/api/v40")

cm_api = cm_client.ClouderaManagerResourceApi(api_client)

# accept trial licence
cm_api.begin_trial()



# Update Cloudera Manager config for KRB 
body = cm_client.ApiConfigList()
body.items=[
    cm_client.ApiConfig(name='KDC_HOST', value='YourHostname'),
    cm_client.ApiConfig(name='KDC_ADMIN_HOST', value='YourHostname'),
    cm_client.ApiConfig(name='KDC_TYPE', value='MIT KDC'),  
    cm_client.ApiConfig(name='KRB_ENC_TYPES', value='aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96 arcfour-hmac-md5'), 
    cm_client.ApiConfig(name='SECURITY_REALM', value='CLOUDERA.COM'), 
    cm_client.ApiConfig(name='KRB_MANAGE_KRB5_CONF', value='true')
    ]
api_response = cm_api.update_config(message="KRB", body=body)

# Import KDC admin credentials
cmd = cm_api.import_admin_credentials(password='BadPass#1', username='cloudera-scm/admin@CLOUDERA.COM')
wait(cmd)



# Install CM Agent on host
with open ("/root/myRSAkey", "r") as f:
    key = f.read()

instargs = cm_client.ApiHostInstallArguments(
    host_names=['YourHostname'], 
    user_name='root', 
    private_key=key, 
    cm_repo_url='https://archive.cloudera.com/cm7/7.4.4/', 
    java_install_strategy='NONE', 
    ssh_port=22, 
    passphrase='')

cmd = cm_api.host_install_command(body=instargs)
wait(cmd)


    
# create MGMT/CMS
mgmt_api = cm_client.MgmtServiceResourceApi(api_client)
api_service = cm_client.ApiService()

api_service.roles = [cm_client.ApiRole(type='SERVICEMONITOR'), 
    cm_client.ApiRole(type='HOSTMONITOR'), 
    cm_client.ApiRole(type='EVENTSERVER'),  
    cm_client.ApiRole(type='ALERTPUBLISHER')]

mgmt_api.auto_assign_roles() # needed?
mgmt_api.auto_configure()    # needed?
mgmt_api.setup_cms(body=api_service)
cmd = mgmt_api.start_command()
wait(cmd)



# create the cluster using the template
with open(sys.argv[1]) as f:
    json_str = f.read()

Response = namedtuple("Response", "data")
dst_cluster_template=api_client.deserialize(response=Response(json_str),response_type=cm_client.ApiClusterTemplate)
cmd = cm_api.import_cluster_template(add_repositories=True, body=dst_cluster_template)

print("Started ImportClusterTemplate, command ID: %s\n" % cmd.id)
last_line_count = 0

def print_step_status(children):
    global last_line_count

    # Move the cursor up and clear previous output
    if last_line_count > 0:
        sys.stdout.write("\033[F\033[K" * last_line_count)  # F = move cursor up, K = clear line
        sys.stdout.flush()

    lines = []
    for child in children.items:
        if child.success:
            status = Colors.GREEN + "[✔]" + Colors.RESET
        elif child.active:
            status = Colors.YELLOW + "[~]" + Colors.RESET
        else:
            status = Colors.GRAY + "[ ]" + Colors.RESET
        lines.append("%s %s" % (status, child.name))

    # Print all lines and update the count
    for line in lines:
        print(line)
    last_line_count = len(lines)

def print_final_status(children):
    """Prints final summary without in-place formatting."""
    print("\nFinal step status:\n")
    for child in children.items:
        if child.success:
            status = Colors.GREEN + "[✔]" + Colors.RESET
        else:
            status = Colors.RED + "[❌]" + Colors.RESET
        print("%s %s" % (status, child.name))

deploy_parcels_completed = False  # Flag to ensure it runs only once

# Poll until command finishes
cmd_api_instance = cm_client.CommandsResourceApi(api_client)
while cmd.active:
    #cmd = cm_api.get_command(cmd.id)  # refresh the status
    cmd = cmd_api_instance.read_command(cmd.id)

    # custom action for Hue
    # Detect when "Deploy Parcels" completes
    for child in cmd.children.items:
        if child.name == "DeployParcels" and child.success and not deploy_parcels_completed:
            deploy_parcels_completed = True
            print("\n🚀 'Deploy Parcels' step completed. Running Hue custom action...\n")
            # === custom action for Hue to start: https://docs.cloudera.com/cdp-private-cloud-base/7.3.1/administering-hue/topics/hue-install-configure-mariadb-rhel8.html ===
            try:
                subprocess.check_call([
                    "cp", "-f",
                    "/usr/lib64/python2.7/site-packages/_mysql.so",
                    "/opt/cloudera/parcels/CDH/lib/hue/build/env/lib/python2.7/site-packages/MySQL_python-1.2.5-py2.7-linux-x86_64.egg/"
                ])
                print("✅ _mysql.so successfully copied.")
            except subprocess.CalledProcessError as e:
                print("❌ Failed to copy _mysql.so: %s" % e)
            # cp -f /usr/lib64/python2.7/site-packages/_mysql.so /opt/cloudera/parcels/CDH/lib/hue/build/env/lib/python2.7/site-packages/MySQL_python-1.2.5-py2.7-linux-x86_64.egg/
    
    
    print_step_status(cmd.children)
    time.sleep(5)

# Final status
print_step_status(cmd.children)

# === Final summary ===
print_final_status(cmd.children)

if cmd.success:
    print("✅ ImportClusterTemplate completed successfully!")
else:
    print("❌ ImportClusterTemplate failed.")
    # Optional: show which steps failed
    for child in cmd.children.items:
        if not child.success:
            print("❌ Step '%s' failed." % child.name)
            if hasattr(child, 'resultMessage') and child.resultMessage:
                print("   Reason: %s" % child.resultMessage)

wait(cmd)
