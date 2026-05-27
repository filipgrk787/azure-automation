#!/bin/bash

subscriptions=($(az account list --query "[].{name:name, id:id}" -o tsv))
subscription_names=()
subscription_ids=()
for ((i=0; i<${#subscriptions[@]}; i+=2)); do
  name="${subscriptions[i]}"
  if [[ "$name" == "MCPP Subscription" || "$name" == "Microsoft Azure Sponsorship" ]]; then
    continue
  fi
  subscription_names+=("$name")
  subscription_ids+=("${subscriptions[i+1]}")
done

if [[ ${#subscription_names[@]} -eq 0 ]]; then
  echo "No subscriptions found (after excluding MCPP Subscription and Microsoft Azure Sponsorship). Please check your Azure login."
  exit 1
fi

echo "Select the Azure Subscription:"
COLUMNS=1
PS3="Enter the number corresponding to the Subscription: "

select subscription_choice in "${subscription_names[@]}"; do
  if [[ -n "$subscription_choice" ]]; then
    selected_index=$((REPLY-1))
    selected_subscription_id="${subscription_ids[$selected_index]}"
    selected_subscription_id=$(echo "$selected_subscription_id" | tr -d '\r\n')
    subscription_choice=$(echo "$subscription_choice" | tr -d '\r\n')
    az account set --subscription "$selected_subscription_id"
    echo "Selected Subscription: '${subscription_choice}' (${selected_subscription_id})"
    break
  else
    echo "Invalid selection. Try again."
  fi
done

# Step 2: Select Resource Group (with filtering and "Not Sure" option)
all_resource_groups_output=$(az group list --query "[].name" -o tsv)
filtered_resource_groups=()

# Filter out unwanted resource groups
while IFS= read -r rg; do
  rg=$(echo "$rg" | tr -d '\r\n')
  if [[ ! "$rg" =~ ^MC_ ]] && \
     [[ ! "$rg" =~ ^ResourceMoverRG ]] && \
     [[ ! "$rg" =~ ^AzureBackupRG ]] && \
     [[ ! "$rg" =~ ^NetworkWatcherRG ]] && \
     [[ ! "$rg" =~ ^LogAnalyticsDefaultResources ]] && \
     [[ ! "$rg" =~ ^ai_ ]] && \
     [[ ! "$rg" =~ ^Default-ActivityLogAlerts ]]; then
    filtered_resource_groups+=("$rg")
  fi
done <<< "$all_resource_groups_output"

# Add "Not Sure" option
filtered_resource_groups+=("Not Sure - Search All Resource Groups")

echo "Select the Resource Group:"
COLUMNS=1
PS3="Enter the number corresponding to the Resource Group: "
select resource_group_choice in "${filtered_resource_groups[@]}"; do
  if [[ -n "$resource_group_choice" ]]; then
    if [[ "$resource_group_choice" == "Not Sure - Search All Resource Groups" ]]; then
      echo "Searching for Front Door profiles across all resource groups..."
      search_all_rgs=true
      resource_group_name=""
     
      # Collect all Front Door profiles from all resource groups
      all_fd_profiles=()
      all_fd_rgs=()
     
      for rg in "${filtered_resource_groups[@]}"; do
        if [[ "$rg" == "Not Sure - Search All Resource Groups" ]]; then
          continue
        fi
        rg_clean=$(echo "$rg" | tr -d '\r\n')
        fd_in_rg=$(az afd profile list --resource-group "$rg_clean" --query "[].name" -o tsv 2>/dev/null | tr -d '\r')
       
        if [[ -n "$fd_in_rg" ]]; then
          while IFS= read -r profile; do
            profile_clean=$(echo "$profile" | tr -d '\r\n')
            all_fd_profiles+=("$profile_clean")
            all_fd_rgs+=("$rg_clean")
          done <<< "$fd_in_rg"
        fi
      done
     
      if [[ ${#all_fd_profiles[@]} -eq 0 ]]; then
        echo "No Azure Front Door profiles found in any resource group."
        exit 1
      fi
     
      # Display profiles with their resource groups
      echo "Select the Azure Front Door profile(s) (you can select multiple):"
      echo "Available profiles:"
      for i in "${!all_fd_profiles[@]}"; do
        echo "$((i+1)). ${all_fd_profiles[$i]} (RG: ${all_fd_rgs[$i]})"
      done
     
      read -p "Enter the numbers separated by spaces (e.g., '1 3 5'): " selected_profiles
      selected_fd_profiles=()
      selected_fd_rgs=()
     
      for num in $selected_profiles; do
        index=$((num-1))
        if [[ $index -ge 0 && $index -lt ${#all_fd_profiles[@]} ]]; then
          selected_fd_profiles+=("${all_fd_profiles[$index]}")
          selected_fd_rgs+=("${all_fd_rgs[$index]}")
        fi
      done
     
      if [[ ${#selected_fd_profiles[@]} -eq 0 ]]; then
        echo "No valid profiles selected."
        exit 1
      fi
     
    else
      search_all_rgs=false
      resource_group_name=$(echo "$resource_group_choice" | tr -d '\r\n')
      echo "Selected Resource Group: '${resource_group_name}'"
     
      # Original flow for single resource group
      fd_profiles_output=$(az afd profile list --resource-group "$resource_group_name" --query "[].name" -o tsv 2>/dev/null)
      fd_profiles_output=$(echo "$fd_profiles_output" | tr -d '\r')
     
      if [[ -z "$fd_profiles_output" ]]; then
        echo "No Azure Front Door profiles found in resource group '$resource_group_name'. Please select a different resource group."
        exit 1
      fi
     
      mapfile -t fd_profiles <<< "$fd_profiles_output"
     
      echo "Select the Azure Front Door profile:"
      PS3="Enter the number corresponding to the Front Door profile: "
      select frontdoor_profile_name in "${fd_profiles[@]}"; do
        if [[ -n "$frontdoor_profile_name" ]]; then
          frontdoor_profile_name=$(echo "$frontdoor_profile_name" | tr -d '\r\n')
          selected_fd_profiles=("$frontdoor_profile_name")
          selected_fd_rgs=("$resource_group_name")
          break
        else
          echo "Invalid selection. Try again."
        fi
      done
    fi
    break
  else
    echo "Invalid selection. Try again."
  fi
done

# Step 3: Enter Priority and State
read -p "Enter the origin Priority to match (e.g., '1' for Prod or '2' for DR): " keyword
read -p "Enter the desired state for the origins (Enabled/Disabled): " state

# Step 4: Collect all matching origins from selected profiles
all_origin_ids=""
profile_summary=""

for idx in "${!selected_fd_profiles[@]}"; do
  current_profile="${selected_fd_profiles[$idx]}"
  current_rg="${selected_fd_rgs[$idx]}"
 
  profile_summary+="  - Profile: $current_profile (RG: $current_rg)"$'\n'
 
  origin_groups_output=$(az afd origin-group list \
    --profile-name "${current_profile}" \
    --resource-group "${current_rg}" \
    --query "[].name" \
    --output tsv)
  origin_groups_output=$(echo "$origin_groups_output" | tr -d '\r')
  mapfile -t origin_groups <<< "$origin_groups_output"
 
  for origin_group_name in "${origin_groups[@]}"; do
    origin_group_name_cl=$(echo "${origin_group_name}" | tr -d '\r\n')
   
    prod_origins_ids_output=$(az afd origin list \
      --profile-name "${current_profile}" \
      --origin-group-name "${origin_group_name_cl}" \
      --resource-group "${current_rg}" \
      --query "[?priority==\`${keyword}\`].id" \
      --output tsv)
    prod_origins_ids_output=$(echo "$prod_origins_ids_output" | tr -d '\r')
   
    if [[ -n "$prod_origins_ids_output" ]]; then
      all_origin_ids+="${prod_origins_ids_output}"$'\n'
    fi
  done
done

if [[ -n "$all_origin_ids" ]]; then
  mapfile -t origin_id_list <<< "$all_origin_ids"
  origins_found_str=$(printf '%s\n' "${origin_id_list[@]}")
else
  origins_found_str="No origins matched the priority ${keyword}."
fi

# Step 5: Display Configuration Summary
echo "================== CONFIGURATION SUMMARY =================="
echo "  Subscription           : ${subscription_choice}"
if [[ "$search_all_rgs" == true ]]; then
  echo "  Search Mode            : All Resource Groups"
  echo "  Selected Profiles      :"
  printf "%s" "$profile_summary"
else
  echo "  Resource Group         : $resource_group_name"
  echo "  Front Door Profile     : ${selected_fd_profiles[0]}"
fi
echo "  Priority to Match      : $keyword"
echo "  Desired State          : $state"
echo "---------------- Origins to update ------------------------"
printf "%s\n" "$origins_found_str"
echo "==========================================================="
read -p "Is the above configuration correct and do you want to proceed? (Y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Script stopped due to user selection."
  exit 0
fi

# Step 6: Execute Updates
if [[ -n "$all_origin_ids" ]]; then
  echo "Attempting to set state '${state}' on all matched origins in parallel..."
  while IFS= read -r origin_id; do
    origin_id=$(echo "$origin_id" | tr -d '\r\n')
    az afd origin update --ids "${origin_id}" --enabled-state "${state}" &
  done <<< "$all_origin_ids"
  wait
  echo "Finished updating all origins."
else
  echo "No origins matched the priority ${keyword}."
fi

echo "-------------------"
echo "Origin updates completed."
echo ""

# ============================================================================
# PURGE FUNCTIONALITY
# ============================================================================

read -p "Do you want to purge endpoints? (Y/N): " purge_confirm
if [[ ! "$purge_confirm" =~ ^[Yy]$ ]]; then
  echo "Skipping purge. Script finished."
  exit 0
fi

echo ""
echo "==================== PURGE CONFIGURATION ===================="

# Step 7: Collect all endpoints from selected profiles
all_endpoints=()
all_endpoint_rgs=()
all_endpoint_profiles=()

for idx in "${!selected_fd_profiles[@]}"; do
  current_profile="${selected_fd_profiles[$idx]}"
  current_rg="${selected_fd_rgs[$idx]}"
 
  endpoints_output=$(az afd endpoint list \
    --profile-name "${current_profile}" \
    --resource-group "${current_rg}" \
    --query "[].name" \
    --output tsv 2>/dev/null)
  endpoints_output=$(echo "$endpoints_output" | tr -d '\r')
 
  if [[ -n "$endpoints_output" ]]; then
    while IFS= read -r endpoint; do
      endpoint_clean=$(echo "$endpoint" | tr -d '\r\n')
      all_endpoints+=("$endpoint_clean")
      all_endpoint_rgs+=("$current_rg")
      all_endpoint_profiles+=("$current_profile")
    done <<< "$endpoints_output"
  fi
done

if [[ ${#all_endpoints[@]} -eq 0 ]]; then
  echo "No endpoints found in the selected Front Door profile(s)."
  exit 0
fi

# Step 8: Select endpoint(s) to purge
echo "Select the endpoint(s) to purge (you can select multiple):"
echo "Available endpoints:"
for i in "${!all_endpoints[@]}"; do
  echo "$((i+1)). ${all_endpoints[$i]} (Profile: ${all_endpoint_profiles[$i]}, RG: ${all_endpoint_rgs[$i]})"
done

read -p "Enter the numbers separated by spaces (e.g., '1 3 5'): " selected_endpoints_input
selected_endpoints=()
selected_endpoint_rgs=()
selected_endpoint_profiles=()

for num in $selected_endpoints_input; do
  index=$((num-1))
  if [[ $index -ge 0 && $index -lt ${#all_endpoints[@]} ]]; then
    selected_endpoints+=("${all_endpoints[$index]}")
    selected_endpoint_rgs+=("${all_endpoint_rgs[$index]}")
    selected_endpoint_profiles+=("${all_endpoint_profiles[$index]}")
  fi
done

if [[ ${#selected_endpoints[@]} -eq 0 ]]; then
  echo "No valid endpoints selected. Skipping purge."
  exit 0
fi

# Step 9: Collect custom domains for selected endpoints (filter out azurefd.net)
all_domains=()
all_domain_endpoints=()
all_domain_profiles=()
all_domain_rgs=()

for idx in "${!selected_endpoints[@]}"; do
  current_endpoint="${selected_endpoints[$idx]}"
  current_rg="${selected_endpoint_rgs[$idx]}"
  current_profile="${selected_endpoint_profiles[$idx]}"
 
  # Get all routes for this endpoint to find associated domains
  routes_output=$(az afd route list \
    --profile-name "${current_profile}" \
    --endpoint-name "${current_endpoint}" \
    --resource-group "${current_rg}" \
    --query "[].name" \
    --output tsv 2>/dev/null)
  routes_output=$(echo "$routes_output" | tr -d '\r')
 
  if [[ -n "$routes_output" ]]; then
    mapfile -t routes_array <<< "$routes_output"
   
    for route_name in "${routes_array[@]}"; do
      route_name_clean=$(echo "$route_name" | tr -d '\r\n')
      [[ -z "$route_name_clean" ]] && continue
     
      # Get custom domains for this specific route
      route_domains=$(az afd route show \
        --profile-name "${current_profile}" \
        --endpoint-name "${current_endpoint}" \
        --route-name "${route_name_clean}" \
        --resource-group "${current_rg}" \
        --query "customDomains[].id" \
        --output tsv 2>/dev/null)
      route_domains=$(echo "$route_domains" | tr -d '\r')
     
      if [[ -n "$route_domains" ]]; then
        while IFS= read -r domain_id; do
          domain_id_clean=$(echo "$domain_id" | tr -d '\r\n')
          # Extract domain name from ID
          domain_name=$(echo "$domain_id_clean" | awk -F'/' '{print $NF}')
         
          # Get the actual hostname
          domain_hostname=$(az afd custom-domain show \
            --profile-name "${current_profile}" \
            --custom-domain-name "${domain_name}" \
            --resource-group "${current_rg}" \
            --query "hostName" \
            --output tsv 2>/dev/null | tr -d '\r\n')
         
          # Filter out azurefd.net domains and duplicates
          if [[ -n "$domain_hostname" ]] && [[ ! "$domain_hostname" =~ azurefd\.net$ ]]; then
            # Check if domain already added (avoid duplicates)
            if [[ ! " ${all_domains[@]} " =~ " ${domain_hostname} " ]]; then
              all_domains+=("$domain_hostname")
              all_domain_endpoints+=("$current_endpoint")
              all_domain_profiles+=("$current_profile")
              all_domain_rgs+=("$current_rg")
            fi
          fi
        done <<< "$route_domains"
      fi
    done
  fi
done

if [[ ${#all_domains[@]} -eq 0 ]]; then
  echo "No custom domains found for the selected endpoint(s) (azurefd.net domains filtered out)."
  exit 0
fi

# Step 10: Select domain(s) to purge
echo ""
echo "Select the domain(s) to purge (you can select multiple):"
echo "Available custom domains:"
for i in "${!all_domains[@]}"; do
  echo "$((i+1)). ${all_domains[$i]} (Endpoint: ${all_domain_endpoints[$i]})"
done

read -p "Enter the numbers separated by spaces (e.g., '1 3 5'): " selected_domains_input
selected_domains=()
selected_domain_endpoints=()
selected_domain_profiles=()
selected_domain_rgs=()

for num in $selected_domains_input; do
  index=$((num-1))
  if [[ $index -ge 0 && $index -lt ${#all_domains[@]} ]]; then
    selected_domains+=("${all_domains[$index]}")
    selected_domain_endpoints+=("${all_domain_endpoints[$index]}")
    selected_domain_profiles+=("${all_domain_profiles[$index]}")
    selected_domain_rgs+=("${all_domain_rgs[$index]}")
  fi
done

if [[ ${#selected_domains[@]} -eq 0 ]]; then
  echo "No valid domains selected. Skipping purge."
  exit 0
fi

# Step 11: Display Purge Configuration Summary
echo ""
echo "================== PURGE SUMMARY =================="
echo "  Content Paths          : /* (all paths)"
echo "---------------- Domains to purge -----------------"
for i in "${!selected_domains[@]}"; do
  echo "  ${selected_domains[$i]}"
  echo "    → Endpoint: ${selected_domain_endpoints[$i]}"
  echo "    → Profile: ${selected_domain_profiles[$i]}"
  echo "    → Resource Group: ${selected_domain_rgs[$i]}"
done
echo "==================================================="
read -p "Proceed with purge? (Y/N): " purge_final_confirm
if [[ ! "$purge_final_confirm" =~ ^[Yy]$ ]]; then
  echo "Purge cancelled. Script finished."
  exit 0
fi

# Step 12: Execute purges in parallel
echo ""
echo "Executing purges in parallel..."
purge_errors=0

for i in "${!selected_domains[@]}"; do
  {
    domain="${selected_domains[$i]}"
    endpoint="${selected_domain_endpoints[$i]}"
    profile="${selected_domain_profiles[$i]}"
    rg="${selected_domain_rgs[$i]}"
   
    echo "Purging: $domain (Endpoint: $endpoint)..."
    if az afd endpoint purge \
      --resource-group "$rg" \
      --profile-name "$profile" \
      --endpoint-name "$endpoint" \
      --domains "$domain" \
      --content-paths '/*' 2>&1; then
      echo "✓ Successfully purged: $domain"
    else
      echo "✗ Failed to purge: $domain"
      ((purge_errors++))
    fi
  } &
done

wait

echo ""
echo "-------------------"
if [[ $purge_errors -eq 0 ]]; then
  echo "✓ All purges completed successfully!"
else
  echo "⚠ Purge completed with $purge_errors error(s). Please check the output above."
fi
echo "Script finished."
