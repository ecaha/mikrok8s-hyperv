# Kubevirt on microk8s on Ubuntu 22.04

There are some obstacles in the way to setup kubevirt on microk8s. Main two are - the microk8s snap location (kubelet directory) - is different from standard one and kubevirt is not playing nicely. The use of microk8s hostpath storage calss has some specifics as well.

Let's start.

As an operator station I am using windows 11. We need couple of tools.

* VS Code - obviously
* kubectl
* virtctl [v1.4 link](https://github.com/kubevirt/kubevirt/releases/download/v1.4.0/virtctl-v1.4.0-windows-amd64.exe)
* vncviewer
* headlamp

```PowerShell
winget install Kubernetes.kubectl
winget install 
```

I will provide detailed instruction further in the text, but in glance:

1. Install Ubuntu 22.04 server
2. Set bridge networking, _set the static IP_
3. Install microk8s
4. Replace symbolic link in _/var/lib/kubelet_ by mount -o bind (in fstab as well)
5. Enable add-ons - hostpath and 
