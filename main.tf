terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">=2.59.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">=2.3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">=1.13.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">=2.0.3"
    }
  }
  required_version = ">=0.14.8"
}

provider "azurerm" {
  features {}
}

provider "helm" {
  debug = true
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
  }
}

data "azurerm_subscription" "current" {
}

resource "random_string" "random" {
  length  = 12
  upper   = false
  number  = false
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = random_string.random.result
  location = "East US 2"
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "subnet1" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_subnet" "subnet2" {
  name                 = "subnet2"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.2.0/24"]
}

resource "azurerm_user_assigned_identity" "aks" {
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  name                = "uai-aks-${random_string.random.result}"
}

resource "azurerm_role_assignment" "subnet1_network_contributor" {
  scope                = azurerm_subnet.subnet1.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "subnet2_network_contributor" {
  scope                = azurerm_subnet.subnet2.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_kubernetes_cluster" "aks" {
  depends_on          = [ azurerm_role_assignment.subnet1_network_contributor,
                          azurerm_role_assignment.subnet2_network_contributor ]

  name                = random_string.random.result
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name

  kubernetes_version  = "1.19.9"
  dns_prefix          = random_string.random.result

  network_profile {
    network_plugin     = "kubenet"
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = "Standard_B2s"
    availability_zones           = [1,2,3]
    node_count                   = 2
    type                         = "VirtualMachineScaleSets"
    vnet_subnet_id               = azurerm_subnet.subnet1.id
  }

  identity {
    type                      = "UserAssigned"
    user_assigned_identity_id = azurerm_user_assigned_identity.aks.id
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "poo1" {
  kubernetes_cluster_id        = azurerm_kubernetes_cluster.aks.id
  name                         = "pool1"
  vm_size                      = "Standard_B2s"
  availability_zones           = [1,2,3]
  node_count                   = 2
  vnet_subnet_id               = azurerm_subnet.subnet1.id
}

resource "azurerm_kubernetes_cluster_node_pool" "poo2" {
  kubernetes_cluster_id        = azurerm_kubernetes_cluster.aks.id
  name                         = "pool2"
  vm_size                      = "Standard_B2s"
  availability_zones           = [1,2,3]
  node_count                   = 2
  vnet_subnet_id               = azurerm_subnet.subnet2.id
}

data "azurerm_resource_group" "node_rg" {
  name = azurerm_kubernetes_cluster.aks.node_resource_group
}

resource "azurerm_role_assignment" "k8s_virtual_machine_contributor" {
  scope                = data.azurerm_resource_group.node_rg.id
  role_definition_name = "Virtual Machine Contributor"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity.0.object_id
}

resource "azurerm_role_assignment" "k8s_managed_identity_operator" {
  scope                = data.azurerm_resource_group.node_rg.id
  role_definition_name = "Managed Identity Operator"
  principal_id         = azurerm_kubernetes_cluster.aks.kubelet_identity.0.object_id
}

resource "helm_release" "aad_pod_identity" {
  depends_on = [azurerm_role_assignment.k8s_virtual_machine_contributor, azurerm_role_assignment.k8s_managed_identity_operator]
  name       = "aad-pod-identity"
  namespace  = "kube-system"
  repository = "https://raw.githubusercontent.com/Azure/aad-pod-identity/master/charts"
  chart      = "aad-pod-identity"
  version    = "4.1.0"

  values = [<<-EOF
  rbac:
    allowAccessToSecrets: false
  installCRDs: true
  nmi:
    allowNetworkPluginKubenet: true
  EOF
  ]
}

output "aks_login" {
  value = "az aks get-credentials --name ${random_string.random.result} --resource-group ${azurerm_resource_group.main.name}"
}