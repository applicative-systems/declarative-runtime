# `virtualisation.incus.runtime` fixtures, shared by the VM test in
# ./checks.nix and by the `incus-rendered-fixtures` package.
#
# why the indirection: `incus-rendered-fixtures` renders these through the
# real option system and renderer, so the `.tf.json` snapshot that guards
# refactors of the resource surface is produced from exactly the configuration
# the VM test proves converges against a live incus.
{
  # Everything the VM test declares at boot. Spans adoption of objects that
  # the preseed of the VM test made (a network and a pool), changes to the
  # `default` profile that incus makes, objects in a project of their own, a
  # reference to an adopted object, the server configuration, and a
  # certificate from a host file.
  main = {
    # The preseed made this network. The reconciler adds the keys that the
    # preseed does not set.
    network.incusbr0 = {
      adopt = true;
      type = "bridge";
      config = {
        "ipv4.address" = "10.0.100.1/24";
        "ipv4.nat" = "true";
        "ipv6.address" = "none";
        "dns.domain" = "incus.test";
        "raw.dnsmasq" = "dhcp-option-force=26,1400";
      };
    };
    network.internal = {
      type = "bridge";
      config = {
        "ipv4.address" = "10.0.200.1/24";
        "ipv4.nat" = "false";
        "ipv6.address" = "none";
      };
    };

    storage_pool.default = {
      adopt = true;
      driver = "dir";
    };
    # The pool is a reference to the adopted pool.
    storage_volume.data = {
      pool = "default";
      description = "Data volume on the adopted pool";
    };

    # incus makes the `default` profile. The provider changes it in place.
    profile.default = {
      description = "Default profile, set by the reconciler";
      device = [
        {
          name = "eth0";
          type = "nic";
          properties = {
            network = "incusbr0";
            name = "eth0";
          };
        }
        {
          name = "root";
          type = "disk";
          properties = {
            path = "/";
            pool = "default";
          };
        }
      ];
    };

    project.tenant = {
      description = "Workloads of a tenant";
      config."limits.instances" = "4";
    };
    profile.web = {
      project = "tenant";
      description = "Web workloads of the tenant";
      config."limits.cpu" = "1";
    };

    server.main.config."core.https_address" = ":8443";

    # A certificate that the host makes at runtime: the provider reads it from
    # the file when it applies.
    certificate.metrics = {
      type = "metrics";
      certificateFile = "/etc/incus-metrics.crt";
      # Nothing writes this file, so the apply creates the certificate.
      adoptIdFile = "/run/incus-metrics.id";
    };

    # A certificate that is in the trust store before the first apply. The VM
    # test writes its fingerprint to the file.
    certificate.adopted = {
      type = "metrics";
      certificateFile = "/etc/incus-adopted.crt";
      adoptIdFile = "/run/incus-adopted.id";
    };
  };

  # No `<attr>File` attribute and no credential, so the rendered config has no
  # variables. The renderer must then leave out the `variable` block.
  noFiles = {
    network.incusbr0 = {
      adopt = true;
      type = "bridge";
      config."ipv4.address" = "10.0.100.1/24";
    };
  };
}
