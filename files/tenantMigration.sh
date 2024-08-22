#!/bin/bash
DATE=$(date '+%Y-%m-%d-%H-%M')
# Write message to stdout
set -x
function console_msg {
  echo "[`date`] ${*}"
}
function exit_error {
  echo "[`date`] ${*}"
  python3 sendmail.py "[Dev Portal] 11.1 Migration failed for ${tenantName}" "${*}"
  exit 1
}

tenantName=$1
operation=$2
source ./vars.sh
fqdn=""
customdomainStatus=""
function triggerTenantBackup() {
    console_msg "Getting tenant chart values for $tenantName"
    curl -X GET "${devops_tms_url}/tms/v1/tenants/${tenantName}/chartvalues" | jq '. + [{"name":"finalSnapshot","value":"enabled"}]' > /opt/softwareag/data/json/${tenantName}.json
    console_msg "Update tenant chart values to add flag finalSnapshot"
    curl -X PUT "${devops_tms_url}/tms/v1/tenants/${tenantName}/chartvalues" -H 'Content-Type: application/json' -d @/opt/softwareag/data/json/${tenantName}.json
    console_msg "Updated tenant chart values to add flag finalSnapshot"
    refreshTenant
}

function refreshTenant() {
    console_msg "Refresh the tenant $tenantName"
    response=$(curl -X PUT "${devops_tms_url}/tms/v1/tenants/${tenantName}")
    console_msg "Refresh response of $tenantName: $response";
    response=$(curl -L -X GET "${devops_tms_url}/tms/v1/tenants/$tenantName/deploy-status")
    console_msg "Health response of $tenantName: $response";
    while true
    do
        response=$(curl -L -X GET "${devops_tms_url}/tms/v1/tenants/$tenantName/deploy-status")
        if [ "$response" == "healthy" ]; then
            console_msg "Backup for $tenantName is completed. Provisioning Tenant in 11.1 version."
            provisionTenant
            break
        else
            console_msg "Backup for $tenantName is not complete"
            console_msg "Retrying again.."
            sleep 60
        fi
    done
}

function provisionTenant() {
    console_msg "Getting tenant chart values for $tenantName"
    curl -X GET "$devops_tms_url/tms/v1/tenants/$tenantName/chartvalues" > /opt/softwareag/data/json/${tenantName}_110.json
    console_msg "Framing config block for $tenantName"
    target_name=($(cat mapping | awk '{print $1}'))
    new_name=($(cat mapping | awk '{print $2}'))
    cp /opt/softwareag/config.json /opt/softwareag/data/json/${tenantName}_config.json
    for index in ${!target_name[*]}; do
        if grep -q ${target_name[$index]} /opt/softwareag/data/json/${tenantName}_110.json; then
            json_data=$(jq --arg key "$(jq --arg target "${target_name[$index]}" '.[] | select(.name == $target).value' /opt/softwareag/data/json/${tenantName}_110.json | tr -d '"')" '.config.tenantConfig += { "'${new_name[$index]}'": ($key | (if . == "true" then true elif . == "false" then false else . end)) }' /opt/softwareag/data/json/${tenantName}_config.json)
            echo $json_data >/opt/softwareag/data/json/${tenantName}_config.json
        fi
    done
    customdomainStatus=$(jq --arg target "customDomain.status" '.[] | select(.name == $target).value' /opt/softwareag/data/json/${tenantName}_110.json | tr -d '"')
    if [ "$customdomainStatus" == "enabled" ]; then
      fqdn=$(jq --arg target "customDomain.domains[0].url" '.[] | select(.name == $target).value' /opt/softwareag/data/json/${tenantName}_110.json | tr -d '"')
    else
      fqdn="${tenantName}.${domain}"
    fi
    sed -i "s#IDM_PREFIX#${idm_prefix}#g" /opt/softwareag/data/json/${tenantName}_config.json
    sed -i "s#TENANTNAME#${tenantName}#g" /opt/softwareag/data/json/${tenantName}_config.json
    sed -i "s#TIER#${tier}#g" /opt/softwareag/data/json/${tenantName}_config.json
    sed -i "s#FQDN#${fqdn}#g" /opt/softwareag/data/json/${tenantName}_config.json
    tenant_config_block=$(cat /opt/softwareag/data/json/${tenantName}_config.json | jq '.config')
    echo "{\"tenantName\": \"${tenantName}\",\"productTenantDetails\": {\"DPO\": {\"tier\": \"${tier^^}\", \"config\": ${tenant_config_block}}}}" >/opt/softwareag/data/json/${tenantName}provision.json
    console_msg "Provisioning 11.1 tenant $tenantName"
    job_id=$(curl "${product_tms_url}/DPO" -H 'Content-Type: application/json' -H "Authorization: Basic $product_tms_authToken" -H 'Cookie: tenant=default' -d @/opt/softwareag/data/json/${tenantName}provision.json | jq -r '.id' | tr -d '"')
    while true
    do
        job_status=$(curl "${product_tms_url}/jobs/status/${job_id}" -H "Authorization: Basic $product_tms_authToken" -H 'Cookie: tenant=default'| jq -r '.jobStatus' | tr -d '"')
        if [ "$job_status" == "COMPLETED" ]; then
            console_msg "Tenant provisioning in 11.1 is successful."
            registerTenantRepo
            break
        else
            console_msg "11.1 Provisioning for $tenantName is not complete"
            console_msg "Retrying again.."
            sleep 60
        fi
    done
}

function deleteTenant() {
    job_id=$(curl -XDELETE "${product_tms_url}/${tenantName}/product/DPO?forceDelete=true" -H 'Content-Type: application/json' -H "Authorization: Basic $product_tms_authToken" -H 'Cookie: tenant=default'| jq -r '.id' | tr -d '"')
    while true
    do
        job_status=$(curl "${product_tms_url}/jobs/status/${job_id}" -H "Authorization: Basic $product_tms_authToken" -H 'Cookie: tenant=default'| jq -r '.jobStatus' | tr -d '"')
        if [ "$job_status" == "COMPLETED" ]; then
            console_msg "Tenant deletion in 11.1 is successful."
            break
        else
            console_msg "11.1 Delete for $tenantName is not complete"
            console_msg "Retrying again.."
            sleep 60
        fi
    done
}
function registerTenantRepo() {
    console_msg "Registering 10.15 backup repo of $tenantName in readonly mode"
    if [ "${CLOUD_PROVIDER}" == "aws" ]; then
      status=$(curl -X PUT "${es_endpoint}/_snapshot/${repoName}" -H 'Content-Type: application/json' -d '{"type": "s3","settings": {"bucket": "'${storageName}'","base_path": "'${basePath}'","region": "'${region}'","endpoint": "'${s3Endpoint}'","compress": true,"readonly": true}}' -u "elastic:${es_password}" | jq -r '.acknowledged' | tr -d '[:space:]')
    else
      status=$(curl -X PUT  "${es_endpoint}/_snapshot/${repoName}" -H 'Content-Type: application/json' -d '{"type": "azure","settings": {"container": "'${storageName}'","base_path": "'${basePath}'","compress": true,"readonly": true}}' -u "elastic:${es_password}" | jq -r '.acknowledged' | tr -d '[:space:]')
    fi
    if [ "$status" != "true" ]; then
        deleteTenant
        exit_error "Error occurred while creating elasticsearch repo for tenant $tenantName"
    fi
    echo "Repo ${repoName} registered successfully..."
    restoreIntermediateIndices
}

function restoreIntermediateIndices() {
    latest_snapshot=$(curl -s -XGET "${es_endpoint}/_snapshot/${repoName}/_all"  -u elastic:${es_password}| jq -r ".snapshots[-1].snapshot")
    console_msg "[11.1] Restoring 10.15 core indices of $tenantName with restore prefix"
    restore_snapshot_status=$(curl -s -X POST "${es_endpoint}/_snapshot/${repoName}/${latest_snapshot}/_restore?wait_for_completion=true" -H 'Content-Type: application/json' -u elastic:${es_password} -d '{"indices": ["portal_*","-portal_'$tenantName'_metrics*","-portal_'$tenantName'_events*"],"rename_pattern": "portal_(.+)","rename_replacement": "restored_portal_$1"}')
    total=$(echo "$restore_snapshot_status" | jq -r ".snapshot.shards.total")
    success=$(echo "$restore_snapshot_status" | jq -r ".snapshot.shards.successful")

    if [ ${total} = null ]; then
        exit_error "Error.. Can't find .snapshot.shards.total"
    else
        console_msg "Successfully found .snapshot.shards.total field"
    fi

    if [ ${success} = null ]; then
        exit_error "Error.. Can't find .snapshot.shards.successful"
    else
        console_msg "Successfully found .snapshot.shards.successful field"
    fi

    if [ -z "${success}" ]; then
        exit_error "Successful shards count is empty ..."
    fi

    if [ "${total}" -ne "${success}" ]; then
        exit_error "Restoring ES snapshot failed..."
    else
        console_msg "Successfully completed restoring ES core metrics for $tenantName..."
    fi
    restoreAnalyticIndices
}

function restoreAnalyticIndices() {
    latest_snapshot=$(curl -s -XGET "${es_endpoint}/_snapshot/${repoName}/_all" -u elastic:${es_password} | jq -r ".snapshots[-1].snapshot")
    console_msg "[11.1] Restoring 10.15 metrics index of $tenantName"
    restore_snapshot_status=$(curl -s -X POST "${es_endpoint}/_snapshot/${repoName}/${latest_snapshot}/_restore?wait_for_completion=true"  -H 'Content-Type: application/json' -u elastic:${es_password} -d '{"indices": "portal_'$tenantName'_metrics*"}' -u elastic:${es_password})
    total=$(echo "$restore_snapshot_status" | jq -r ".snapshot.shards.total")
    success=$(echo "$restore_snapshot_status" | jq -r ".snapshot.shards.successful")

    if [ ${total} = null ]; then
        exit_error "Error.. Can't find .snapshot.shards.total"
    else
        console_msg "Successfully found .snapshot.shards.total field"
    fi

    if [ ${success} = null ]; then
        exit_error "Error.. Can't find .snapshot.shards.successful"
    else
        console_msg "Successfully found .snapshot.shards.successful field"
    fi

    if [ -z "${success}" ]; then
        exit_error "Successful shards count is empty ..."
    fi

    if [ "${total}" -ne "${success}" ]; then
        exit_error "Restoring ES snapshot failed..."
    else
        console_msg "Successfully completed restoring Metrics Index for $tenantName..."
    fi
    reindex
}

function reindex() {
    console_msg "Get document count of 10.15 data indices for $tenantName"
    doccount1015=$(curl -s -X POST "${es_endpoint}/restored_portal_${tenantName}_associates,restored_portal_${tenantName}_audits,restored_portal_${tenantName}_collaboration,restored_portal_${tenantName}_configurations,restored_portal_${tenantName}_core,restored_portal_${tenantName}_files,restored_portal_${tenantName}_logs,restored_portal_${tenantName}_uiconfigurations/_count" -u elastic:${es_password}| jq -r '.count')
    console_msg "[11.1] Reindex all portal data indices for $tenantName"
    status=$(curl -s -X POST "${es_endpoint}/_reindex" -H 'Content-Type: application/json' -u elastic:${es_password} -d '{"source": {"index": ["restored_portal_'$tenantName'_associates","restored_portal_'$tenantName'_audits","restored_portal_'$tenantName'_collaboration","restored_portal_'$tenantName'_configurations","restored_portal_'$tenantName'_core","restored_portal_'$tenantName'_files","restored_portal_'$tenantName'_logs","restored_portal_'$tenantName'_uiconfigurations"],"query": {"match_all": {}}},"dest": {"index": "portal_'$tenantName'_core"},"script": {"source": "if (ctx._source.documentType == \"API_PATCH\") {ctx._id=\"API_PATCH-\" + ctx._id; ctx._source.id=\"API_PATCH-\"+ctx._source.id}\n\n if (ctx._source.documentType == \"CONFIGURATION\" && (ctx._source.category == \"rating\" || ctx._source.category == \"RATING\")) {ctx._id=\"CONFIGURATION-\" + ctx._id; ctx._source.id=\"CONFIGURATION-\"+ctx._source.id}\n\n if (ctx._source.documentType == \"EVENTS\" && ctx._source.eventType == \"SIGN_UP_EVENT\") {ctx._id=\"EVENTS-\" + ctx._id;ctx._source.id=\"EVENTS-\"+ctx._source.id}\n\n if (ctx._source.documentType == \"FILE\" && (ctx._source.type == \"API_LOGO\" || ctx._source.type == \"PACKAGE_LOGO\" || ctx._source.type == \"PLAN_LOGO\")) {ctx._id=\"FILE-\" + ctx._id; ctx._source.id=\"FILE-\"+ctx._source.id}\n\n if ((ctx._source.documentType == \"API\" || ctx._source.documentType == \"PACKAGE\" || ctx._source.documentType == \"PLAN\") &&  (ctx._source.icon !=null && ctx._source.icon.url != null && ctx._source.icon.url.contains(\"rest/v1/files/\"+ctx._id))) {ctx._source.icon.url=\"rest/v1/files/FILE-\"+ctx._id;}\n\n if (ctx._source.documentType == \"FLOW\" && (ctx._source.type == \"APPLICATION_CREATION_REQUEST\" || ctx._source.type == \"APPLICATION_SCOPE_INCREASE_REQUEST\")) {def name = ctx._source.parameters.name; if (name != null) { ctx._source.parameters.remove(\"name\"); ctx._source.parameters.appName=name;}def desc = ctx._source.parameters.description; if (desc != null) {ctx._source.parameters.remove(\"description\"); ctx._source.parameters.appDescription=desc;}}","lang": "painless"}}' | jq -r ".failures")
    if [ "${status}" != '[]' ]; then
        exit_error "Reindex failed for portal data indices of $tenantName"
    fi
    sleep 60
    doccount110=$(curl -s -X POST "${es_endpoint}/portal_${tenantName}_core/_count" -u elastic:${es_password}| jq -r '.count')
    if [ "${doccount110}" -lt "${doccount1015}" ]; then
      exit_error "Documents count do not match after reindex. Reindex failed for portal data indices of $tenantName"
    else
        console_msg "10.15 core data doc count - $doccount1015 & 11.1  core data doc count - $doccount110. Validated that 11.1 doc count is more than or equal to 10.15 doc count for $tenantName."
    fi
    doccount1015=$(curl -s -X POST "${es_endpoint}/restored_portal_${tenantName}_umc,restored_portal_${tenantName}_umc_events,restored_portal_${tenantName}_umc_pictures/_count" -u elastic:${es_password}| jq -r '.count')
    console_msg "[11.1] Reindex UMC master indices for $tenantName"
    status=$(curl -s -X POST "${es_endpoint}/_reindex" -H 'Content-Type: application/json' -u elastic:${es_password} -d '{"source": {"index": ["restored_portal_master_umc","restored_portal_master_umc_events","restored_portal_master_umc_pictures"],"query": {"match_all": {}}},"dest": {"index": "portal_master_umc"}}' | jq -r ".failures")
    if [ "${status}" != '[]' ]; then
        exit_error "Reindex failed for UMC master indices of $tenantName"
    fi
    console_msg "[11.1] Reindex UMC data indices for $tenantName"
    status=$(curl -s -X POST "${es_endpoint}/_reindex" -H 'Content-Type: application/json' -u elastic:${es_password} -d '{"source": {"index": ["restored_portal_'$tenantName'_umc","restored_portal_'$tenantName'_umc_events","restored_portal_'$tenantName'_umc_pictures"],"query": {"match_all": {}}},"dest": {"index": "portal_'$tenantName'_umc"}}' | jq -r ".failures")
    if [ "${status}" != '[]' ]; then
        exit_error "Reindex failed for UMC data indices of $tenantName"
    fi
    sleep 60
    doccount110=$(curl -s -X POST "${es_endpoint}/portal_${tenantName}_umc/_count" -u elastic:${es_password}| jq -r '.count')
    if [ "${doccount110}" -lt "${doccount1015}" ]; then
      exit_error "Documents count do not match after reindex. Reindex failed for UMC data indices of $tenantName"
    else
        console_msg "10.15 UMC data doc count - $doccount1015 & 11.1  UMC data doc count - $doccount110. Validated that 11.1 doc count is more than or equal to 10.15 doc count for $tenantName."
    fi
    console_msg "[11.1] Reindexing completed for $tenantName..."
    deleteIndices "restored_portal_*"
    updateSchema
}

function deleteIndices() {
    curl -s -X DELETE "${es_endpoint}/$1" -u elastic:${es_password}
}

function updateSchema() {
    apk add mysql-client
    mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "UPDATE $tms_schema_name.tenant_config SET major_version='11.1' WHERE tenant_name='$tenantName'"
    config_keys=$(cat /opt/softwareag/data/json/${tenantName}_config.json | jq '.config.tenantConfig')
    if [ "${tier^^}" == "FREE_FOREVER" ]; then
      mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "UPDATE $tms_schema_name.tenant_config SET helm_chart_values='[]' WHERE tenant_name='$tenantName'"
      mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "UPDATE $tms_schema_name.portal_tenant_config SET config_keys='$config_keys' WHERE tenant_name='$tenantName'"
      deleteOldTenant
    else
      if [ "$customdomainStatus" == "enabled" ]; then
        mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "UPDATE $tms_schema_name.tenant_config SET helm_chart_values='[{\"name\":\"customDomain.domains[0].tenantName\",\"value\":\"$tenantName\"},{\"name\":\"customDomain.domains[0].url\",\"value\":\"${fqdn}\"}]' WHERE tenant_name='$tenantName'"
      else
        mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "UPDATE $tms_schema_name.tenant_config SET helm_chart_values='[{\"name\":\"ingress.domains[0].tenantName\",\"value\":\"$tenantName\"},{\"name\":\"ingress.domains[0].url\",\"value\":\"${fqdn}\"}]' WHERE tenant_name='$tenantName'"
      fi
      mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "INSERT INTO $tms_schema_name.portal_tenant_config (config_id, common_es_endpoint, major_version, tenant_name, config_keys) SELECT MAX(config_id) + 1,NULL, '11.1', '$tenantName', '$config_keys' FROM $tms_schema_name.portal_tenant_config"
      python3 sendmail.py "[Dev Portal] 11.1 Migration partial success for ${tenantName}" "Data migration to 11.1 is completed for tenant ${tenantName}. Traffic will still be directed to 10.15. Once 10.15 resources are deleted, traffic will be switched to 11.1"
    fi
    mysql -h $database_endpoint -u $database_user -p$database_password --ssl -se "UPDATE $tms_schema_name.tenant SET tenant_status='DEPLOYED' WHERE tenant_name='$tenantName'"
}

function deleteOldTenant() {
    access_token=$(curl -s -d 'client_id=tm-admin' -d 'client_secret='${client_secret}'' -d 'grant_type=client_credentials' ${keycloak_url}/auth/realms/${keycloak_realm}/protocol/openid-connect/token | jq -r '.access_token')
    curl -s -H "Authorization: Bearer ${access_token}" -X DELETE ${tenant_manager_url}/v3/tenants/${tenantName}?majorVersion=10.15
    if [ "${tier^^}" != "FREE_FOREVER" ]; then
      if [ "$customdomainStatus" == "enabled" ]; then
        curl -s -H "Authorization: Bearer ${access_token}" -X POST ${tenant_manager_url}/v3/tenants/create/${tenantName} -H "Content-Type: application/json" -d '{"tenantName": "'${tenantName}'", "majorVersion": "ingress","customChartVal": [{"name": "customDomain.domains[0].tenantName", "value": "'${tenantName}'"}, {"name": "customDomain.domains[0].url", "value": "'${fqdn}'"}]}'
      else
        curl -s -H "Authorization: Bearer ${access_token}" -X POST ${tenant_manager_url}/v3/tenants/create/${tenantName} -H "Content-Type: application/json" -d '{"tenantName": "'${tenantName}'", "majorVersion": "ingress","customChartVal": [{"name": "ingress.domains[0].tenantName", "value": "'${tenantName}'"}, {"name": "ingress.domains[0].url", "value": "'${fqdn}'"}]}'
      fi
    fi
    python3 sendmail.py "[Dev Portal] 11.1 Migration success for ${tenantName}" "Data migration to 11.1 is completed for tenant ${tenantName}. Traffic is now switched to 11.1"
}

repoName="${tenantName}_es_1015_daily_backup"
basePath="devportal/primary/${tenantName}/1015/daily"
case $operation in
  migrate)
      python3 sendmail.py "[Dev Portal] 11.1 Migration is started for ${tenantName}" "Tenant upgrade from current version to 11.1 is started for tenant ${tenantName}. You will be notified once the upgrade completes/fails"
      console_msg "Performing migration for the First time for tenant $tenantName"
      tenantState=$(curl -X GET "${devops_tms_url}/tms/v1/tenants/$tenantName" | jq -r '.tenantStatus')
      if [ "${tenantState}" == "DEPLOYED" ]; then
        console_msg "Tenant $tenantName is in DEPLOYED state. Preparing to take final backup"
        triggerTenantBackup
      else
        console_msg "Tenant $tenantName is not in DEPLOYED state. Skipping backup to provision 11.1 version of tenant"
        provisionTenant
        curl -X DELETE ${devops_tms_url}/tms/v3/aws/route53 -H 'Content-Type: application/json' -d '{"recordName": "'${tenantName}'.'${domain}'","recordType": "CNAME"}'
      fi
      ;;
  retry)
    python3 sendmail.py "[Dev Portal] 11.1 Migration is started for ${tenantName}" "Tenant upgrade from current version to 11.1 is started for tenant ${tenantName}. You will be notified once the upgrade completes/fails"
    console_msg "Retrying migrationfor tenant $tenantName"
    deleteIndices "restored_portal_*"
    deleteTenant
    tenantState=$(curl -X GET "${devops_tms_url}/tms/v1/tenants/$tenantName" | jq -r '.tenantStatus')
    if [ "${tenantState}" == "DEPLOYED" ]; then
      console_msg "Tenant $tenantName is in DEPLOYED state. Preparing to take final backup"
      triggerTenantBackup
    else
      console_msg "Tenant $tenantName is not in DEPLOYED state. Skipping backup to provision 11.1 version of tenant"
      provisionTenant
      curl -X DELETE ${devops_tms_url}/tms/v3/aws/route53 -H 'Content-Type: application/json' -d '{"recordName": "'${tenantName}'.'${domain}'","recordType": "CNAME"}'
    fi
   ;;
 deleteOldTenant)
    console_msg "Delete 10.15 Resource and redirecting traffic to 11.1"
    customdomainStatus=$(jq --arg target "customDomain.status" '.[] | select(.name == $target).value' /opt/softwareag/data/json/${tenantName}_110.json | tr -d '"')
    if [ "$customdomainStatus" == "enabled" ]; then
      fqdn=$(jq --arg target "customDomain.domains[0].url" '.[] | select(.name == $target).value' /opt/softwareag/data/json/${tenantName}_110.json | tr -d '"')
    else
      fqdn="${tenantName}.${domain}"
    fi
    deleteOldTenant
esac
