# Kubevirt on microk8s on Ubuntu 22.04

The goal is to install 24H2 edition of Windows 11 as kubevirt pod. We will not optimize the solution for performance, it's PoC only.
There are some obstacles in the way to setup kubevirt on microk8s. Main two are - the microk8s snap location (kubelet directory) - is different from standard one and kubevirt is not playing nicely along. And the use of microk8s hostpath storage calss has some specifics as well.

### LAB platform
* Supermicro X11SCA-F board
* i7-8700 CPU
* 128 GB RAM
* 256GB Nvme for OS
* 4* 1TB SATA SSD for data
* Only 1 NIC (combined with BMC) is used in this setup

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
Nothing special here, I am using netboot.xyz and iKVM on BMC to do that. Everything is set to defalut, nvme partitioned by default. For PoC OpenSSH server is installed and password authentication enabled. Single NIC is DHCPv4 enabled, we will configure the bridge later. When the installation is done, restart server and SSH to it. 

Four SATA drives are in separate volumegroup (VG). Stripped logical volume (LV) is created.
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
sudo lvcreate -i 4 -l 100%FREE -n data-lv0 data-vg0

# mkfs
sudo mkfs.ext4 /dev/data-vg0/data-lv0

# mount
sudo mkdir -p /mnt/data
sudo bash -c 'echo "/dev/data-vg0/data-lv0 /mnt/data ext4 defaults 0 0" >> /etc/fstab'
sudo mount /mnt/data
```

## Netwroking setup
Ubuntu is using netplan to configure networking. Easiest way how to change direct connection to bridge is just add another file into _/etc/netplan/_ directory.
Before that we need to know the name of the interface. We can check which interface got an IP address from DHCP server. The name of the interface is required for bridge definition. Also the static address for our bridge interface is needed.

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
        - 192.168.174.41/24 #The IP address for the node
      routes:
        - to: default
          via: 192.168.174.1
      nameservers:
        addresses: [192.168.174.1, 8.8.8.8]
      interfaces:
        - eno2     # iface name
EOF'

sudo chmod 600 /etc/netplan/60-bridge.yaml

sudo netplan apply

# will result in a bugged warning `Cannot call Open vSwitch: ovsdb-server.service is not running.`
# which can be solved by installing the following package, however, it is safe to ignore
# https://bugs.launchpad.net/ubuntu/+source/netplan.io/+bug/2041727

#sudo apt get upgade
#sudo apt install openvswitch-switch-dpdk
#sudo netplan apply
```
Reestablish connection to the chosen IP address through SSH.

## Install microk8s
Straight forward procedure, nothing special here about the installation. After microk8s are installed we create _mount -o bind_ type junction, instead of symlink. Kubevirt is not working well with a symlink. Execute following in SSH session on the server.

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
We enable couple of addons
* community - for access to multus
* multus - network for VMs, we discuss it in detail in some following post
* hostpath-storage - access to local drives for pods
* metrics-server - used by Headlamp to monitor the environment
  
Execute on remote SSH session.
```bash
sudo microk8s enable community
sudo microk8s enable multus
sudo microk8s enable hostpath-storage
sudo microk8s enable metrics-server
```

## Set environment

We need to prepare our kubernetes management environment on a local Windows 11 machine by firstly acquiring the kubernetes config file from the server and then storing it locally. Then we will set a KUBECONFIG environment variable to point towards the cluster.

On the remote host, print out the config file to the terminal
```bash
sudo microk8s config
```
On the local Windows machine, create a directory for the config file by executing the following inside PowerShell, preferably >7
```Powershell
New-Item -ItemType Directory -Force -Path "$home/.kube"
notepad $home/.kube/mycluster.yaml
```
Copy and paste config from the remote host terminal to the new yaml file.

Then set the environment variable and test connectivity.
```Powershell
$env:KUBECONFIG = "$home/.kube/mycluster.yaml"
kubectl get pod -A
```
If it works, you can import kubeconfig into Headlamps for an easy cluster observation.

## Custom default storage class

The hostpath storage does not play well along with kubevirt. Easiest way how to overcome the issues is to create custom storage class and make it default. We will use /mnt/data (our SSD LVM stripe) location for that.

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
kubectl patch storageclass data-storageclass -p '{\"metadata\": {\"annotations\":{\"storageclass.kubernetes.io/is-default-class\":\"true\"}}}'
```
## Install kubevirt
Kubevirt requires having a control part deployed on the control plane (master nodes). Microk8s does not specify the role explicitly (is inferred by cluster topology). So we must to add the label to the node.

```powershell
kubectl get node
# uburtx01 is name of the node use the right one here
kubectl label node mynode node-role.kubernetes.io/master=master
kubectl get node
```

Just the standard installation procedure from [kubevirt.io](https://kubevirt.io/quickstart_kind/) rewritten into Powershell

```Powershell
$VERSION =  $(Invoke-WebRequest https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt).Content.Trim()
echo $VERSION
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-operator.yaml"
kubectl create -f "https://github.com/kubevirt/kubevirt/releases/download/${VERSION}/kubevirt-cr.yaml"

#By default KubeVirt will deploy 7 pods, 3 services, 1 daemonset, 3 deployment apps, 3 replica sets.
kubectl get all -n kubevirt
```

## Test empheral VM

We will not touch the persistent storage yet. We want know if kubevirt works and if it is capable of running precreated image. We expect virtctl is called from the actual ($pwd) directory it is located in.

```Powershell
kubectl apply -f https://kubevirt.io/labs/manifests/vm.yaml

# Optional - observe the vm
kubectl get vms
kubectl get vms -o yaml testvm

#Start the VM
./virtctl start testvm

#Connect to the VM
./virtctl console testvm

#Stop and delete VM
./virtctl stop testvm
kubectl delete vm testvm
```

## CDI

Now we need a way to pass the iso file to the virtual machine. CDI - Containerized Data Importer is the right tool for that. It will create a PVC (persistent volume claim) and will allow us to upload files into this persistent volume. More details [here](https://kubevirt.io/labs/kubernetes/lab2.html).

Install CDI - in powershell
```PowerShell
$Results = Invoke-WebRequest -Method Get -Uri  "https://github.com/kubevirt/containerized-data-importer/releases/latest" -MaximumRedirection 0 -ErrorAction SilentlyContinue

$VERSION = [System.IO.Path]::GetFileName($Results.Headers.Location)
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-operator.yaml
kubectl create -f https://github.com/kubevirt/containerized-data-importer/releases/download/$VERSION/cdi-cr.yaml

#Check four CDI pods
kubectl get pods -n cdi
```

## Upload image
Basically, we are following this [article](https://kubevirt.io/2022/KubeVirt-installing_Microsoft_Windows_11_from_an_iso.html).

To upload the image, we need a way to communicate with the cdi-proxy pod. The default service uses cluster IP and therefore is not accessible by default from outside. Easiest approach is to declare an additional service which will use a nodeport.

```PowerShell
$service = @"
apiVersion: v1
kind: Service
metadata:
  name: cdi-uploadproxy-nodeport
  namespace: cdi
  labels:
    cdi.kubevirt.io: "cdi-uploadproxy"
spec:
  type: NodePort
  ports:
      - port: 443
        targetPort: 8443
        nodePort: 32111 # Use unused nodeport in 31,500 to 32,767 range
        protocol: TCP
  selector:
    cdi.kubevirt.io: cdi-uploadproxy
"@

$service | kubectl apply -f -
```

We are using the 24H2 version of Windows 11 here. In an upcoming article we will discuss options such as injecting virtio drivers into a custom ISO, removing the "Press any key requirement" etc. As well as the option to prepare a _golden image_ and clone it as a VM. For now, a simple "Next->Next..." Windows install will be sufficient enough. To do that, we need to upload a Windows 11 ISO from our local machine. You can use a trial version but I will be using a key from my Visual Studio subscribtion.

```Powershell
./virtctl image-upload pvc win11cd-pvc --size 7Gi --force-bind --image-path=..path/to/win11.iso --insecure --uploadproxy-url="https://192.168.174.41:32111"
```

## Create windows VM and run installation
We need a PVC for the windows hardrive and VM definition. Then we can start the machine and use VNC to access graphics console. You must distinguish between the two different kinds of resources kubevirt introduces - VirtualMachine and VirtualMachineInstance. VM has a state and we usally use virtctl to control it and therefore has a slightly different lifecycle than regulare pod. VMI lifecycle is much closer to the pod and you use kubectl to work with it. If you dig deeper in some examples, always check the kind in yaml files.

PVC => windows harddisk - change size according to your needs
```Powershell
$winpvc=@"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wintest01-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 64Gi
"@

$winpvc | kubectl apply -f -
```

VM definition - be aware - it has TPM, but TPM is not persisted, so if you bitlocker your disk, you will need a recovery key each time. You can enable persistent TPM in feature toggle for kubevirt. Its just vTPM file based not backed by any real hardware TPM.

```PowerShell
$wintest01 = @"
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  labels:
    special: wintest01
  name: wintest01
spec:
  runStrategy: Halted
  template:
    metadata:
      labels:
        kubevirt.io/domain: wintest01
    spec:
      architecture: amd64
      domain:
        clock:
          utc: {}
          timer:
            hpet:
              present: false
            pit:
              tickPolicy: delay
            rtc:
              tickPolicy: catchup
            hyperv: {}
        features:
          acpi: {}
          apic: {}
          smm: {}
          hyperv:
            relaxed: {}
            vapic: {}
            vpindex: {}
            spinlocks:
              spinlocks: 8191
            synic: {}
            synictimer:
              direct: {}
            tlbflush: {}
            frequencies: {}
            reenlightenment: {}
            ipi: {}
            runtime: {}
            reset: {}
        firmware:
          bootloader:
            efi:
              secureBoot: true
#              persistent: true
          uuid: 5d307ca9-b3ef-428c-8861-06e72d69f223
        cpu:
          cores: 4
        devices:
          tpm: {}
 #           persistent: true
          interfaces:
          - masquerade: {}
            model: e1000
            name: default
          disks:
          - bootOrder: 1
            cdrom:
              bus: sata
            name: winiso
          - disk:
              bus: sata
            name: pvcdisk
        resources:
          requests:
            memory: 8G
      networks:
      - name: default
        pod: {}
      volumes:
      - name: pvcdisk
        persistentVolumeClaim:
          claimName:  wintest01-pvc
      - name: winiso
        persistentVolumeClaim:
          claimName: win11cd-pvc
"@

$wintest01 | kubectl apply -f -
```

Run and VNC to the machine
```Powershell
./virtctl start wintest01
./virtctl vnc wintest01
```
If it is not working add RealVNC to your path
```Powershell
$env:PATH = $env:PATH + ";C:\\Program Files\\RealVNC\\VNC Viewer"
```

