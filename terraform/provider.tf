

terraform {
    required_providers {
      hyperv = {
        source = "taliesins/hyperv"
        version = ">= 1.0.4"
      }
    }
}
provider "hyperv" {
    user            = "BIGBOY\\Administator"
    password        = "Jerabina123456!"
    host            = "192.168.174.61"
    port            = 5986
    https           = true
    insecure = true
    script_path     = "C:/Temp/terraform_%RAND%.cmd"
    timeout         = "30s"
}

resource "hyperv_vhd" "web_server_vhd" {
  path = "c:\\temp\\web_server_g2.vhdx"
  #source               = ""
  #source_vm            = ""
  #source_disk          = 0
  vhd_type = "Dynamic"
  #parent_path          = ""
  size = 10737418240 #10GB
  #block_size           = 0
  #logical_sector_size  = 0
  #physical_sector_size = 0
}
