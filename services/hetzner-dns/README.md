# Hetzner DNS

Declaratively manage [Hetzner DNS](https://docs.hetzner.cloud/reference/cloud#zones)
zones and records from NixOS: DNS zones, resource record sets (RRSets),
individual records, and secondary (slave) zones.

DNS is managed through the [`hetznercloud/hcloud`][hetznercloud/hcloud] provider.

[provider]: https://registry.terraform.io/providers/hetznercloud/hcloud/latest/docs

## Installation

### Include the module

Add this flake as an input and import its `nixosModules.hetzner-dns` into your
host. Pointing the input's `nixpkgs` at your own keeps the provider build in
step with the rest of your system.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # This repository.
    declarative-runtime.url = "github:youruser/declarative-runtime";
    declarative-runtime.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, declarative-runtime, ... }:
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          declarative-runtime.nixosModules.hetzner-dns
          ./host.nix
        ];
      };
    };
}
```

### Provide an API token

Create a Hetzner Cloud API token with DNS permissions ("Security > API tokens"
in the Hetzner Cloud console) and place it on the target host — e.g. via
sops-nix or agenix. Point `tokenFile` at that host path. `tokenFile` is
required: a cloud API token cannot be self-bootstrapped.

## Configuration examples

Declare the desired state under `services.hetzner-dns.runtime`. Each entry's
attributes are **typed options** named after the provider's snake_case
attributes.

### A zone with records (recommended)

`zone_rrsets` is the recommended way to manage records: one entry per
name+type, holding every value for that pair.

```nix
{
  services.hetzner-dns.runtime = {
    enable = true;
    tokenFile = "/run/secrets/hcloud-dns-token";

    zones.acme = {
      name = "acme.example";
      ttl = 3600;
      labels.team = "platform";
    };

    zone_rrsets.www = {
      zone = "acme";
      name = "www"; # "@" for the apex, "*" for a wildcard
      type = "A";
      ttl = 300;
      records = [
        { value = "203.0.113.10"; }
        { value = "203.0.113.11"; comment = "second frontend"; }
      ];
    };

    zone_rrsets.apex_txt = {
      zone = "acme";
      name = "@";
      type = "TXT";
      records = [ { value = ''"v=spf1 include:_spf.example -all"''; } ];
    };

    zone_rrsets.mail = {
      zone = "acme";
      name = "@";
      type = "MX";
      records = [ { value = "10 mail.acme.example"; } ];
    };
  };
}
```

### A single record (`zone_records`)

Use `zone_records` only when a single record must be managed independently of
the rest of its RRSet (it drives the `add_records`/`remove_records` API). Never
manage the same name+type with both a `zone_rrsets` **and** a `zone_records`
entry — they would fight over the set.

```nix
services.hetzner-dns.runtime.zone_records.legacy_a = {
  zone = "acme";
  name = "legacy";
  type = "A";
  value = "203.0.113.99";
  comment = "kept for the old load balancer";
};
```

### A zone managed elsewhere

`zone` also accepts a literal Hetzner zone name or numeric ID, for records in a
zone you do not manage from this host:

```nix
services.hetzner-dns.runtime.zone_rrsets.status = {
  zone = "shared.example";
  name = "status";
  type = "CNAME";
  records = [ { value = "status.hosted.example."; } ];
};
```

### A secondary zone

For a `secondary` zone, Hetzner slaves records from your own primary
nameservers; set `primary_nameservers` and leave the records to the primary.
The TSIG key authenticating zone transfers is a secret — supply it via
`tsig_keyFile`.

```nix
services.hetzner-dns.runtime.zones.mirror = {
  name = "mirror.example";
  mode = "secondary";
  primary_nameservers = [
    {
      address = "203.0.113.53";
      tsig_algorithm = "hmac-sha256";
      tsig_keyFile = "/run/secrets/mirror-tsig";
    }
  ];
};
```

## Module options (`services.hetzner-dns.runtime`)

| Option      | Type        | Default                        | Purpose                                                                             |
| ----------- | ----------- | ------------------------------ | ----------------------------------------------------------------------------------- |
| `enable`    | bool        | `false`                        | Turn on the reconciler.                                                             |
| `tokenFile` | null or str | `null`                         | **Required.** Host path to a Hetzner Cloud API token.                               |
| `endpoint`  | str         | `https://api.hetzner.cloud/v1` | Hetzner Cloud API base URL. Override only for a self-hosted proxy or a test double. |

Plus one collection option per provider resource (next section).

## Resources

| Option         | `hcloud_*` resource | Key defaults | Reference inputs        |
| -------------- | ------------------- | ------------ | ----------------------- |
| `zones`        | `zone`              | `name`       | —                       |
| `zone_rrsets`  | `zone_rrset`        | —            | `zone` → zone (name/ID) |
| `zone_records` | `zone_record`       | —            | `zone` → zone (name/ID) |

Notes:

- Apex `SOA`/`NS` RRSets are created and managed by Hetzner; do not declare them.
- `zones.<name>.mode` defaults to `"primary"`. `primary_nameservers` is required
  for `"secondary"` zones and forbidden for `"primary"` ones (enforced by the
  provider at apply).
- The reconciler keeps its Terraform state under
  `/var/lib/declarative-hetzner-dns`, owned by a dedicated `declarative-hetzner-dns`
  system user.

## Importing existing resources

Pointing the pairing at zones that **already** exist — or recovering after the
Terraform state under `/var/lib/declarative-hetzner-dns/declarative-terraform`
is lost — does not fail with "already exists". Before each `tofu apply`, the
reconciler runs a best-effort `tofu import` for every declared resource whose id
is derivable from your configuration, adopting what already exists into state;
anything genuinely absent is created. The same plan is also written to
`declarative-hetzner-dns-import.tf.json.disabled` in the work dir for a manual,
previewable adoption.

`zones` adopt by name. `zone_rrsets` have a derivable import id
(`<zone>/<name>/<type>`), but reconcile cleanly on adoption **only** when their
`zone` is a literal name (a zone managed elsewhere); when `zone` names a
_managed_ zone (whose numeric id a lost state cannot re-derive), a re-apply
replaces the RRSet rather than adopting it. `zone_records` support only
identity-based import and are always recreated.

## Security note

The API token always flows through systemd `LoadCredential=` into the sensitive
`hcloud_token` Terraform variable — the generated `.tf.json` holds only a
`${var.hcloud_token}` reference, never the literal.

The per-record TSIG secret (`tsig_key` on a secondary zone's
`primary_nameservers`) supports a `tsig_keyFile` form that takes a **host file
path** instead of the literal value. The file is read at apply time via
`LoadCredential=` into its own sensitive variable and **never enters the Nix
store**; the generated `.tf.json` holds only a `${var.…}` reference. `tsig_key`
and `tsig_keyFile` are mutually exclusive — prefer `tsig_keyFile` for any real
key. Setting `tsig_key` literally renders the value verbatim into the
**world-readable** `.tf.json` store path; use it only for throwaway values.
