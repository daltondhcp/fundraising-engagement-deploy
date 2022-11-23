# Secure Fundraising and Engagement deployments

Fundraising and Engagement involves processing potentially sensitive data subject to standards such as [PCI DSS](https://learn.microsoft.com/en-us/azure/compliance/offerings/offering-pci-dss).
This means there are strict security requirements in areas like network flows that need to be considered when building the solution.

> **Note:** Microsoft doesn't provide guidance on compliance review of the solution nor the validation of solution for PCI DSS.

The purpose of this article is to describe the required network patterns as well as how to further enhance network security in Fundraising and Engagement deployments by enabling private connectivity.
For general information about Fundraising and Engagement, refer to [Overview of deploying Fundraising and Engagement](https://learn.microsoft.com/en-us/dynamics365/industry/nonprofit/fundraising-engagement-deploy-overview) at Microsoft Learn.

## Solution overview – network flows

An overview of the individual Azure Components created for Fundraising and Engagement can be found [here](https://learn.microsoft.com/en-us/dynamics365/industry/nonprofit/fundraising-engagement-deploy-overview#overview-of-azure-components-used-by-fundraising--engagement).

In terms of inbound network flows, the Background Service/Payment Services function needs to be accessed directly from Dynamics 365/Power Platform. As it is currently not possible to connect from Power Platform to a private virtual network, the functions need to be exposed with public endpoints. The backend components (Key Vault, Storage, SQL database) only need to be accessed through the functions/Web Job and require no public endpoints.
![Import-Git](./media/overview.png)

## Post-deployment configuration

For a semi-automated deployment method, follow the [Post-deployment configuration using PowerShell script]() instructions.
If you prefer doing it manually using the portal, follow the instructions for [manual configuration]().

After reconfiguring/securing the Azure resources, you need to reconfigure the Dynamics background service URI as well as the webhook for the payment service.

> **Note:** the following instructions assume that you have already deployed Fundraising and Engagement using the installer or manual instructions found at [Microsoft Learn](https://learn.microsoft.com/en-us/dynamics365/industry/nonprofit/fundraising-engagement-deploy-overview).

> If upgrading an existing installation, you may need to run/validate the post-deployment script/configuration again to ensure that everything is properly locked down.

### Prerequisites

Since all services will be attached to a virtual network, you need to create one virtual network (VNet) per environment tier (dev/test/prod) in the same region as the Azure components.

The Virtual Network size need to be at least /26 with the following subnets in place. Naming below is just an example. In case you intend to peer the network, ensure address space alignment.

|Subnet Name | Minimum Subnet Size | Purpose |
| --- | --- | --- |
| private-endpoints | /28 | Private endpoints will be attached to this subnet|
| app-services | /28 | [App services VNet integration](https://learn.microsoft.com/en-us/azure/app-service/overview-vnet-integration#subnet-requirements)|

![VNet Creation](./media/vnet_creation.png)

### Post-deployment Azure configuration using PowerShell script

The PowerShell script will configure/create the following components. Naming will be based on the prefix used when deploying the F&E solution.

* Validate Inputs
* Private DNS Zones for App Services/Functions, Key Vaults and SQL Server. The zones will be created in the solution resource group and linked to the VNet.
    * privatelink.database.windows.net
    * privatelink.vaultcore.azure.net
    * privatelink.azurewebsites.net
    > Note: *If you have centralized private DNS in your Azure Environment, you may need to change/remove this part from the script.*

    <https://learn.microsoft.com/en-us/azure/dns/private-dns-getstarted-portal>
    <https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns>
* Private Endpoints for Key Vaults, Functions and SQL Database
* Outbound VNet Integration of App Services/Functions
* Deployment of Azure Front Door
    * Create endpoint for Payment and Background service
    * Create origin for Payment and Background service
* Disable Azure Key Vault public access
--- 
#### Execute deployment 
1. In Azure Cloud Shell, switch to PowerShell and run below command to download configuration script:
    ```bash
    wget https://raw.githubusercontent.com/daltondhcp/fundraising-engagement-deploy/instructions/scripts/securePostConfig.ps1
    ```