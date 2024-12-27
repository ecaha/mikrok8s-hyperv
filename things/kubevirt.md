# Kubevirt on microk8s on Ubuntu 22.04

The goal is to install 24H2 edition of Windows 11 as kubevirt pod. We will not optimize the solution for performance, it's PoC only.
There are some obstacles in the way to setup kubevirt on microk8s. Main two are - the microk8s snap location (kubelet directory) - is different from standard one and kubevirt is not playing nicely. The use of microk8s hostpath storage calss has some specifics as well.

LAB platform
* Supermicro X11SCA-F board
* i7-8700 CPU
* 128 GB RAM
* 256GB Nvme for OS
* 4* 1TB SATA SSD for data
* Only 1 NIC (combined with BMC) is used in this setup

Let's start.

As an operator station I am using windows 11. We need couple of tools.

* VS Code - obviously
* kubectl
* virtctl [v1.4 link](https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/virtctl-v1.4.0-windows-amd64.exe)
* vncviewer
* headlamp (optional Microsoft's tool for kuebrnetes management)
  

```PowerShell
winget install Kubernetes.kubectl
winget install vncviewer
winget install Headlamp.Headlamp
```

When we are armed by tools we can setup the microk8s node. I will provide detailed instruction further in the text, but in glance:

1. Install Ubuntu 22.04 server
2. Set bridge networking, _set the static IP_
3. Install microk8s
4. Replace symbolic link in _/var/lib/kubelet_ by mount -o bind (in fstab as well)
5. Enable add-ons - hostpath-storage, metrics-server and multus
6. Set environment, create custom storage class, set it default
7. Install kubevirt
8. Spin empheral VM - test kubevirt
10. Install CDI
11. Upload windows ISO
12. Create and run machine

## Install Ubuntu 22.04
Nothing special here, I am using netboot.xyz and iKVM on BMC to do that. Everything is set to defalut, nvme partitioned by default. For PoC OpenSSH server is installed and password authentication enabled. Single NIC is DHCPv4 enabled, we will configure the bridge later. When the installation is done, restert server and SSH to it. 

Four SATA drives are in separate VG and stripped LV is created.
```bash
# SSH to server

# list blk devices to check SATA drives connection
sudo lsblk

# remove LVM
sudo lvdisplay
sudo lvremove /dev/data-vg0/data-lv0
sudo vgremove data-vg0
sudo pvremove /dev/sda /dev/sdb /dev/sdc /dev/sdd

#clean drives with sfdisk
sudo sfdisk --delete /dev/sda
sudo sfdisk --delete /dev/sdb
sudo sfdisk --delete /dev/sdc
sudo sfdisk --delete /dev/sdd
```

Create new lvm for data

```bash
# LVM
sudo pvcreate /dev/sda /dev/sdb /dev/sdc /dev/sdd
sudo vgcreate data-vg0 /dev/sda /dev/sdb /dev/sdc /dev/sdd
sudo lvcreate -l 100%FREE -n data-lv0 data-vg0

# mkfs
sudo mkfs.ext4 /dev/data-vg0/data-lv0

# mount
sudo mkdir -p /mnt/data
sudo bash -c 'echo "/dev/data-vg0/data-lv0 /mnt/data ext4 defaults 0 0" >> /etc/fstab'
sudo mount /mnt/data
```

## Netwroking setup
Ubuntu is using netplan to configure networking. Easiest way how to change direct connection to bridge is just add another file into _/etc/netplan/_ directory.
Before that we need to know the connected DHCPv4 provided interface we will use in the bridge scenario. Also the static address for our bridge interface is needed.

```bash
# check the interface name
sudo cat /etc/netplan/50-cloud-init.yaml #in the ethernets section, the name of iface with dhcp4: true
# XOR
sudo ip ad #iface name with ipaddress

sudo bash -c 'cat << EOF > /etc/netplan/60-bridge.yaml
network:
  version: 2
  renderer: networkd
  bridges:
    br0:
      addresses:
        - 192.168.174.41/24
      gateway4: 192.168.174.1
      nameservers:
        addresses: [192.168.174.1, 8.8.8.8]
      interfaces:
        - eno2     
EOF'

sudo chmod 600 /etc/netplan/60-bridge.yaml

sudo netplan apply
```
Restablish connection to chosen IP address

## Install microk8s
Straithforward procedure nothing special here. Execute in SSH session on the server.

```bash
sudo snap install microk8s --classic

# wait until it starts
sudo microk8s status

# stop microk8s
sudo microk8s stop

#remove symlink
sudo rm /var/lib/kubelet
sudo mkdir -p /var/lib/kubelet
sudo bash -c 'echo "/var/snap/microk8s/common/var/lib/kubelet /var/lib/kubelet none bind 0 0" >> /etc/fstab'
sudo mount /var/lib/kubelet

#start microk8s
sudo microk8s start
```

## Enable Addons
Execute on remote SSH session.
```bash
sudo microk8s enable community
sudo microk8s enable multus
sudo microk8s enable hostpath-storage
sudo microk8s enable metrics-server
```

## Set environment
We need to prepare our kubernetes management environment. So we get kubeconfig from the server and we will store it locally.
On the remote host execute
```bash
sudo microk8s config
```
On local widnows machine execute in PowerShell, preferably >7
```Powershell
New-Item -ItemType Directory -Force -Path "$home/.kube"
notepad $home/.kube/mycluster
```
Copy and paste config from terminal to the file and then set envrionemnt variable and test connectivity
```Powershell
$env:KUBECONFIG = "$home/.kube/mycluster"
kubectl get pod -A
```
If it works, you can impor kubeconfig into Headlamps for easy cluster observation.

## Custom default storage class
The hostpath storage does not play well along with kubevirt. Easiest way how to overcome the issues is to create custom storage class and make it  default. \we will use /mnt/data location for that.

```Powershell
$storClass = @"
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: data-storageclass
provisioner: microk8s.io/hostpath
reclaimPolicy: Retain
parameters:
  pvDir: /mnt/data
volumeBindingMode: WaitForFirstConsumer
"@

#add storage class
$storClass | kubectl apply -f -

#make it default
kubectl patch storageclass microk8s-hostpath -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'
kubectl patch storageclass data-storageclass -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"false\"}}}'
```
## Install kubevirt
Just standard installation procedure rewritten into Powershell

```Powershell
$VERSION =  $(Invoke-WebRequest https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt).Content.Trim()
echo $VERSION
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-operator.yaml"
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-cr.yaml"

#By default KubeVirt will deploy 7 pods, 3 services, 1 daemonset, 3 deployment apps, 3 replica sets.
kubectl get all -n kubevirt
```
