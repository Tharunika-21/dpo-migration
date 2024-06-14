name: Pre-Deployment/Deployment/Post-Deployment
description: Pre-Deployment/Deployment/Post-Deployment
outputs:
  apigw_deployment_job_status:
    value: ${{ steps.apigwhealthCheck.outputs.apigw_deployment_job_status }}
  kibana_deployment_job_status:
    value: ${{ steps.healthCheck.outputs.kibana_deployment_job_status }} 
inputs:
  major_version:
    type: choice
    description: Major version of the apigw image to be deployed (possible values are 1100)
    default: 1100
    required: false
    options:
      - '1100'
  platform:
    description: "Cloud Provider (AWS or Azure)"
    required: true
    type: string
  environment:
    description: "Environment"
    required: true
    type: string
  region:
    description: "Region"
    required: true
    type: string
  tenant_names:
    description: "Tenant Names (Provide tenant names as comma separated values which needs to be promoted/deployed or All)"
    type: string
    required: true
  internal_tenant_names:
    description: "Internal Tenant Names (Provide internal tenant names as comma separated values which needs to be promoted/deployed)"
    type: string
    required: true   
  exclude_tenants:
    description: "Tenants to be excluded in the cluster for promotion/deployment (Provide tenant names as comma separated values)"
    type: string
    required: false
  tag:
    description: "Image tags of the components to be promoted/deployed"
    required: true
    type: string
  component:
    description: "Component to be promoted/deployed (possible values are apigateway-server, apigw-kibana)"
    required: true
    type: string
  source_env:
    description: "Source env for preprod(Stage/Spro)"
    required: false
    type: string
    default: Staging
  runner:
    description: "Runner Machine"
    required: true
    type: string
  tier:
    description: "Paid or FFE"
    required: true
    type: string
  type:
    description: "Promote or Deploy or Rollback"
    required: true
    type: string
  email_id:
    description: "Email Id to notify about upgrades via email"
    required: true
    type: string
  notify_customer:
    description: "Whether to notify customer regarding fix upgrade (Possible values are all or none) Default value is all"
    required: false
    type: string 
    default: all
  source_registry:
    description: Source environment ECR registry URL
    required: true
  target_registry:
    description: Target environment ECR registry URL
    required: true
  kc_url:
    description: Keycloak client target environment
    required: true
  kc_realm:
    description: Keycloak client realm name URL of target environment
    required: true
  tms_url:
    description: TMS URL of target environment
    required: true
  tms_client_id:
    description: TMS Client id of target environment
    required: true
  tms_client_secret:
    description: TMS Client secret of target environment
    required: true
  tm_url:
    description: Tenant manager URL of target environment
    required: true
  tm_client_id:
    description: Tenant manager Client id of target environment
    required: true
  tm_client_secret:
    description: Tenant manager Client secret of target environment
    required: true
  environment_platform:
    description: "Environment cloud platform"
    required: true
  environment_region:
    description: "Environment region"
    required: true
  environment_stage:
    description: "Environment stage"
    required: true
  environment_registry:
    description: "Image registry for current environment"
    required: true
  environment_predecessor:
    description: "Name of the predecessor environment"
    required: true
  environment_predecessor_registry:
    description: "Image registry for predecessor environment"
    required: true
  environment_spokes:
    description: "Spokes linked to the environment"
    required: true
  product_code:
    description: "Product code"
    required: true
  application_name:
    description: "Application name"
    required: true
  application_namespace:
    description: "Application namespace"
    required: true
  application_pod_prefix:
    description: "Application pod prefix"
    required: true
  application_image_repo:
    description: "Application image repository"
    required: true
  application_stable_image:
    description: "Application stable image"
    required: true

runs:
  using: "composite"
  steps:
  - name: Checkout repository
    uses: actions/checkout@v3
    with:
      ref: feature/KUB-29779
  - name: Login to  Amazon ECR
    id: login-ecr
    uses: aws-actions/amazon-ecr-login@v1
  - name: Configure AWS S3 credentials
    uses: aws-actions/configure-aws-credentials@v3
    with:
      aws-access-key-id: ${{ env.CICD_S3_ACCESS_KEY_ID }}
      aws-secret-access-key: ${{ env.CICD_S3_SECRET_ACCESS_KEY }}
      aws-region: ${{ env.CICD_S3_REGION }}
  - name: Print Deployment Inputs
    shell: bash
    run: |
      echo "Image Tags: ${{ github.event.inputs.tag }}"
      echo "Components: ${{ github.event.inputs.component }}"
      echo "Tenant Names: ${{ github.event.inputs.tenant_names }}"
      echo "Internal Tenant Names: ${{ github.event.inputs.internal_tenant_names }}"
      echo "Exclude Tenant Names: ${{ github.event.inputs.exclude_tenants }}"
      echo "Tier Details   : ${{ github.event.inputs.tier }}"
  - name: Fetch CI/CD metadata
    id: fetch-metadata
    uses: ./.github/actions/manage-cicd-metadata
    with:
      operation: 'fetch_static_metadata'
      environment: ${{ inputs.environment }}
      product_name: 'apigateway'
      component: ${{ inputs.component }}
      platform: "AWS"
  - name: Fetch stable image
    id: fetch-stable-image
    uses: ./.github/actions/manage-cicd-metadata
    with:
      operation: 'fetch_stable_image'
      metadata_bucket_name: ${{ env.CICD_S3_BUCKET_NAME }}
      stable_image_for: ${{ inputs.type }}
      environment: ${{ inputs.environment }}
      product_name: 'apigateway'
      component: ${{ inputs.component }}
      tag: ${{ inputs.tag }}
      platform: ${{ inputs.platform }}
  - name: Get current image in ${{ inputs.platform }}-${{ inputs.environment }} in Runtime
    if: inputs.type == 'deploy' && (inputs.tier == 'Paid' || inputs.tier == 'Ffe' || inputs.tier == 'PAID' || inputs.tier == 'FFE' || inputs.tier == 'paid' || inputs.tier == 'ffe')
    id: getCurrentImage
    shell: bash
    run: |

        if [[ "${{ inputs.tenant_names }}" =~ ^(All|ALL|all)$ ]]; then
          echo "Tenant Names are: ${{ inputs.tenant_names }}. Hence excluding tenants from the cluster"
          tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
          data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants?status=DEPLOYED&majorVersion=${{ inputs.major_version }}" | jq -r '.[]| "\(.tenantName)"')
          readarray -t tenants <<<"$data" 
          echo "Exclude Tenant Names: ${{ github.event.inputs.exclude_tenants }}"
          IFS=',' read -r -a excluded_tenants <<< "${{ github.event.inputs.exclude_tenants }}"
          echo "Excluded tenants: ${{ github.event.inputs.exclude_tenants }}"

          for tenant in "${tenants[@]}"; do
            if [[ ! " ${excluded_tenants[@]} " =~ " ${tenant} " ]]; then
              echo "Tenant $tenant is included"
              tenants_list+=("$tenant")
            fi
          done
        else
          echo "Tenant Names are : ${{ inputs.tenant_names }}"
          IFS=',' read -r -a tenants_list <<< "${{ inputs.tenant_names }}"
        fi

        echo "Tenants to be excluded are ${excluded_tenants[@]}"
        echo "Tenants to be included are ${tenants_list[@]}"

        component_names=($(echo "${{ inputs.component }}" | sed -e 's/,/ /g'))
        image_tags=($(echo "${{ inputs.tag }}" | sed -e 's/,/ /g'))

        echo "Components are: ${component_names[@]}"
        echo "Image Tags are: ${image_tags[@]}"

        for tenant in "${!tenants_list[@]}"; do
          tenant_name=${tenants_list[${tenant}]}
          echo $tenant_name
          for component in "${!component_names[@]}"; do
            image_name="${component_names[${component}]}"
            namespace="apigw-${tenant_name}"
            echo $namespace
            if [ "${image_name}" == 'apigateway-server' ]; then
              echo "Image name is apigateway-server"
              echo "Getting current deployed image for tenant ${tenant_name}"
              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
              currentApigwImage=$(curl -H "Authorization: Bearer ${tms_access_token}" -sX GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues" | jq '.[] | select(.name == "applications.apigw.imageTag").value' -r)
              echo "Current apigw deployment in ${{ inputs.platform }}-${{ inputs.environment }} is running with ${currentApigwImage}"
              echo "Apigw Image tag to be rolled back in case of failure - ${currentApigwImage}"
            fi
          done
        done

  - name: Promote/Check image in ${{ inputs.platform }}-${{ inputs.environment }} registry
    if: (inputs.type == 'deploy' || inputs.type == 'promote') && (inputs.tier == 'Paid' || inputs.tier == 'Ffe' || inputs.tier == 'PAID' || inputs.tier == 'FFE' || inputs.tier == 'paid' || inputs.tier == 'ffe')
    shell: bash
    run: |      
        
        component_names=($(echo "${{ inputs.component }}" | sed -e 's/,/ /g'))
        image_tags=($(echo "${{ inputs.tag }}" | sed -e 's/,/ /g'))

        echo "Components are: ${component_names[@]}"
        echo "Image Tags are: ${image_tags[@]}"

        for index in ${!component_names[@]}; do
          image_name="${component_names[${index}]}"
          for tag in "${!image_tags[@]}"; do
            image_tag="${image_tags[${tag}]}"
            echo $image_name
            echo $image_tag
            if [[ "${image_name}" = 'apigateway-server' || "${image_name}" = 'apigw-kibana' ]]; then
              if docker buildx imagetools inspect ${{ steps.login-ecr.outputs.registry }}/${image_name}:${image_tags[${index}]} ; then
                echo "Image is present in the registry."                
              else
                if [ "${{ inputs.environment }}" = 'DEV' ]; then
                  echo "Image is not present in dev registry, provide right image tag"
                  exit 1
                else
                  echo "Image is not present in registry, Trying to pull from previous environment registry"
                  docker pull ${{ inputs.source_registry }}/${image_name}:${image_tags[${index}]}
                  docker tag ${{ inputs.source_registry }}/${image_name}:${image_tags[${index}]} ${{ inputs.target_registry }}/${image_name}:${image_tags[${index}]}
                  docker push ${{ inputs.target_registry }}/${image_name}:${image_tags[${index}]}
                  echo "Image is pushed to the registry. Proceeding with image publish to TMS database"
                  tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                  echo $tms_access_token
                  echo "Publishing latest build to TMS db"
                  latest_release='{
                      "fixVersion": "$image_tag",
                      "isLatestFix": "false"
                  }'
                  image_publish_code=$(curl -H "Authorization: Bearer ${tms_access_token}" -o /dev/null -w "%{http_code}" -sX PATCH -H "Content-Type: application/json" -d "$latest_release" "${{ inputs.tms_url }}/tms/v3/release/version${{ inputs.major_version }}")
                  echo "${image_publish_code}"
                  if [ "${image_publish_code}" = '200' ]; then
                    echo "Publish latest image to TMS database succeeded"
                  else
                    echo "Publish latest image to TMS database failed"
                  fi
                fi
              fi
            else
              echo "Provided component is not supported for Image Promotion. Please check and provide the right component name"
            fi
          done
        done

  - name: Deploy apigw image to ${{ inputs.platform }}-${{ inputs.environment }} Runtime
    id: apigwhealthCheck
    if: inputs.type == 'deploy' && (inputs.tier == 'Paid' || inputs.tier == 'PAID' || inputs.tier == 'paid' || inputs.tier == 'FFE' || inputs.tier == 'Ffe' || inputs.tier == 'ffe')
    shell: bash
    run: |

        batch_size=15
        sleepSecs=3
        scheduleAfter=5      

        revertLatestImage() {
          revert_image_tag=$1
          tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
          revert_status_code=$(curl -X DELETE '${{ inputs.tms_url }}/tms/v3/release/version/${{ inputs.major_version }}/fix' -H 'Content-Type: application/json' -H 'Authorization: Bearer ${tms_access_token}' -d '{"fixVersion": "$revert_image_tag"}')
          echo $revert_status_code
          if [ "${revert_status_code}" = '200' ]; then
            echo "Deleted the latest fix version from TMS db as internal tenant upgrade failed"
          else
            echo "Failed to delete the latest fix version from TMS db as internal tenant upgrade failed"
          fi          
        }        

        if [[ "${{ inputs.tenant_names }}" =~ ^(All|ALL|all)$ ]]; then
          echo "Tenant Names are: ${{ inputs.tenant_names }}. Hence excluding tenants from the cluster"
          tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
          data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants?majorVersion=${{ inputs.major_version }}" | jq -r '.[]| "\(.tenantName)"')
          readarray -t tenants <<<"$data" 
          echo "Exclude Tenant Names: ${{ github.event.inputs.exclude_tenants }}"
          IFS=',' read -r -a excluded_tenants <<< "${{ github.event.inputs.exclude_tenants }}"
          echo "Excluded tenants: ${{ github.event.inputs.exclude_tenants }}"

          for tenant in "${tenants[@]}"; do
            if [[ ! " ${excluded_tenants[@]} " =~ " ${tenant} " ]]; then
              echo "Tenant $tenant is included"
              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
              tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant}" | jq -r '.tier')
              echo "Tenant Tier: ${tenant_tier}"
              if [[ "${tenant_tier}" =~ ^PAID_(ADVANCED|BASIC|ENTERPRISE)$ ]]; then
                tenants_list+=("$tenant")
              elif [[ "${tenant_tier}" =~ ^(FREE_FOREVER)$ ]]; then
                tenants_list+=("$tenant")
              fi
            fi
          done
        else
          echo "Tenant Names are : ${{ inputs.tenant_names }}"
          IFS=',' read -r -a tenants_list <<< "${{ inputs.tenant_names }}"
        fi

        echo "Tenants to be excluded are ${excluded_tenants[@]}"
        echo "Tenants to be included are ${tenants_list[@]}"

        IFS=',' read -r -a internal_tenants <<< "${{ inputs.internal_tenant_names }}"
        echo "Internal Tenants are ${internal_tenants[@]}"

        component_names=($(echo "${{ inputs.component }}" | sed -e 's/,/ /g'))
        image_tags=($(echo "${{ inputs.tag }}" | sed -e 's/,/ /g'))

        echo "Components are: ${component_names[@]}"
        echo "Image Tags are: ${image_tags[@]}"
        echo "Performing deployment operation"
        echo "Tenant names to deploy new images are: ${tenants_list[@]}"

        for component in "${!component_names[@]}"; do
          image_name="${component_names[${component}]}"
          for tag in "${!image_tags[@]}"; do
            image_tag="${image_tags[${tag}]}"
            # Calculate number of batches
            num_batches=$(( (${#tenants_list[@]} + $batch_size - 1) / $batch_size ))
            # Split array into batches and print each batch on a new line
            for ((i = 0; i < $num_batches; i++)); do
              start_index=$(( i * $batch_size ))
              end_index=$(( (i + 1) * $batch_size ))
              tenants_batch=("${tenants_list[@]:$start_index:$batch_size}")
              echo "${tenants_batch[@]}"
              for tenant in ${!tenants_batch[@]}; do
                tenant_name=${tenants_batch[${tenant}]}
                namespace="apigw-${tenant_name}"
                if [ "${image_name}" == 'apigateway-server' ]; then
                  if [[ "${{ inputs.tier }}" =~ ^(Ffe|FFE|ffe|Paid|PAID|paid)$ ]]; then
                    echo "Get tenant status of tenant $tenant_name"
                    tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                    echo "TenantName: ${tenant_name}"
                    tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                    echo "Tenant Status: ${tenant_status}"
                    tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tier')
                    echo "Tenant Tier: ${tenant_tier}"           
                    if [[ "${tenant_status}" == 'DEPLOYED' || "${tenant_status}" == 'FIX_UPGRADE_FAILED' ]]; then
                      echo "Tenant Status is: ${tenant_status}. Hence proceeding"
                      echo "Tenant Tier is ${tenant_tier}"
                        # Iterate through elements of internal_tenants array
                        for internal_tenant in "${internal_tenants[@]}"; do
                          echo "Checking if $tenant_name is an internal tenant or not"
                          echo "Tenant Name: $internal_tenant"
                          # Check if the tenant_name is in $internal_tenant
                          if [[ "${tenant_name}" == "$internal_tenant" ]]; then
                            echo "$tenant_name is an internal tenant"
                            echo "Scheduling upgrade for internal tenant $tenant_name"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                            epochTimestamp=$(date -d "+3 mins" +%s%3N)
                            echo "Upgrade initiated by GitHub user: ${{ github.actor }}"
                            echo "Image tag to be deployed is: ${image_tag}"
                            upgrade_status_code=$(curl -s -X POST "${{ inputs.tms_url }}/tms/v3/release/upgrade/${tenant_name}" -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${tms_access_token}" -H 'Content-Type: application/json' -d '{ "tenantName": "'${tenant_name}'", "scheduledTime": "'${epochTimestamp}'", "nextVersion": "'${image_tag}'", "initiatedBy": "'${{ github.actor }}'", "notificationEmailIds": "'${{ inputs.email_id }}'"}')
                            echo "${upgrade_status_code}"
                            if [ "${upgrade_status_code}" = '202' ]; then
                              echo "Scheduled upgrade for internal tenant ${tenant_name} at ${epochTimestamp}"
                            else
                              echo "Scheduling upgrade failed for internal tenant ${tenant_name}"
                              echo "Reverting latest image from TMS DB"
                              revertLatestImage $image_tag
                            fi

                            # check health of apigw pod

                            n=1
                            apigw_deployment_status="Failure"
                            echo "Get tenant status of internal tenant $tenant_name"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                            echo "Tenant Status: ${tenant_status}"
                            tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                            sleep 10
                            while [[ $n -le 30 ]]
                            do
                              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                              apigw_pod_health=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                              echo "Tenant Status after scheduling upgrade: ${apigw_pod_health}"
                              if [ "$apigw_pod_health" == "DEPLOYED" ]; then
                                apigw_deployment_status="Success"
                                break
                              else
                                echo "Checking Deployment of apigw image on ${tenant_name} internal tenant $n th time"
                                sleep 60
                                n=$(( n+1 ))
                              fi
                            done
                            echo "apigw_deployment_status=${apigw_deployment_status}"
                            if [[ ${apigw_deployment_status} == "Failure" ]]; then
                              apigw_deployment_job_status="Failure"
                              echo "apigw_deployment_job_status=${apigw_deployment_job_status}" >> $GITHUB_OUTPUT                            
                            else
                              apigw_deployment_job_status="Success"
                              echo "apigw_deployment_job_status=${apigw_deployment_job_status}" >> $GITHUB_OUTPUT                            
                            fi                          
                          else
                            echo "$tenant_name is not an internal tenant"
                          fi
                        done
                      fi
                    else
                      echo "Tenant status is not DEPLOYED || FIX_UPGRADE_FAILED "
                    fi
                  fi
                fi
              done
              if [[ "${{ inputs.tier }}" =~ ^(Ffe|FFE|ffe|Paid|PAID|paid)$ ]]; then
                echo "Get tenant status of tenant $tenant_name"
                tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                echo "TenantName: ${tenant_name}"
                tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                echo "Tenant Status: ${tenant_status}"
                tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tier')
                echo "Tenant Tier: ${tenant_tier}"                  
                if [ "${image_name}" == 'apigateway-server' ]; then
                  if [[ "${tenant_status}" == 'DEPLOYED' || "${tenant_status}" == 'FIX_UPGRADE_FAILED' || "${tenant_status}" == 'STOPPED']]; then
                    echo "Tenant Status is: ${tenant_status}. Hence proceeding"
                      echo "Tenant Tier is ${tenant_tier}"                 
                      if [[ "${apigw_deployment_job_status}" == "Success" ]]; then
                        echo "Scheduling upgrade for other tenants in batches as the internal tenant upgrade is successful"
                        echo "Setting epoch timestamp for tenant ${tenant_name} to schedule upgrade"
                        epochTimestamp=$(date -d "+$scheduleAfter mins" +%s%3N)
                        echo "Batch epochTimestamp = $epochTimestamp"
                        for tenant in ${!tenants_batch[@]}; do
                          tenant_name=${tenants_batch[${tenant}]}
                          for internal_tenant in "${internal_tenants[@]}"; do
                            if [[ "${tenant_name}" != "$internal_tenant" ]]; then
                              i=0
                              if [ "$i" -ne "$batch_size" ]; then
                                echo -e "\nNew batch starts. The new batch upgrade will be scheduled after " $scheduleAfter " mins from now"
                                ((scheduleAfter=scheduleAfter+1))
                                echo "TenantName: $tenant_name"
                                epochTimestamp=$(date -d "+$scheduleAfter mins" +%s%3N)
                                echo "new epochTimestamp = " $epochTimestamp
                                echo "entering sleep for "$sleepSecs" seconds"
                                sleep $sleepSecs
                              fi
                              ((i=i+1))
                              echo "Scheduling upgrade for tenant"
                              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                              upgrade_status_code=$(curl -s -X POST "${{ inputs.tms_url }}/tms/v3/release/upgrade/${tenant_name}" -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${tms_access_token}" -H 'Content-Type: application/json' -d '{ "tenantName": "'${tenant_name}'", "scheduledTime": "'${epochTimestamp}'", "nextVersion": "'${image_tag}'", "initiatedBy": "'${{ github.actor }}'", "notificationEmailIds": "'${{ inputs.email_id }}'", "shouldNotifyCustomer": "'${{ inputs.notify_customer }}'"}')
                              if [ "${upgrade_status_code}" = '202' ]; then
                                echo "Scheduled upgrade for tenant ${tenant_name} at ${epochTimestamp}"
                              else
                                echo "Scheduling upgrade failed for tenant ${tenant_name}"                               
                              fi
                            else
                              echo "Internal tenant ${tenant_name} is upgraded already."
                              continue
                            fi
                          done
                        done
                      else
                        echo "Internal tenant deployment failed for apigw. Hence, cannot proceed with upgrading the rest of the tenants."
                      fi
                  elif [[ "${tenant_status}" == 'STOPPED' ]]; then
                    echo "Tenant Status is: ${tenant_status}. Hence proceeding"
                    echo "Tenant Tier is ${tenant_tier}"                 
                    if [[ "${apigw_deployment_job_status}" == "Success" ]]; then
                      echo "Scheduling upgrade for other tenants in batches as the internal tenant upgrade is successful"
                      echo "Setting epoch timestamp for tenant ${tenant_name} to schedule upgrade"
                      epochTimestamp=$(date -d "+$scheduleAfter mins" +%s%3N)
                      echo "Batch epochTimestamp = $epochTimestamp"
                      for tenant in ${!tenants_batch[@]}; do
                        tenant_name=${tenants_batch[${tenant}]}
                        for internal_tenant in "${internal_tenants[@]}"; do
                          if [[ "${tenant_name}" != "$internal_tenant" ]]; then
                            i=0
                            if [ "$i" -ne "$batch_size" ]; then
                              echo -e "\nNew batch starts. The new batch upgrade will be scheduled after " $scheduleAfter " mins from now"
                              ((scheduleAfter=scheduleAfter+1))
                              echo "TenantName: $tenant_name"
                              epochTimestamp=$(date -d "+$scheduleAfter mins" +%s%3N)
                              echo "new epochTimestamp = " $epochTimestamp
                              echo "entering sleep for "$sleepSecs" seconds"
                              sleep $sleepSecs
                            fi
                            ((i=i+1))
                            echo "Scheduling upgrade for tenant"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                            upgrade_status_code=$(curl -s -X POST "${{ inputs.tms_url }}/tms/v3/release/upgrade/${tenant_name}" -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${tms_access_token}" -H 'Content-Type: application/json' -d '{ "tenantName": "'${tenant_name}'", "scheduledTime": "'${epochTimestamp}'", "nextVersion": "'${image_tag}'", "initiatedBy": "'${{ github.actor }}'", "notificationEmailIds": "'${{ inputs.email_id }}'", "shouldNotifyCustomer": "'${{ inputs.notify_customer }}'"}')
                            if [ "${upgrade_status_code}" = '202' ]; then
                              echo "Scheduled upgrade for tenant ${tenant_name} at ${epochTimestamp}"
                            else
                              echo "Scheduling upgrade failed for tenant ${tenant_name}"
                              echo "Reverting latest image from TMS DB"
                              revertLatestImage $image_tag                                
                            fi
                          else
                            echo "Internal tenant ${tenant_name} is upgraded already."
                            continue
                          fi
                        done
                      done
                    else
                      echo "Internal tenant deployment failed for apigw. Hence, cannot proceed with upgrading the rest of the tenants."
                    fi          
                  else
                    echo "Tenant status not in DEPLOYED || FIX_UPGRADE_FAILED || STOPPED"
                  fi
                fi
              fi
            done
          done
        done              


  - name: Deploy kibana image to ${{ inputs.platform }}-${{ inputs.environment }} Runtime
    id: kibanaHealthCheck
    if: inputs.type == 'deploy' && (inputs.tier == 'Paid' || inputs.tier == 'PAID' || inputs.tier == 'paid' || inputs.tier == 'FFE' || inputs.tier == 'Ffe' || inputs.tier == 'ffe')
    shell: bash
    run: |

        batch_size=15
        sleepSecs=3
        scheduleAfter=5

        if [[ "${{ inputs.tenant_names }}" =~ ^(All|ALL|all)$ ]]; then
          echo "Tenant Names are: ${{ inputs.tenant_names }}. Hence excluding tenants from the cluster"
          tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
          if [[ "${{ inputs.tier }}" =~ ^(PAID|Paid|paid)$ ]]; then
            data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants?majorVersion=${{ inputs.major_version }}" | jq -r '.[]| "\(.tenantName)"')
            readarray -t tenants <<<"$data" 
            echo "Exclude Tenant Names: ${{ github.event.inputs.exclude_tenants }}"
            IFS=',' read -r -a excluded_tenants <<< "${{ github.event.inputs.exclude_tenants }}"
            echo "Excluded tenants: ${{ github.event.inputs.exclude_tenants }}"


            for tenant in "${tenants[@]}"; do
              if [[ ! " ${excluded_tenants[@]} " =~ " ${tenant} " ]]; then
                tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant}" | jq -r '.tier')
                echo "Tenant Tier: ${tenant_tier}"
                if [[ "${tenant_tier}" =~ ^PAID_(ADVANCED|BASIC|ENTERPRISE)$ ]]; then
                  tenants_list+=("$tenant")
                  echo "Tenant $tenant is a paid tenant and is included"
                fi
              fi
            done
          else
            data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants?majorVersion=${{ inputs.major_version }}" | jq -r '.[]| "\(.tenantName)"')
            readarray -t tenants <<<"$data" 
            echo "Exclude Tenant Names: ${{ github.event.inputs.exclude_tenants }}"
            IFS=',' read -r -a excluded_tenants <<< "${{ github.event.inputs.exclude_tenants }}"
            echo "Excluded tenants: ${{ github.event.inputs.exclude_tenants }}"


            for tenant in "${tenants[@]}"; do
              if [[ ! " ${excluded_tenants[@]} " =~ " ${tenant} " ]]; then
                tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant}" | jq -r '.tier')
                echo "Tenant Tier: ${tenant_tier}"
                if [[ "${tenant_tier}" =~ ^(FREE_FOREVER)$ ]]; then
                  tenants_list+=("$tenant")
                  echo "Tenant $tenant is an ffe tenant and is included"
                fi
              fi
            done        
          fi        
        else
          echo "Tenant Names are : ${{ inputs.tenant_names }}"
          IFS=',' read -r -a tenants_list <<< "${{ inputs.tenant_names }}"
        fi

        echo "Tenants to be excluded are ${excluded_tenants[@]}"
        echo "Tenants to be included are ${tenants_list[@]}"

        IFS=',' read -r -a internal_tenants <<< "${{ inputs.internal_tenant_names }}"
        echo "Internal Tenants are ${internal_tenants[@]}"

        component_names=($(echo "${{ inputs.component }}" | sed -e 's/,/ /g'))
        image_tags=($(echo "${{ inputs.tag }}" | sed -e 's/,/ /g'))

        echo "Components are: ${component_names[@]}"
        echo "Image Tags are: ${image_tags[@]}"
        echo "Performing deployment operation"
        echo "Tenant names to deploy new images are: ${tenants_list[@]}"

        for component in "${!component_names[@]}"; do
          image_name="${component_names[${component}]}"
          for tag in "${!image_tags[@]}"; do
            image_tag="${image_tags[${tag}]}"
            # Calculate number of batches
            num_batches=$(( (${#tenants_list[@]} + $batch_size - 1) / $batch_size ))
            # Split array into batches and print each batch on a new line
            for ((i = 0; i < $num_batches; i++)); do
              start_index=$(( i * $batch_size ))
              end_index=$(( (i + 1) * $batch_size ))
              tenants_batch=("${tenants_list[@]:$start_index:$batch_size}")
              echo "${tenants_batch[@]}"
              for tenant in ${!tenants_batch[@]}; do
                tenant_name=${tenants_batch[${tenant}]}
                namespace="apigw-${tenant_name}"
                if [ "${image_name}" == 'apigw-kibana' ]; then
                  for internal_tenant in "${internal_tenants[@]}"; do
                    echo "Checking if $tenant_name is an internal tenant or not"   
                    echo "Tenant Name: $tenant_name"
                    # Check if the tenant_name is in $internal_tenant
                    if [[ "${tenant_name}" == "$internal_tenant" ]]; then
                      echo "$tenant_name is an internal tenant"
                      echo "Upgrading kibana image for internal tenant $tenant_name"
                      tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                      data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues")
                      touch data req.json int_req.json
                      echo $data > data
                      jq ". - [{\"name\": \"applications.kibana.imageTag\",\"value\": \"${image_tag}\"}]" data > int_req.json
                      jq ". + [{\"name\": \"applications.kibana.imageTag\",\"value\": \"${image_tag}\"}]" int_req.json > req.json
                      echo "Updating tenant chart values for tenant ${tenant_name} to deploy new image tag for Kibana Runtime"
                      update_tenant_status=$(curl -H "Authorization: Bearer ${tms_access_token}" -o /dev/null -w "%{http_code}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues" -H 'Content-Type: application/json' -d @req.json | sed -e 's/"//g')
                      if [ "${update_tenant_status}" = '200' ]; then
                        echo "Refreshing the tenant to deploy new image tag for Kibana Runtime"
                        curl -H "Authorization: Bearer ${tms_access_token}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}"
                      else
                        echo "Error in updating tenant chart values for tenant ${tenant_name} to deploy new image tag for Kibana Runtime"
                        rm -rf data req.json int_req.json
                      fi
                      rm -rf data req.json int_req.json
                      echo "Checking health of tenant ${tenant_name}'s kibana pod"
                      n=1
                      kibana_deployment_status="Failure"
                      echo "Get tenant status of internal tenant $tenant_name"
                      tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                      tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                      echo "Tenant Status: ${tenant_status}"
                      sleep 10
                      while [[ $n -le 30 ]]
                      do
                        tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                        kibana_pod_health=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                        echo "Tenant Status after scheduling upgrade: ${kibana_pod_health}"
                        if [ "$kibana_pod_health" == "DEPLOYED" ]; then
                          kibana_deployment_status="Success"
                          break
                        else
                          echo "Checking Deployment of kibana image on ${tenant_name} internal tenant $n th time"
                          sleep 60
                          n=$(( n+1 ))
                        fi
                      done
                      echo "kibana_deployment_status=${kibana_deployment_status}" >> $GITHUB_OUTPUT
                      if [[ ${kibana_deployment_status} == "Failure" ]]; then
                        kibana_deployment_job_status="Failure"
                        echo "kibana_deployment_job_status=${kibana_deployment_job_status}" >> $GITHUB_OUTPUT                       
                      else
                        kibana_deployment_job_status="Success"
                        echo "kibana_deployment_job_status=${kibana_deployment_job_status}" >> $GITHUB_OUTPUT
                      fi
                    else
                      echo "$tenant_name is not an internal tenant"
                    fi
                  done
                fi
              done

              if [[ "${{ inputs.tier }}" =~ ^(Paid|PAID|paid|FFE|Ffe|ffe)$ ]]; then
                echo "Get tenant status of tenant $tenant_name"
                tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                echo "TenantName: ${tenant_name}"
                tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                echo "Tenant Status: ${tenant_status}"
                if [ "${image_name}" == 'apigw-kibana' ]; then
                  if [[ "${tenant_status}" == 'DEPLOYED' || "${tenant_name}" == 'STOPPED' || "${tenant_name}" == 'FIX_UPGRADE_FAILED' ]]; then
                    if [[ "${kibana_deployment_job_status}" == "Success" ]]; then
                      echo "Upgrading kibana for other tenants in batches as the internal tenant upgrade is successful"
                      for tenant in ${!tenants_batch[@]}; do
                        tenant_name=${tenants_batch[${tenant}]}
                        for internal_tenant in "${internal_tenants[@]}"; do
                          if [[ "${tenant_name}" != "$internal_tenant" ]]; then
                            echo "Upgrading kibana image for tenant $tenant_name"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                            data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues")
                            touch data int_req.json req.json
                            echo $data > data
                            jq ". - [{\"name\": \"applications.kibana.imageTag\",\"value\": \"${image_tag}\"}]" data > int_req.json
                            jq ". + [{\"name\": \"applications.kibana.imageTag\",\"value\": \"${image_tag}\"}]" int_req.json > req.json
                            echo "Updating tenant chart values for tenant ${tenant_name} to deploy new image tag for Kibana Runtime"
                            update_tenant_status=$(curl -H "Authorization: Bearer ${tms_access_token}" -o /dev/null -w "%{http_code}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues" -H 'Content-Type: application/json' -d @req.json | sed -e 's/"//g')
                            if [ "${update_tenant_status}" = '200' ]; then
                              echo "Refreshing the tenant to deploy new image tag for Kibana Runtime"
                              curl -H "Authorization: Bearer ${tms_access_token}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}"
                            else
                              echo "Error in updating tenant chart values for tenant ${tenant_name} to deploy new image tag for Kibana Runtime"
                              rm -rf data req.json int_req.json
                            fi
                            rm -rf data req.json int_req.json
                          else
                            echo "Internal tenant ${tenant_name} is upgraded already."
                            continue
                          fi 
                        done
                      done                                          
                    else
                      echo "Internal tenant deployment failed for kibana. Hence, cannot proceed with upgrading the rest of the tenants."
                    fi
                  else
                    echo "Tenant status not in DEPLOYED || STOPPED || FIX_UPGRADE_FAILED"
                  fi
                fi
              else
                echo "Provided tenant tier not available to process for kibana image upgrade"
              fi
            done
          done
        done

  - name: Rollback apigw image to ${{ inputs.platform }}-${{ inputs.environment }} Runtime
    if: inputs.type == 'rollback' && (inputs.tier == 'Paid' || inputs.tier == 'PAID' || inputs.tier == 'paid' || inputs.tier == 'FFE' || inputs.tier == 'Ffe' || inputs.tier == 'ffe')
    shell: bash
    run: |

        batch_size=15
        sleepSecs=3
        scheduleAfter=5      
      
        if [[ "${{ inputs.tenant_names }}" =~ ^(All|ALL|all)$ ]]; then
          echo "Tenant Names are: ${{ inputs.tenant_names }}. Hence excluding tenants from the cluster"
          tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
          data=$(curl -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants?majorVersion=${{ inputs.major_version }}" | jq -r '.[]| "\(.tenantName)"')
          readarray -t tenants <<<"$data" 
          echo "Exclude Tenant Names: ${{ github.event.inputs.exclude_tenants }}"
          IFS=',' read -r -a excluded_tenants <<< "${{ github.event.inputs.exclude_tenants }}"
          echo "Excluded tenants: ${{ github.event.inputs.exclude_tenants }}"

          for tenant in "${tenants[@]}"; do
            if [[ ! " ${excluded_tenants[@]} " =~ " ${tenant} " ]]; then
              echo "Tenant $tenant is included"
              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
              tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant}" | jq -r '.tier')
              echo "Tenant Tier: ${tenant_tier}"
                tenants_list+=("$tenant")
              fi
            fi
          done
        else
          echo "Tenant Names are : ${{ inputs.tenant_names }}"
          IFS=',' read -r -a tenants_list <<< "${{ inputs.tenant_names }}"
        fi

        echo "Tenants to be excluded are ${excluded_tenants[@]}"
        echo "Tenants to be included are ${tenants_list[@]}"

        IFS=',' read -r -a internal_tenants <<< "${{ inputs.internal_tenant_names }}"
        echo "Internal Tenants are ${internal_tenants[@]}"

        component_names=($(echo "${{ inputs.component }}" | sed -e 's/,/ /g'))
        image_tags=()
        if [[ -z "${{ inputs.tag }}" ]]; then
          image_tags+="${{ steps.fetch-stable-image.outputs.application_stable_image }}"
        else
          IFS=',' read -r -a image_tags <<< "${{ inputs.tag }}"
        fi

        echo "image tag: ${image_tags}"
        echo "app stable image: ${{ steps.fetch-stable-image.outputs.application_stable_image }}"
        echo "Components are: ${component_names[@]}"
        echo "Image Tags are: ${image_tags[@]}"
        echo "Performing deployment operation"
        echo "Tenant names to deploy new images are: ${tenants_list[@]}"

        for component in "${!component_names[@]}"; do
          image_name="${component_names[${component}]}"
          for tag in "${!image_tags[@]}"; do
            image_tag="${image_tags[${tag}]}"
            # Calculate number of batches
            num_batches=$(( (${#tenants_list[@]} + $batch_size - 1) / $batch_size ))
            # Split array into batches and print each batch on a new line
            for ((i = 0; i < $num_batches; i++)); do
              start_index=$(( i * $batch_size ))
              end_index=$(( (i + 1) * $batch_size ))
              tenants_batch=("${tenants_list[@]:$start_index:$batch_size}")
              echo "${tenants_batch[@]}"
              for tenant in ${!tenants_batch[@]}; do
                tenant_name=${tenants_batch[${tenant}]}
                namespace="apigw-${tenant_name}"
                if [ "${image_name}" == 'apigateway-server' ]; then
                    echo "Get tenant status of tenant $tenant_name"
                    tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                    echo "TenantName: ${tenant_name}"
                    tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                    echo "Tenant Status: ${tenant_status}"
                    tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tier')
                    echo "Tenant Tier: ${tenant_tier}"           
                    if [[ "${tenant_status}" == 'DEPLOYED' || "${tenant_status}" == 'FIX_UPGRADE_FAILED' ]]; then
                      echo "Tenant Status is: ${tenant_status}. Hence proceeding"
                        echo "Tenant Tier is ${tenant_tier}"
                        # Iterate through elements of internal_tenants array
                        for internal_tenant in "${internal_tenants[@]}"; do
                          echo "Checking if $tenant_name is an internal tenant or not"
                          echo "Tenant Name: $internal_tenant"
                          # Check if the tenant_name is in $internal_tenant
                          if [[ "${tenant_name}" == "$internal_tenant" ]]; then
                            echo "$tenant_name is an internal tenant"
                            echo "Updating chart values for internal tenant $tenant_name"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                # Retrieve current chart values
                            current_chart_values=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues")

                            # Save current chart values to a file
                            echo "$current_chart_values" > data.json

                            # Update chart values using jq commands
                            jq ". - [{\"name\": \"applications.apigw.imageTag\",\"value\": \"${currentApigwImage}\"}]" data.json > int_req.json
                            jq ". - [{\"name\": \"versionNo\",\"value\": \"${currentApigwImage}\"}]" int_req.json > inter_req.json
                            jq ". + [{\"name\": \"applications.apigw.imageTag\",\"value\": \"${image_tag}\"}]" inter_req.json > interm_req.json
                            jq ". + [{\"name\": \"versionNo\",\"value\": \"${image_tag}\"}]" interm_req.json > int_req.json

                            # Read updated chart values from the file
                            updated_chart_values=$(cat int_req.json)

                            # Update tenant chart values with the updated JSON
                            update_tenant_status=$(curl -H "Authorization: Bearer ${tms_access_token}" -o /dev/null -w "%{http_code}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues" -H 'Content-Type: application/json' -d "$updated_chart_values" | sed -e 's/"//g')
                            if [ "${update_tenant_status}" = '200' ]; then
                                echo "Refreshing the tenant to deploy new image tag for apigw Runtime"
                                curl -H "Authorization: Bearer ${tms_access_token}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}"
                            else
                                echo "Error in updating tenant chart values for tenant ${tenant_name} to deploy new image tag for apigw Runtime"
                            fi
                            rm -rf data req.json int_req.json inter_req.json interm_req.json

                            # check health of apigw pod

                            n=1
                            apigw_rollback_status="Failure"
                            echo "Get tenant status of internal tenant $tenant_name"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                            echo "Tenant Status: ${tenant_status}"
                            tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                            sleep 10
                            while [[ $n -le 30 ]]
                            do
                              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                              apigw_pod_health=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                              echo "Tenant Status after scheduling upgrade: ${apigw_pod_health}"
                              if [ "$apigw_pod_health" == "DEPLOYED" ]; then
                                apigw_rollback_status="Success"
                                break
                              else
                                echo "Checking Deployment of apigw image on ${tenant_name} internal tenant $n th time"
                                sleep 60
                                n=$(( n+1 ))
                              fi
                            done
                            echo "apigw_rollback_status=${apigw_rollback_status}"
                            if [[ ${apigw_rollback_status} == "Failure" ]]; then
                              apigw_rollback_job_status="Failure"
                              echo "apigw_rollback_job_status=${apigw_rollback_job_status}" >> $GITHUB_OUTPUT                            
                            else
                              apigw_rollback_job_status="Success"
                              echo "apigw_rollback_job_status=${apigw_rollback_job_status}" >> $GITHUB_OUTPUT                            
                            fi                          
                          else
                            echo "$tenant_name is not an internal tenant"
                          fi
                        done
                      fi
                    else
                      echo "Tenant status is not DEPLOYED || FIX_UPGRADE_FAILED"
                    fi
                  fi
                fi
              done
              if [[ "${{ inputs.tier }}" =~ ^(Ffe|FFE|ffe|Paid|PAID|paid)$ ]]; then
                echo "Get tenant status of tenant $tenant_name"
                tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                echo "TenantName: ${tenant_name}"
                tenant_status=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tenantStatus')
                echo "Tenant Status: ${tenant_status}"
                tenant_tier=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}" | jq -r '.tier')
                echo "Tenant Tier: ${tenant_tier}"                  
                if [ "${image_name}" == 'apigateway-server' ]; then
                  if [[ "${tenant_status}" == 'DEPLOYED' || "${tenant_name}" == 'FIX_UPGRADE_FAILED' || "${tenant_status}" == 'STOPPED' ]]; then
                    echo "Tenant Status is: ${tenant_status}. Hence proceeding"
                      echo "Tenant Tier is ${tenant_tier}"                 
                      if [[ "${apigw_rollback_job_status}" == "Success" ]]; then
                        echo "Rolling back apigw image for other tenants in batches as the internal tenant rollback is successful"
                        for tenant in ${!tenants_batch[@]}; do
                          tenant_name=${tenants_batch[${tenant}]}
                          for internal_tenant in "${internal_tenants[@]}"; do
                            if [[ "${tenant_name}" != "$internal_tenant" ]]; then
                              echo "Rolling back image tag for tenant"
                              tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                    # Retrieve current chart values
                              current_chart_values=$(curl -s -H "Authorization: Bearer ${tms_access_token}" -X GET "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues") 
                              # Save current chart values to a file
                              echo "$current_chart_values" > data 
                              # Update chart values using jq commands
                              jq ". - [{\"name\": \"applications.apigw.imageTag\",\"value\": \"${currentApigwImage}\"}]" data.json > int_req.json
                              jq ". - [{\"name\": \"versionNo\",\"value\": \"${currentApigwImage}\"}]" int_req.json > inter_req.json
                              jq ". + [{\"name\": \"applications.apigw.imageTag\",\"value\": \"${image_tag}\"}]" inter_req.json > interm_req.json
                              jq ". + [{\"name\": \"versionNo\",\"value\": \"${image_tag}\"}]" interm_req.json > int_req 
                              # Read updated chart values from the file
                              updated_chart_values=$(cat int_req.json)
                              # Update tenant chart values with the updated JSON
                              update_tenant_status=$(curl -H "Authorization: Bearer ${tms_access_token}" -o /dev/null -w "%{http_code}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}/chartvalues" -H 'Content-Type: application/json' -d "$updated_chart_values" | sed -e 's/"//g')
                              if [ "${update_tenant_status}" = '200' ]; then
                                  echo "Refreshing the tenant to deploy new image tag for apigw Runtime"
                                  curl -H "Authorization: Bearer ${tms_access_token}" -s -X PUT "${{ inputs.tms_url }}/tms/v3/tenants/${tenant_name}"
                              else
                                  echo "Error in updating tenant chart values for tenant ${tenant_name} to deploy new image tag for apigw Runtime" 			          
                              fi
                              rm -rf data req.json int_req.json inter_req.json interm_req.json
                            else
                              echo "Internal tenant ${tenant_name} is upgraded already."
                              continue
                            fi
                          done
                        done
                      else
                        echo "Internal tenant deployment failed for apigw. Hence, cannot proceed with upgrading the rest of the tenants."
                      fi
                   elif [[ "${tenant_status}" == 'STOPPED' ]]; then
                    echo "Tenant Status is: ${tenant_status}. Hence proceeding"
                    echo "Tenant Tier is ${tenant_tier}"                 
                    if [[ "${apigw_rollback_job_status}" == "Success" ]]; then
                      echo "Scheduling upgrade for other tenants in batches as the internal tenant upgrade is successful"
                      echo "Setting epoch timestamp for tenant ${tenant_name} to schedule upgrade"
                      epochTimestamp=$(date -d "+$scheduleAfter mins" +%s%3N)
                      echo "Batch epochTimestamp = $epochTimestamp"
                      for tenant in ${!tenants_batch[@]}; do
                        tenant_name=${tenants_batch[${tenant}]}
                        for internal_tenant in "${internal_tenants[@]}"; do
                          if [[ "${tenant_name}" != "$internal_tenant" ]]; then
                            i=0
                            if [ "$i" -ne "$batch_size" ]; then
                              echo -e "\nNew batch starts. The new batch upgrade will be scheduled after " $scheduleAfter " mins from now"
                              ((scheduleAfter=scheduleAfter+1))
                              echo "TenantName: $tenant_name"
                              epochTimestamp=$(date -d "+$scheduleAfter mins" +%s%3N)
                              echo "new epochTimestamp = " $epochTimestamp
                              echo "entering sleep for "$sleepSecs" seconds"
                              sleep $sleepSecs
                            fi
                            ((i=i+1))
                            echo "Scheduling upgrade for tenant"
                            tms_access_token=$(curl -s -d 'client_id='${{ inputs.tms_client_id }}'' -d 'client_secret='${{ inputs.tms_client_secret }}'' -d 'grant_type=client_credentials' ${{ inputs.kc_url }}/auth/realms/${{ inputs.kc_realm }}/protocol/openid-connect/token | jq -r '.access_token')
                            upgrade_status_code=$(curl -s -X POST "${{ inputs.tms_url }}/tms/v3/release/upgrade/${tenant_name}" -o /dev/null -w "%{http_code}" -H "Authorization: Bearer ${tms_access_token}" -H 'Content-Type: application/json' -d '{ "tenantName": "'${tenant_name}'", "scheduledTime": "'${epochTimestamp}'", "nextVersion": "'${image_tag}'", "initiatedBy": "'${{ github.actor }}'", "notificationEmailIds": "'${{ inputs.email_id }}'", "shouldNotifyCustomer": "'${{ inputs.notify_customer }}'"}')
                            if [ "${upgrade_status_code}" = '202' ]; then
                              echo "Scheduled upgrade for tenant ${tenant_name} at ${epochTimestamp}"
                            else
                              echo "Scheduling upgrade failed for tenant ${tenant_name}"
                              echo "Reverting latest image from TMS DB"
                              revertLatestImage $image_tag                                
                            fi
                          else
                            echo "Internal tenant ${tenant_name} is upgraded already."
                            continue
                          fi
                        done
                      done
                    else
                      echo "Internal tenant deployment failed for apigw. Hence, cannot proceed with upgrading the rest of the tenants."                     
                    fi
                  else
                    echo "Tenant status not in DEPLOYED || FIX_UPGRADE_FAILED ||STOPPED"
                  fi            
                fi
              fi
            done
          done
        done              
