# Azure Arc-enabled Data Services demo - generic, direct and indirect, MI GP and BC 

## Set variables 
$subscription = "Azure Data Demos"
$resourceGroup = "jeschult-portalupgrade"
$location = "southeastasia"
$aks = "aks-portalupgrade"
$nodeVMSize = "Standard_D8s_v3"
$nodeCount = 3
$connectedCluster = "aks-arc-portalupgrade"
$k8sNamespace = "arc-ds" # Do not use azure-arc
$dataController = "dc-upgrade"
$instance = "mi-cli"

## Set env variables which will be used in 'az arcdata dc create' as the data controller (for now), Kibana, and Grafana admin credentials
$admincredentials = New-Object System.Management.Automation.PSCredential ('arcadmin', (ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText))

$ENV:AZDATA_LOGSUI_USERNAME="$($admincredentials.UserName)"
$ENV:AZDATA_LOGSUI_PASSWORD="$($admincredentials.GetNetworkCredential().Password)"
$ENV:AZDATA_METRICSUI_USERNAME="$($admincredentials.UserName)"
$ENV:AZDATA_METRICSUI_PASSWORD="$($admincredentials.GetNetworkCredential().Password)"

## Login and set sub
az login

az account set --subscription $subscription
az account show -s $subscription
### Copy sub ID 
$subscriptionID = "182c901a-129a-4f5d-86e4-cc6b294590a2"

## Create resource group 
az group create --location $location --name $resourceGroup 

## Set context 
az aks get-credentials --resource-group $resourceGroup --name $aks

## View nodes
kubectl get nodes

## View namespaces
kubectl get namespaces

##################################################################################################################

## Create data controller 

### Indirect mode 
### Depends on K8s distribution 
#### az arcdata dc create --profile-name <storage profile - depends on distro> --k8s-namespace <k8s namespace> --use-k8s --name <data controller name> --subscription <sub id> --resource-group <rg name> --location <location> --connectivity-mode indirect

#### need to determine our storage profile 
az arcdata dc create --profile-name azure-arc-aks-premium-storage --k8s-namespace $k8sNamespace --name $dataController --subscription $subscriptionID --resource-group $resourceGroup --location $location --connectivity-mode indirect --use-k8s 

#### Monitor 
kubectl get namespaces

#### Get pods 
kubectl get pods --namespace $k8sNamespace -o wide

#### Get services 
kubectl get services --namespace $k8sNamespace

#### View status 
kubectl get datacontroller/$dataController --namespace $k8sNamespace

#### View logs for data controller - update pod name here
kubectl --namespace $k8sNamespace logs control-zt7kf   controller

#######################################################################################################################

## Create Managed Instance 

$gpinstance = "mi-gp"
$bcinstance = "mi-bc"

### General Purpose 
#### az sql mi-arc create --name $gpinstance --k8s-namespace $k8sNamespace --tier GeneralPurpose --dev --cores-limit 4 --cores-request 2 --memory-limit 8Gi --memory-request 4Gi --use-k8s
az sql mi-arc create --name $gpinstance --k8s-namespace $k8sNamespace --tier GeneralPurpose --dev --use-k8s

### Business Critical 
#### az sql mi-arc create --name $bcinstance --k8s-namespace $k8sNamespace --tier BusinessCritical --replicas <1, 2, 3> --dev --volume-size-data 20Gi --volume-size-logs 5Gi --volume-size-backups 20Gi --use-k8s
az sql mi-arc create --name $bcinstance --k8s-namespace $k8sNamespace --tier BusinessCritical --replicas <X> --dev --use-k8s

az sql mi-arc create --name $bcinstance --k8s-namespace $k8sNamespace --tier BusinessCritical --dev --replicas 3 --cores-limit 8 --cores-request 2 --memory-limit 32Gi --memory-request 8Gi --volume-size-data 20Gi --volume-size-logs 5Gi --volume-size-backups 20Gi --collation Turkish_CI_AS --agent-enabled true --use-k8s

#### Monitor 

#### Get pods 
kubectl get pods --namespace $k8sNamespace -w

#### Get services 
kubectl get services --namespace $k8sNamespace

## Check it out! Get endpoint to connect. 
az sql mi-arc list --k8s-namespace $k8sNamespace --use-k8s

#### Go to ADS - connect to the MI. Also connect data controller to show Kibana and Grafana. 

#######################################################################################################################

## Scale 
az sql mi-arc edit --name $gpinstance --cores-limit 8 --cores-request 4 --memory-limit 16Gi --memory-request 8Gi --k8s-namespace $k8sNamespace --use-k8s

#######################################################################################################################

## Restore AdvWorks 
kubectl get pods --namespace $k8sNamespace
$pod = ""
kubectl exec $pod -n $k8sNamespace -c arc-sqlmi -- wget https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2019.bak -O /var/opt/mssql/data/AdventureWorks2019.bak
kubectl exec $pod -n $k8sNamespace -c arc-sqlmi -- /opt/mssql-tools/bin/sqlcmd -S localhost -U $admincredentials.UserName -P $admincredentials.Password -Q "RESTORE DATABASE AdventureWorks2019 FROM  DISK = N'/var/opt/mssql/data/AdventureWorks2019.bak' WITH MOVE 'AdventureWorks2017' TO '/var/opt/mssql/data/AdventureWorks2019.mdf', MOVE 'AdventureWorks2017_Log' TO '/var/opt/mssql/data/AdventureWorks2019_Log.ldf'"

## Open ADS to connect and query 

#######################################################################################################################

## Point-in-time restore 

### Check retention setting
az sql mi-arc show --name <SQL instance name> --k8s-namespace <SQL MI namespace> --use-k8s
#Example
az sql mi-arc show --name sqlmi --k8s-namespace arc --use-k8s

### Restore 
az sql midb-arc restore --managed-instance <SQL managed instance> --name <source DB name> --dest-name <Name for new db> --k8s-namespace <namespace of managed instance> --time "YYYY-MM-DDTHH:MM:SSZ" --use-k8s
#Example
az sql midb-arc restore --managed-instance sqlmi1 --name Testdb1 --dest-name mynewdb --k8s-namespace arc --time "2021-10-29T01:42:14.00Z" --use-k8s

### YAML - Ben 

#######################################################################################################################

## MI HA 

### General purpose - HA is provided by K8s 
#### Verify HA 
kubectl get pods --namespace $k8sNamespace
$pod = ""
### Delete primary 
kubectl delete pod $pod --namespace $k8sNamespace
kubectl get pods --namespace $k8sNamespace

### Business criticial - HA is an AG
#### Get secondary endpoint 
az sql mi-arc list --k8s-namespace $k8sNamespace --use-k8s  
az sql mi-arc show --name $bcinstance --k8s-namespace $k8sNamespace --use-k8s # This shows the info about the instance 
####  "secondaryEndpoint": "52.150.52.94,1433"

####  I can connect and view in ADS; database is read-only. 
####  I can connect and view in SSMS, with the added benefit of seeing the AG info there. 

### Verify HA 
####  View pods 
kubectl get pods --namespace $k8sNamespace 
$pod = ""

### Determine which is primary 
$Env:sqlpod="mi-bc-1-0"
$Env:namespace=$k8sNamespace
$Env:sqlname=$Env:sqlpod.Substring(0,$Env:sqlpod.length-2)

kubectl get pod $Env:sqlpod -n $Env:namespace -o jsonpath="{.metadata.labels.role\.ag\.mssql\.microsoft\.com/$Env:sqlname-$Env:sqlname}"

####  Delete primary
kubectl delete pod $pod --namespace $k8sNamespace 
kubectl get pods --namespace $k8sNamespace 


## Upload usage data to Azure - wait 24 hours after creation 

az arcdata dc export --type usage --path usage.json --k8s-namespace $k8sNamespace --use-k8s

az arcdata dc upload --path usage.json



## Clean up resources 

### Delete MI 
az sql mi-arc delete --name $instance --k8s-namespace $k8sNamespace --use-k8s

### Delete data controller 
az arcdata dc delete --name $dataController --k8s-namespace $k8sNamespace


kubectl get nodes
kubectl get namespaces
kubectl get pods --namespace $k8sNamespace
kubectl get services --namespace $k8sNamespace
