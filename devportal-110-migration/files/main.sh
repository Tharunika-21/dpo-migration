#!/bin/bash
DATE=$(date '+%Y-%m-%d-%H-%M')
iteration=0
# Write message to stdout
function console_msg {
  echo "[`date`] ${*}"
}
function exit_error {
  echo "[`date`] ${*}"
  exit 1
}
operation=$1
source ./vars.sh
apk add jq python3
ls -ld /opt/softwareag/data/logs &> /dev/null || mkdir /opt/softwareag/data/logs -p
ls -ld /opt/softwareag/data/json &> /dev/null || mkdir /opt/softwareag/data/json -p
function initMigration() {
  console_msg "Below are the tenants to be Migrated: "
  echo "$(cat tenants.list)"
  for tenant in $(cat tenants.list)
  do
      echo "Tenant data migration started for: ${tenant}"
      bash ./tenantMigration.sh ${tenant} ${operation} &> /opt/softwareag/data/logs/${tenant}_${DATE}.log
      bash ./publish_portal.sh ${tenant}
  done
  wait
}
initMigration

