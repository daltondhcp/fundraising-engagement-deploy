#!/bin/bash
set -e

while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
    -g|--group)
      RESOURCE_GROUP="$2"
      shift; shift
      ;;
    -u|--url)
      URL="$2"
      shift; shift
      ;;
    -n|--function-name)
      FUNCTION_APP_NAME="$2"
      shift; shift
      ;;
    -f|--afd-name)
      AFD_NAME="$2"
      shift; shift
      ;;
    *)
      >&2 echo "Invalid parameter: $key"
      shift; shift
      ;;
  esac
done

if [[ -z $RESOURCE_GROUP || -z $FUNCTION_APP_NAME || -z $URL ]]; then
  >&2 echo "ERROR: Please set all required parameters"
   # Display Help
  >&2 echo "Command"
  >&2 echo "   setup-webhook: Setup webhook integration to Azure function"
  >&2 echo ""
  >&2 echo "Arguments (All required)"
  >&2 echo "   -g|--group             : Resource group where Azure Function is."
  >&2 echo "   -u|--url               : Url of Power platform environment."
  >&2 echo "   -n|--function-name     : Name of Azure Function in Azure for lookup."
  >&2 echo "   -f|--afd-name          : Url of the Azure Front Door Front end."
  >&2 echo
  exit 1
fi

set -u

_function_url=$AFD_NAME # Replace this with correct URL to Azure Front Door Instance. To use the actual function URL, uncomment row 127
WEBHOOK_NAME='FEPaymentService'
SERVICE_ENDPOINT_URL="${URL%/}/api/data/v9.2/serviceendpoints"

TOKEN=$(az account get-access-token --resource=$URL --query accessToken -o tsv 2>/dev/null || true) # This is expected to fail in Azure Cloud Shell
if [[ -z $TOKEN ]]; then
  read -p 'Enter your Dynamics Access Token: ' TOKEN
fi
TOKEN="$(echo $TOKEN | xargs)" # trim whitespace

function _get_or_set_function_key {
  local resource_group=$1
  local function_app_name=$2

  local dataverse_key_name="dataverse"
  local current_keys="$(az functionapp keys list -n $function_app_name -g $resource_group)"

  if [[ $(jq '.functionKeys | has("dataverse")' <<< $current_keys) == false ]]; then
    echo >&2 "Creating new Function key"
    current_keys=$(az functionapp keys set --key-type functionKeys --key-name $dataverse_key_name -n $function_app_name -g $resource_group)
  else
    echo >&2 "Key is already defined; reusing"
  fi
  echo $(jq -r '.functionKeys.dataverse' <<< $current_keys)
}

function _get_webhook_id {
  echo >&2 "Retrieving Webhook Id"
  local webhook_response=$(curl $SERVICE_ENDPOINT_URL -G \
    -sL -w '{ "statusCode": %{http_code}}' \
    -H "Accept: application/json" \
    -H "OData-Version: 4.0" \
    -H "Cache-Control: no-cache" \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "\$select=name,serviceendpointid" \
    --data-urlencode "\$filter=(name eq '$WEBHOOK_NAME')" | jq -ren '[inputs] | add')

  if [[ $(jq '.statusCode' <<<$webhook_response) != '200' ]]; then
    echo >&2 "Error when requesting Service Endpoint with name $WEBHOOK_NAME"
    exit 1
  fi

  if [[ $(jq -r '.value | length' <<<$webhook_response) > 1 ]]; then
    echo >&2 "Service Endpoint name $WEBHOOK_NAME is ambiguous"
    exit 1
  fi

  if [[ $(jq -r '.value | length' <<<$webhook_response) == 1 ]]; then
    _webhook_id=$(jq -r '.value[0].serviceendpointid' <<<$webhook_response)
    echo $_webhook_id;
  fi
  # else result will be empty
}

function _create_webhook {
  local _function_url="$1"

  echo "Creating Webhook"
  local _contract=8 # Webhook
  local _authtype=5 # Http header
  local _webhook_create_request=$(jq -n '{
    "name": "'$WEBHOOK_NAME'",
    "contract": '$_contract',
    "authtype": '$_authtype',
    "url": "https://'$_function_url'/api/payment-service"
  }')
  local _webhook_create_response=$(echo $_webhook_create_request | curl -sL --request POST "$SERVICE_ENDPOINT_URL" \
    -w '{ "statusCode": %{http_code} }' \
    --header 'Accept: application/json' \
    --header 'Authorization: Bearer '$TOKEN \
    --header 'Content-Type: application/json' \
    --header "Cache-Control: no-cache" \
    -d @- | jq -ren '[inputs] | add')

  if [[ $(jq '.statusCode' <<<$_webhook_create_response) == '204' ]]; then
    echo "Succesfully created Webhook $WEBHOOK_NAME"
  else
    echo >&2 "$_webhook_create_response"
    exit 1
  fi
}

# GET AZURE FUNCTION INFO
echo "Checking Azure Function"
#_function_url=$(az functionapp show -n $FUNCTION_APP_NAME -g $RESOURCE_GROUP --query 'defaultHostName' -o tsv | tr -d '\r')
echo "Function URL is:$_function_url"

echo "Get or check Azure function Key"
_function_key=$(_get_or_set_function_key "$RESOURCE_GROUP" "$FUNCTION_APP_NAME")

### GET WEBHOOK DEFINITION
_webhook_id=$( _get_webhook_id)
if [[ -z $_webhook_id ]]; then
  _create_webhook "$_function_url"
  _webhook_id=$(_get_webhook_id)
fi


if [[ -z $_webhook_id ]]; then
  echo >&2 "ID if the webhook was not found at address:$SERVICE_ENDPOINT_URL"
  exit 1
fi

### SET WEBHOOK DEFINITION
echo "Configuring Webhook"
webhook_update_request=$(jq -n '{
  "authvalue": "<settings><setting name=\"x-functions-key\" value=\"'$_function_key'\" /></settings>",
  "url": "https://'$_function_url'/api/payment-service"
}')
webhook_update_response=$(echo $webhook_update_request | curl -sL --request PATCH "$SERVICE_ENDPOINT_URL($_webhook_id)" \
  -w '{ "statusCode": %{http_code} }' \
  --header 'If-Match: *' \
  --header 'Accept: application/json' \
  --header 'Authorization: Bearer '$TOKEN \
  --header 'Content-Type: application/json' \
  --header "Cache-Control: no-cache" \
  -d @- | jq -ren '[inputs] | add')

if [[ $(jq '.statusCode' <<<$webhook_update_response) == '204' ]]; then
  echo "Succesfully set Webhook address and key for webhook: $WEBHOOK_NAME"
else
  echo >&2 "$webhook_update_response"
  exit 1
fi