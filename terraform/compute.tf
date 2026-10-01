locals {
  compartment_id = var.compartment_ocid != "" ? var.compartment_ocid : var.tenancy_ocid
  shape          = "VM.Standard.A1.Flex"
}

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_core_images" "ubuntu" {
  compartment_id           = local.compartment_id
  operating_system         = "Canonical Ubuntu"
  operating_system_version = var.ubuntu_version
  shape                    = local.shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Canonical-Ubuntu-${var.ubuntu_version}-aarch64-.*"]
    regex  = true
  }
}

resource "oci_core_instance" "mc" {
  compartment_id      = local.compartment_id
  availability_domain = data.oci_identity_availability_domains.ads.availability_domains[var.availability_domain_index].name
  display_name        = var.instance_name
  shape               = local.shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_gb
    # 10 VPUs/GB = "Balanced", the only performance level covered by Always Free.
    boot_volume_vpus_per_gb = 10
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.mc.id
    assign_public_ip = true
    hostname_label   = "minecraft"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64gzip(local.cloud_init)
  }

  preserve_boot_volume = false

  lifecycle {
    # user_data only runs at first boot, and changing it would recreate the
    # VM along with every game server on it. scripts/sync-bootstrap.sh pushes
    # template changes to a running instance instead.
    ignore_changes = [source_details[0].source_id, metadata["user_data"]]
  }
}

locals {
  cloud_init = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {
    timezone               = var.timezone
    region                 = var.region
    instance_name          = var.instance_name
    panel_version          = var.panel_version
    panel_domain           = var.panel_domain
    panel_admin_email      = var.panel_admin_email
    panel_admin_username   = var.panel_admin_username
    panel_admin_first_name = var.panel_admin_first_name
    panel_admin_last_name  = var.panel_admin_last_name
    panel_admin_password   = local.panel_admin_password
    app_key                = local.app_key
    db_root_password       = random_password.db_root.result
    db_password            = random_password.db_user.result
    game_port_min          = var.game_port_min
    game_port_max          = var.game_port_max
    mclibrarymgr_patch     = file("${path.module}/templates/extensions/mclibrarymgr-authz.patch")
  })
}
