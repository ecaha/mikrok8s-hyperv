# Kubevirt on microk8s on Ubuntu 22.04

There are some obstacles in the way to setup kubevirt on microk8s. Main two are - the microk8s snap location (kubelet directory) - is different from standard one and kubevirt is not playing nicely. The use of microk8s hostpath storage calss has some specifics as well.

Let's start.

I will provide detailed instruction further in the text, but in glance:

1. Install Ubuntu 22.04 server
2. Set bridge networking, _set the static IP_
3. Install microk8s
4. Replace symbolic link in _/var/lib/kubelet_ by mount -o bind (in fstab as well)
5. 
