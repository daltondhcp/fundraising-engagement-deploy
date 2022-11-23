param (
    [Parameter(Mandatory = $true)]
    [ValidatePattern('(\{|\()?[A-Za-z0-9]{4}([A-Za-z0-9]{4}\-?){4}[A-Za-z0-9]{12}(\}|\()?')]
    $SubscriptionId = '',
    [Parameter(Mandatory = $true)]
    $ResourceGroupName = '',
    [Parameter(Mandatory = $true)]
    $appSubnetName = '',
    [Parameter(Mandatory = $true)]
    $peSubnetName = '',
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "qa", "test", "uat", "prod")]
    $Environment = ''
)

begin {
    # Ensure correct Azure Context
    Set-AzContext -SubscriptionId $SubscriptionId -WarningAction Ignore
    # Ensure resource group exists
    $ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
    if (-not $ResourceGroup) {
        break
    }
    $virtualNetwork = Get-AzVirtualNetwork -ResourceGroupName $ResourceGroupName
    if ($virtualNetwork.count -gt 1) {
        throw "Multiple virtual networks in resource group, please provide $VirtualNetworkName parameter"
    }
    elseif (-not $virtualNetwork) {
        throw "No virtual network found in resource group"
    }
    # Get subnet and add delegation
    $virtualNetworkSubnets = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $virtualNetwork
    $peSubnetName,$appSubnetName | ForEach-Object -Process {
        if ($virtualNetworkSubnets.Name -notcontains $_) {
            throw "Subnet $_ not found in Virtual Network"
        }
    }
    $appSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $virtualNetwork -Name $appSubnetName
    $appSubnet = Add-AzDelegation -Name 'appSvcDelegation' -ServiceName 'Microsoft.Web/serverFarms' -Subnet $appSubnet
    Write-Output "Adding subnet delegation for app services"
    $null = Set-AzVirtualNetwork -VirtualNetwork $virtualNetwork
    $namingPrefix = (Get-AzResource -ResourceGroupName $ResourceGroupName -TagName displayName -TagValue 'Payment Service').Name.Split('-')[0]
    if (-not $namingPrefix) {
        throw "Couldn't find naming prefix, verify that solution is actually deployed in resource group"
    }
}
process {
    # region create private dns zones
    $privateDNSZonesToCreate = @('privatelink.database.windows.net',
        'privatelink.vaultcore.azure.net',
        'privatelink.azurewebsites.net'
        #'privatelink.blob.core.windows.net'
    )

    foreach ($zone in $privateDNSZonesToCreate) {
        # Create zone
        try {
            Write-Output "Creating Private DNS Zone $zone"
            $createdZone = New-AzPrivateDnsZone -Name $zone -ResourceGroupName $ResourceGroupName
            $link = New-AzPrivateDnsVirtualNetworkLink -ZoneName $zone -ResourceGroupName $ResourceGroupName -Name "link-$($virtualNetwork.Name)" -VirtualNetworkId $virtualNetwork.Id
        }
        catch {
            Write-Warning $_
        }
    }
    # endregion create private dns zones

    # region integrate app services/functions with vnet for outbound connectivity

    Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType Microsoft.Web/sites | ForEach-Object -Process {
        Write-Output "Configuring outbound VNet integration for $($_.Name)"
        $app = Get-AzResource -ResourceId $_.ResourceId
        $app.Properties.virtualNetworkSubnetId = ($virtualNetworkSubnets | Where-Object { $_.name -eq $appSubnetName }).Id
        $app | Set-AzResource -Force | Out-Null
        Start-Sleep -Seconds 10
        Write-Output "Restarting $($_.Name)"
        $null = Restart-AzWebApp -ResourceGroupName $ResourceGroupName -Name $_.Name
    }
    # endregion integrate app services/functions with vnet for outbound connectivity

    # region create private endpoints
    $endpointsToCreate = @{
        'privatelink.vaultcore.azure.net'  = 'Microsoft.KeyVault/vaults', 'vault'
        'privatelink.database.windows.net' = 'Microsoft.Sql/servers', 'sqlServer'
        #'privatelink.blob.core.windows.net' = 'Microsoft.Storage/storageAccounts', 'blob'
        'privatelink.azurewebsites.net'    = 'Microsoft.Web/sites', 'sites'
    }
    foreach ($service in $endpointsToCreate.Keys) {
        try {
            $dnsConfig = New-AzPrivateDnsZoneConfig -Name $service -PrivateDnsZoneId ($dnsConfig = Get-AzResource -Name $service -ResourceGroupName $ResourceGroupName).ResourceId
            $resources = Get-AzResource -ResourceType $endpointsToCreate[$service][0] -ResourceGroupName $ResourceGroupName

            foreach ($resource in $resources) {
                Write-Output "Create private endpoint for $($resource.Name)"
                $peSubnet = $virtualNetworkSubnets | Where-Object { $_.Name -eq $peSubnetName }
                $peConnection = New-AzPrivateLinkServiceConnection -Name "$($resource.Name)-peconn" -PrivateLinkServiceId $resource.ResourceId -GroupId $endpointsToCreate[$service][1]
                $privateEndpoint = New-AzPrivateEndpoint -Name "$($resource.Name)-pe"-ResourceGroupName $ResourceGroupName -Location $virtualNetwork.Location -Subnet $peSubnet -PrivateLinkServiceConnection $peConnection -Force

                $dnsZoneGroup = New-AzPrivateDnsZoneGroup -Name "$($resource.Name)-zoneGroup" -ResourceGroupName $resourcegroupname -PrivateEndpointName $privateEndpoint.Name -PrivateDnsZoneConfig $dnsConfig -Force
            }
        }
        catch {
            Write-Warning $_
        }

    }

    # region Create Azure Front Door
    Write-Output "Creating Azure Front Door"
    $fdProfile = New-AzFrontDoorCdnProfile -ResourceGroupName $ResourceGroupName -Name "$($namingPrefix)-afd-$($Environment)" -SkuName Premium_AzureFrontDoor -Location Global

    # Create default origin probe settings
    $HealthProbeSetting = New-AzFrontDoorCdnOriginGroupHealthProbeSettingObject -ProbeIntervalInSecond 60 -ProbePath "/" -ProbeRequestType GET -ProbeProtocol Https
    $LoadBalancingSetting = New-AzFrontDoorCdnOriginGroupLoadBalancingSettingObject -AdditionalLatencyInMillisecond 50 -SampleSize 4 -SuccessfulSamplesRequired 3

    # Create endpoints for Payment and Background Service
    'payment', 'background' | ForEach-Object -Process {
        $serviceName = $_
        Write-Output "Creating Azure Front Door Origin for $serviceName"
        $App = Get-AzWebApp -ResourceGroupName $ResourceGroupName | Where-Object { $_.Name -like "*$serviceName*" }
        $AppPe = Get-AzResource -ResourceGroupName $resourcegroupname -ResourceType "Microsoft.Network/privateEndpoints" | Where-Object { $_.Name -like "*$serviceName*" }
        $Endpoint = New-AzFrontDoorCdnEndpoint -EndpointName "$($namingPrefix)-$serviceName-$($Environment)" -ProfileName "$($namingPrefix)-afd-$($Environment)" -ResourceGroupName $ResourceGroupName -Location Global
        $Originpool = New-AzFrontDoorCdnOriginGroup -OriginGroupName "$($namingPrefix)-$serviceName-origin-$($Environment)" -ProfileName "$($namingPrefix)-afd-$($Environment)" -ResourceGroupName $ResourceGroupName -HealthProbeSetting $HealthProbeSetting -LoadBalancingSetting $LoadBalancingSetting
        $Origin1 = New-AzFrontDoorCdnOrigin -OriginGroupName $Originpool.Name -OriginName "$($namingPrefix)-$serviceName-origin-$($Environment)" `
            -ProfileName "$($namingPrefix)-afd-$($Environment)" `
            -ResourceGroupName $ResourceGroupName `
            -HostName $App.DefaultHostName `
            -OriginHostHeader $App.DefaultHostName `
            -HttpPort 80 `
            -HttpsPort 443 `
            -Priority 1 `
            -Weight 1000 `
            -PrivateLinkId $App.Id -SharedPrivateLinkResourceRequestMessage "$serviceName origin approval" -SharedPrivateLinkResourcePrivateLinkLocation $AppPe.Location -SharedPrivateLinkResourceGroupId 'sites'

        # Approve private endpoint connection to $serviceName App
        $peApproval = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $App.Id | Where-Object { $_.ProvisioningState -eq "Pending" }
        $null = Approve-AzPrivateEndpointConnection -ResourceId $peApproval.Id
        $null = New-AzFrontDoorCdnRoute `
            -EndpointName $Endpoint.Name `
            -Name "$($namingPrefix)-$serviceName-route-$($Environment)" `
            -ProfileName "$($namingPrefix)-afd-$($Environment)" `
            -ResourceGroupName $ResourceGroupName `
            -ForwardingProtocol 'HttpsOnly' `
            -HttpsRedirect Enabled `
            -LinkToDefaultDomain Enabled `
            -OriginGroupId $Originpool.Id `
            -SupportedProtocol Https
    }

    #endregion create Azure front door

    # Lock down keyvaults to only allow usage over the private endpoints
    Write-Output "Locking down Key Vault Firewalls"
    Get-AzKeyVault -ResourceGroupName $ResourceGroupName | ForEach-Object -Process {
        $null = Update-AzKeyVault -ResourceGroupName $ResourceGroupName -VaultName $_.VaultName -PublicNetworkAccess Disabled
    }

    Write-Output "----- Front door endpoints to put into Dynamics -----"
    Get-AzFrontDoorCdnEndpoint -ProfileName "$($namingPrefix)-afd-$($Environment)" -ResourceGroupName $resourceGroupName | ForEach-Object -Process {
        [PSCustomObject]@{
            EndpointName = $_.Name
            HostName     = $_.HostName
        }
    }

}

