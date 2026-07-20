{ pkgs }:
let
  genlib = import ../../modules/lib { inherit pkgs; };
  inherit (genlib)
    oStr
    oBool
    oInt
    oAttrsStr
    oListSub
    rStr
    ;
  inherit (pkgs) lib;
  ty = lib.types;

  provider = pkgs.terraform-providers.hetznercloud_hcloud;
  providerVersion = provider.version;
  # The Hetzner Cloud API token; exposed to OpenTofu as the sensitive
  # `hcloud_token` variable/ `TF_VAR_hcloud_token`.
  tokenVar = "hcloud_token";
  executor = pkgs.opentofu.withPlugins (_: [ provider ]);

  recordSubmodule = ty.submodule {
    options = {
      value = rStr "Value of the record (e.g. an IPv4/IPv6 address, target host, or a quoted TXT string).";
      comment = oStr "Optional comment for this record.";
    };
  };

  # ID or Name of a parent zone. Managed zones resolve to
  # `${hcloud_zone.<label>.id}`; other values pass as it.
  zoneRef = {
    attr = "zone";
    targets = [
      {
        collection = "zones";
        field = "id";
      }
    ];
    managedOnly = false;
    required = true;
    description = "Parent zone: the key of a managed zone, or a literal Hetzner zone name/ID for a zone managed elsewhere.";
  };

  # The DNS resource surface of the hetznercloud/hcloud provider. Per resource:
  #   type            the `hcloud_*` resource type
  #   prefix          unique Terraform label prefix
  #   nameAttr        attribute defaulted from the collection key (or null)
  #   refs            parent links resolved to references against managed zones
  #   requiredAttrs   collection attrs that must be present and non-empty
  #   attrs           the settable attributes, each a typed option (no freeform)
  #   importId        (optional) declared-state -> provider import id (see
  #                   modules/lib mkImportEntries); omitted where the id is
  #                   server-assigned or not importable by id string
  # Computed/output-only attributes (id, registrar, authoritative_nameservers,
  # protection read-back, ...) are intentionally omitted.
  resourceTypes = {
    zones = {
      type = "hcloud_zone";
      prefix = "zone";
      nameAttr = "name";
      refs = { };
      # imported by zone (domain) name.
      importId = ctx: ctx.item.name;
      description = "Hetzner DNS zones, keyed by zone (domain) name.";
      attrs = {
        name = oStr "Name of the zone (domain, e.g. \"example.com\"). Defaults to the attribute key.";
        mode = lib.mkOption {
          type = ty.str;
          default = "primary";
          description = ''
            Zone mode: "primary" (Hetzner is authoritative; manage records here)
            or "secondary" (Hetzner slaves the zone from your own primaries -- set
            `primary_nameservers` and leave records to the primary).
          '';
        };
        ttl = oInt "Default TTL (seconds) for the zone's records (provider default 3600).";
        labels = oAttrsStr "User-defined labels (key/value pairs) attached to the zone.";
        delete_protection = oBool "Protect the zone from deletion.";
        primary_nameservers =
          oListSub
            {
              address = rStr "Public IPv4 or IPv6 address of the primary nameserver.";
              port = oInt "Port of the primary nameserver (default 53).";
              tsig_algorithm = oStr "TSIG algorithm (e.g. \"hmac-sha256\") used to sign zone transfers.";
              tsig_key = oStr "TSIG key authenticating zone transfers. Prefer `tsig_keyFile` to keep the secret out of the world-readable store.";
              tsig_keyFile = oStr "Runtime path to a file holding the TSIG key (loaded via systemd LoadCredential=; never copied to the store). Mutually exclusive with a literal `tsig_key`.";
            }
            "Primary nameservers Hetzner transfers a secondary zone from. Required when `mode = \"secondary\"`, forbidden when `mode = \"primary\"`.";
      };
    };

    zone_rrsets = {
      type = "hcloud_zone_rrset";
      prefix = "rrset";
      nameAttr = null;
      refs.zone = zoneRef;
      # imported by "<zone>/<name>/<type>"; the zone component is the parent
      # zone's name (or the literal the user gave).
      importId =
        ctx:
        let
          zone = ctx.refName "zone";
        in
        if zone == null then null else "${zone}/${ctx.item.name}/${ctx.item.type}";
      requiredAttrs = [ "records" ];
      description = "Hetzner DNS resource record sets (all records sharing a name+type), keyed by an arbitrary label. The recommended way to manage records.";
      attrs = {
        name = rStr "Record name relative to the zone: \"@\" for the apex, or a label such as \"www\" or \"*\".";
        type = rStr "RRSet type: A, AAAA, CNAME, MX, TXT, SRV, NS, CAA, DS, PTR, TLSA, ... (SOA/NS at the apex are managed by Hetzner).";
        ttl = oInt "TTL (seconds) for this RRSet; falls back to the zone default when unset.";
        labels = oAttrsStr "User-defined labels (key/value pairs) attached to the RRSet.";
        change_protection = oBool "Protect the RRSet's records from changes.";
        records = lib.mkOption {
          type = ty.listOf recordSubmodule;
          description = "The records making up this set (at least one). For TXT, each value must be one or more quoted 255-char strings.";
        };
      };
    };

    zone_records = {
      type = "hcloud_zone_record";
      prefix = "record";
      nameAttr = null;
      refs.zone = zoneRef;
      description = "Individual Hetzner DNS records, keyed by an arbitrary label. Prefer `zone_rrsets`; use this only when a single record must be managed independently of the rest of its RRSet (never manage the same name+type with both).";
      attrs = {
        name = rStr "Record name relative to the zone: \"@\" for the apex, or a label such as \"www\".";
        type = rStr "Record type (A, AAAA, CNAME, MX, TXT, ...).";
        value = rStr "Value of the record (e.g. an IPv4/IPv6 address, target host, or a quoted TXT string).";
        comment = oStr "Optional comment for the record.";
      };
    };
  };

  # cfg -> { config; credentials; }. `config` carries no secrets
  hetznerDnsTfConfig = genlib.mkTfConfig {
    inherit resourceTypes providerVersion tokenVar;
    providerName = "hcloud";
    providerSource = "hetznercloud/hcloud";
    runtimePrefix = "services.hetzner-dns.runtime";
    providerBlock = cfg: {
      token = "\${var.${tokenVar}}";
      inherit (cfg) endpoint;
    };
  };
in
{
  inherit resourceTypes hetznerDnsTfConfig;
  resourceOptions = genlib.resourceOptions resourceTypes;
  mkReconcileService = args: genlib.mkReconcileService (args // { inherit executor tokenVar; });
}
