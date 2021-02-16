<#
.SYNOPSIS
    The script allows you to get reduce the size of the OS disk of a Windows VM running in Azure.

.DESCRIPTION
    The disk being resized needs to be shrunk inside the guest OS to a size equal or smaller than the new size.
    You are better off shrinking to a smaller size than the $DiskSizeGB parameter and expanding the disk after resize is complete.

.PARAMETER DiskName
    Specifies the name of the OS disk of the VM

.PARAMETER VMName
    Specifies the name of the VM.

.PARAMETER DisksizeGB
    Specifies the size of the new disk in GB.

.PARAMETER AzSubscription
    Specifies the name of the Azure subscription containing the VM.

.EXAMPLE
    shrink-azosdisk -DiskName "simplevm_OsDisk_1_123456789" -VMName "simplevm" -DiskSizeGB 32 -AzSubscription "Sub1"

    This will shrink the OS disk of a VM named simplevm in subscription sub1 to 32GB


.NOTES
    NAME:    Shrink-AZOSdisk.ps1
    AUTHOR:    Robert Shepherd
    DATE:    2/16/2021
    Github:    github.com/shepsop
    Adapted from:  https://github.com/jrudlin/Azure/blob/master/General/Shrink-AzDisk.ps1

    VERSION HISTORY:
    1.0 2/16/2021
        Initial Version
#>
Param(
    [Parameter(
        Mandatory=$true)]
        [string] $DiskName,
    [Parameter(
        Mandatory=$true)]
        [string] $VMName,
    [Parameter(
        Mandatory=$true)]
        [int] $DiskSizeGB,
    [Parameter(
        Mandatory=$true)]
        [string] $AzSubscription
    )

# Provide your Azure admin credentials
Connect-AzAccount

#Provide the subscription Id of the subscription where snapshot is created
Select-AzSubscription -Subscription $AzSubscription

# VM to resize disk of
$VM = Get-AzVm | Where-Object name -eq $VMName

#Provide the name of your resource group where snapshot is created
$resourceGroupName = $VM.ResourceGroupName

# Get Disk from ID
$Disk = Get-AzDisk -ResourceGroupName $ResourceGroupname -DiskName $DiskName

# Get VM/Disk generation from Disk
$HyperVGen = $Disk.HyperVGeneration

# stop VM if it is not stopped
$status = (Get-AzVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status).Statuses[1].DisplayStatus

if ($status -ne "VM deallocated"){
    Stop-AzVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -confirm:$false -force}

while(($state = Get-AzVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status).Statuses[1].DisplayStatus -ne "VM deallocated") { $state; Start-Sleep -Seconds 20 }
$state

# Get SAS URI for the Managed disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName -Access 'Read' -DurationInSecond 600000;

#Provide storage account name where you want to copy the snapshot - the script will create a new one temporarily
$storageAccountName = "shrink" + [system.guid]::NewGuid().tostring().replace('-','').substring(1,18)

#Name of the storage container where the downloaded snapshot will be stored
$storageContainerName = $storageAccountName

#Provide the name of the VHD file to which snapshot will be copied.
$destinationVHDFileName = "$($VM.StorageProfile.OsDisk.Name).vhd"

#Create the context for the storage account which will be used to copy snapshot to the storage account
$StorageAccount = New-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName -SkuName Standard_LRS -Location $VM.Location
$destinationContext = $StorageAccount.Context
$container = New-AzStorageContainer -Name $storageContainerName -Permission Off -Context $destinationContext

#Copy the snapshot to the storage account and wait for it to complete
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $destinationVHDFileName -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $destinationVHDFileName -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $DiskName

# Emtpy disk to get footer from
$emptydiskforfootername = "$($VM.StorageProfile.OsDisk.Name)-empty.vhd"

# Empty disk URI
#$EmptyDiskURI = $container.CloudBlobContainer.Uri.AbsoluteUri + "/" + $emptydiskforfooter

$diskConfig = New-AzDiskConfig `
    -Location $VM.Location `
    -CreateOption Empty `
    -DiskSizeGB $DiskSizeGB `
    -HyperVGeneration $HyperVGen

$dataDisk = New-AzDisk `
    -ResourceGroupName $resourceGroupName `
    -DiskName $emptydiskforfootername `
    -Disk $diskConfig

$VM = Add-AzVMDataDisk `
    -VM $VM `
    -Name $emptydiskforfootername `
    -CreateOption Attach `
    -ManagedDiskId $dataDisk.Id `
    -Lun 63

Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM | Stop-AzVM -Force

while(($state = Get-AzVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status).Statuses[1].DisplayStatus -ne "VM deallocated") { $state; Start-Sleep -Seconds 20 }
$state

# Get SAS token for the empty disk
$SAS = Grant-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Access 'Read' -DurationInSecond 600000;

# Copy the empty disk to blob storage
Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $emptydiskforfootername -DestContext $destinationContext
while(($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $emptydiskforfootername -Container $storageContainerName).Status -ne "Success") { $state; Start-Sleep -Seconds 20 }
$state

# Revoke SAS token
Revoke-AzDiskAccess -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername

# Remove temp empty disk
Remove-AzVMDataDisk -VM $VM -DataDiskNames $emptydiskforfootername
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

# Delete temp disk
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $emptydiskforfootername -Force;

# Get the blobs
$emptyDiskblob = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $emptydiskforfootername
$osdisk = Get-AzStorageBlob -Context $destinationContext -Container $storageContainerName -Blob $destinationVHDFileName

$footer = New-Object -TypeName byte[] -ArgumentList 512
write-output "Get footer of empty disk"

$downloaded = $emptyDiskblob.ICloudBlob.DownloadRangeToByteArray($footer, 0, $emptyDiskblob.Length - 512, 512)

$osDisk.ICloudBlob.Resize($emptyDiskblob.Length)
$footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (,$footer)
write-output "Write footer of empty disk to OSDisk"
$osDisk.ICloudBlob.WritePages($footerStream, $emptyDiskblob.Length - 512)

Write-Output -InputObject "Removing empty disk blobs"
$emptyDiskblob | Remove-AzStorageBlob -Force

#Provide the name of the Managed Disk
$NewDiskName = "$DiskName" + "-new"

#Create the new disk with the same SKU as the current one
$accountType = $Disk.Sku.Name

# Get the new disk URI
$vhdUri = $osdisk.ICloudBlob.Uri.AbsoluteUri

# Specify the disk options
$diskConfig = New-AzDiskConfig -AccountType $accountType -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption Import -StorageAccountId $StorageAccount.Id -HyperVGeneration $HyperVGen

#Create Managed disk
$NewManagedDisk = New-AzDisk -DiskName $NewDiskName -Disk $diskConfig -ResourceGroupName $resourceGroupName

$VM = Get-AzVM -ResourceGroupName $resourceGroupName -name $VMName
$VM | Stop-AzVM -Force

while(($state = Get-AzVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status).Statuses[1].DisplayStatus -ne "VM deallocated") { $state; Start-Sleep -Seconds 20 }
$state

# Set the VM configuration to point to the new disk
Set-AzVMOSDisk -VM $VM -ManagedDiskId $NewManagedDisk.Id -Name $NewManagedDisk.Name

# Update the VM with the new OS disk
Update-AzVM -ResourceGroupName $resourceGroupName -VM $VM

$VM | Start-AzVM

while(($state = Get-AzVm -Name $vm.Name -ResourceGroupName $vm.ResourceGroupName -Status).Statuses[1].DisplayStatus -ne "VM running") { $state; Start-Sleep -Seconds 20 }
$state

# Delete old Managed Disk
Remove-AzDisk -ResourceGroupName $resourceGroupName -DiskName $DiskName -Force;

# Delete old blob storage
$osdisk | Remove-AzStorageBlob -Force

# Delete temp storage account
$StorageAccount | Remove-AzStorageAccount -Force