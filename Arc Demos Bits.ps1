# Let's check out our environment
# We run a few VMs on Hyper-V
Get-VM

# Which clusters do we have?
kubectl config view -o jsonpath='{range .contexts[*]}{.name}{''\n''}{end}'

# Those are backed by our VMs and we can switch between them
kubectl config use-context kubeadm-small
kubectl get nodes

# Let's stay with our "big" cluster for now
kubectl config use-context kubeadm-big
kubectl get nodes

# A big time factor is image download - so we've pre-pulled them
kubectl get nodes (kubectl get nodes -o jsonpath="{.items[1].metadata.name}" ) -o jsonpath="{range .status.images[*]}{.names[1]}{'\n'}{end}" | grep arcdata 

# It's almost 40 GB (for current and previous version) - PER WORKER!
$TotalSize = 0
((kubectl get nodes  (kubectl get nodes -o jsonpath="{.items[1].metadata.name}" )  -o jsonpath="{range .status.images[*]}{.sizeBytes}{'\t'}{.names[1]}{'\n'}{end}" | grep arcdata).Split("`t") | grep -v mcr).Split("`n") | Foreach { $TotalSize += $_}
[Math]::Round(($TotalSize/1024/1024),2)


# OK, let's login to Azure
$subscriptionName = "Azure Data Demos"
az login --only-show-errors -o table --query Dummy
az account set -s $SubscriptionName

# Set some variables
$RG="ArcDataRG"
$Region="eastus"
$Subscription=(az account show --query id -o tsv)
$k8sNamespace="arc"

# And credentials
$admincredentials = New-Object System.Management.Automation.PSCredential ('arcadmin', (ConvertTo-SecureString -String 'P@ssw0rd' -AsPlainText -Force))
$ENV:AZDATA_USERNAME="$($admincredentials.UserName)"
$ENV:AZDATA_PASSWORD="$($admincredentials.GetNetworkCredential().Password)"
$ENV:SQLCMDPASSWORD="$($admincredentials.GetNetworkCredential().Password)"
$ENV:ACCEPT_EULA='yes'
$ENV:SQLCMDPASSWORD=$ENV:AZDATA_PASSWORD

# Create an RG
az group create -l $Region -n $RG

# We could deploy direct from Portal (requires arc connected k8s!)
Start-Process https://portal.azure.com/#create/Microsoft.DataController

# Let's stick to indirect for today
# Deploy DC from Command Line
az arcdata dc create --connectivity-mode Indirect --name arc-dc-kubeadm --k8s-namespace $k8sNamespace `
    --subscription $Subscription `
    -g $RG -l eastus --storage-class local-storage `
    --profile-name azure-arc-kubeadm --infrastructure onpremises --use-k8s

# Check ADS while running

# This created a new Namespace for us
kubectl get namespace

# Check the pods that got created
kubectl get pods -n $k8sNamespace 

# Check Status of the DC
az arcdata dc status show --k8s-namespace arc --use-k8s

# View logs for data controller
kubectl get pods -n $k8sNamespace -l app=controller 
$ControlPod=(kubectl get pods -n $k8sNamespace -l app=controller -o jsonpath='{ .items[0].metadata.name }')
kubectl --namespace $k8sNamespace logs $ControlPod controller

# Add Controller in ADS

# Create MIs
$gpinstance = "mi-gp"
$bcinstance = "mi-bc"

# General Purpose 
az sql mi-arc create -n $gpinstance --k8s-namespace $k8sNamespace  --use-k8s `
--storage-class-backups local-storage `
--storage-class-data local-storage `
--storage-class-datalogs local-storage `
--storage-class-logs local-storage `
--cores-limit 4 --cores-request 2 `
--memory-limit 8Gi --memory-request 4Gi --dev `
--tier GeneralPurpose 

# Everything in Arc-enabled Data Services is also Kubernetes native!
kubectl edit sqlmi $gpinstance -n $k8sNamespace

# Business Critical 
az sql mi-arc create --name $bcinstance --k8s-namespace $k8sNamespace --tier BusinessCritical --dev `
                    --replicas 3 --cores-limit 8 --cores-request 2 --memory-limit 32Gi --memory-request 8Gi `
                    --volume-size-data 20Gi --volume-size-logs 5Gi --volume-size-backups 20Gi `
                    --collation Turkish_CI_AS --agent-enabled true --use-k8s

# We now have 2 MIs!
az sql mi-arc list --k8s-namespace $k8sNamespace  --use-k8s -o table

# We can scale our Instances
az sql mi-arc update --name $gpinstance --cores-limit 8 --cores-request 4 `
                --memory-limit 16Gi --memory-request 8Gi --k8s-namespace $k8sNamespace --use-k8s

# Let's restore AdventureWorks to our GP Instance
copy e:\Backup\AdventureWorks2019.bak .
kubectl cp AdventureWorks2019.bak mi-gp-0:/var/opt/mssql/data/AdventureWorks2019.bak -n $k8sNamespace -c arc-sqlmi
Remove-Item AdventureWorks2019.bak

# We can see the file
kubectl exec mi-gp-0 -n $k8sNamespace -c arc-sqlmi -- ls -l /var/opt/mssql/data/AdventureWorks2019.bak

# We could restore in the Pod - or using the Instance's Endpoint
kubectl get sqlmi $gpinstance -n $k8sNamespace
$SQLEndpoint=(kubectl get sqlmi $gpinstance -n $k8sNamespace -o jsonpath='{ .status.primaryEndpoint }')

# No AdventureWorks
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME  -Q "SELECT Name FROM sys.Databases"

# Restore
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME  -Q "RESTORE DATABASE AdventureWorks2019 FROM  DISK = N'/var/opt/mssql/data/AdventureWorks2019.bak' WITH MOVE 'AdventureWorks2017' TO '/var/opt/mssql/data/AdventureWorks2019.mdf', MOVE 'AdventureWorks2017_Log' TO '/var/opt/mssql/data/AdventureWorks2019_Log.ldf'"

# Tadaaaaaa
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME  -Q "SELECT Name FROM sys.Databases"

# We can add, managed, monitor and query those from ADS!


# MI HA 

# General purpose - HA is provided by k8s 
# Verify HA 
kubectl get pods --namespace $k8sNamespace -l app.kubernetes.io/instance=mi-gp
# Delete primary 
kubectl delete pod mi-gp-0 --namespace $k8sNamespace
kubectl get pods --namespace $k8sNamespace -l app.kubernetes.io/instance=mi-gp

# Business criticial - HA is an AG
# Get secondary endpoint 
az sql mi-arc list --k8s-namespace $k8sNamespace --use-k8s 
az sql mi-arc show --name $bcinstance --k8s-namespace $k8sNamespace --use-k8s 

#  I can connect and view in ADS; database is read-only. 
#  I can connect and view in SSMS, with the added benefit of seeing the AG info there. 

# Determine which is primary 
for ($i=0; $i -le 2; $i++){
kubectl get pod ("$($bcinstance)-$i") -n $k8sNamespace -o jsonpath="{.metadata.labels}" | ConvertFrom-Json | grep -v controller | grep -v app | grep -v arc-resource | grep -v -e '^$'
}

# Delete a Pod
kubectl delete pod mi-bc-0 -n $k8sNamespace
kubectl get pods -n $k8sNamespace -l app.kubernetes.io/instance=mi-bc

# Determine which is primary now
for ($i=0; $i -le 2; $i++){
    kubectl get pod ("$($bcinstance)-$i") -n $k8sNamespace -o jsonpath="{.metadata.labels}" | ConvertFrom-Json | grep -v controller | grep -v app | grep -v arc-resource | grep -v -e '^$'
    }

# Updates
kubectl config use-context kubeadm-small

# Our DC is up to date
az arcdata dc list-upgrades -k $k8sNamespace

# But our MI is "old"
$SQLEndpoint=(kubectl get sqlmi mi-1 -n $k8sNamespace -o jsonpath='{ .status.primaryEndpoint }')
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME -Q "SELECT @@version"

# Let's update
az sql mi-arc upgrade -n mi-1 --use-k8s --k8s-namespace $k8sNamespace

# Wait for upgraded Pod
kubectl get pods mi-1-0 -n $k8sNamespace -w

# Check the log
kubectl logs mi-1-0 -n $k8sNamespace -c arc-sqlmi 

# And our MI is updated
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME -Q "SELECT @@version"

# Backup / Restore
# We have a fancy Database with PIT data
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME -Q "SELECT TOP 5 * FROM BackupDemo.dbo.Timestamps order by ts desc"

$PointInTime=(get-date).AddMinutes(-90).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.ffZ")

az sql midb-arc restore --managed-instance mi-1 --name BackupDemo --dest-name RestoreDemo --k8s-namespace arc --time $PointInTime --use-k8s
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME -Q "SELECT TOP 5 * FROM BackupDemo.dbo.Timestamps order by ts desc"
sqlcmd -S $SQLEndpoint -U $ENV:AZDATA_USERNAME -Q "SELECT TOP 5 * FROM RestoreDemo.dbo.Timestamps order by ts desc"

kubectl get SqlManagedInstanceRestoreTask -n $k8sNamespace


# Upload to Azure
kubectl config use-context kubeadm-big

# Connect to Azure Monitor:
# Create Service Principal
$SP=(az ad sp create-for-rbac --name http://ArcDemoSP --role Contributor| ConvertFrom-Json)

# Add Role
az role assignment create --assignee $SP.appId --role "Monitoring Metrics Publisher" --scope subscriptions/$Subscription

# Create Log Analytics Workspace and retrieve it's credentials
$LAWS=(az monitor log-analytics workspace create -g $RG -n ArcLAWS| ConvertFrom-Json)
$LAWSKEYS=(az monitor log-analytics workspace get-shared-keys -g $RG -n ArcLAWS | ConvertFrom-Json)

# For Direct connected mode:
# Connect the Kubernetes Cluster to Azure (Arc-enabled Kubernetes)
# Enable the Cluster for Custom Locations
# Deploy Custom Location and DC from Portal

# In indirect connected mode:

# Store keys
$Env:SPN_AUTHORITY='https://login.microsoftonline.com'
$Env:WORKSPACE_ID=$LAWS.customerId
$Env:WORKSPACE_SHARED_KEY=$LAWSKEYS.primarySharedKey
$Env:SPN_CLIENT_ID=$SP.appId
$Env:SPN_CLIENT_SECRET=$SP.password
$Env:SPN_TENANT_ID=$SP.tenant
$Env:AZDATA_VERIFY_SSL='no'

# Export our logs and metrics (and usage)
# az arcdata dc export -t usage --path usage.json -k $k8sNamespace --force --use-k8s
az arcdata dc export -t metrics --path metrics.json -k $k8sNamespace --force --use-k8s
az arcdata dc export -t logs --path logs.json -k $k8sNamespace --force --use-k8s

# Upload the data to Azure - this should be a scheduled job.
# az arcdata dc upload --path usage.json
az arcdata dc upload --path metrics.json
az arcdata dc upload --path logs.json

remove-item *.json

# Check in portal
Start-Process ("https://portal.azure.com/#@"+ (az account show --query tenantId -o tsv) + "/resource" + (az group show -n $RG --query id -o tsv))

# Cleanup when done
kubectl delete namespace arc
az group delete -g $RG --yes
az ad sp delete --id $SP.appId
az logout