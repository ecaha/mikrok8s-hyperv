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
5. Enable add-ons - hostpath and multus
6. Install kubevirt
7. Spin empheral VM - test kubevirt
8. Create custom storage class, set it default
9. Install CDI
10. Upload windows ISO
11. Create and run machine

## Install Ubuntu 22.04
Nothing special here, I am using netboot.xyz and iKVM on BMC to do that. Everything is set to defalut, nvme partitioned by default. For PoC OpenSSH server is installed and password authentication enabled. Single NIC is DHCPv4 enabled, we will configure the bridge later.

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
sudo echo "/dev/data-vg0/data-lv0 /mnt/data ext4 defaults 0 0" >> /etc/fstab
sudo mount /mnt/data
```
