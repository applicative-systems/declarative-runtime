{
  config,
  pkgs,
  modulesPath,
  ...
}:
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  networking.hostName = "scranton";
  networking.firewall.enable = false;
  time.timeZone = "America/New_York";

  services.openssh.enable = true;
  services.openssh.settings.PermitRootLogin = "yes";
  users.users.root.password = "hackme";
  services.getty.autologinUser = "root";

  environment.systemPackages = with pkgs; [
    curl
    jq
  ];

  # demo-only: stand-ins for the host-file secrets that <attr>File options
  # reach for via systemd LoadCredential. real deployments source these
  # from sops-nix / agenix; never the world-readable nix store.
  environment.etc = {
    "secrets/keycloak-db-password".text = "hackme";
    "secrets/keycloak-admin-password".text = "hackme";
    "secrets/jhalpert-password".text = "hackme";
    "secrets/dunder-mifflin-app-client-secret".text = "topsecret";
    "secrets/dschrute-password".text = "hackme";
    "secrets/jhalpert-forgejo-password".text = "hackme";
  };

  virtualisation = {
    memorySize = 4096;
    diskSize = 8192;
    graphics = false;
    forwardPorts = [
      {
        from = "host";
        host.port = 2222;
        guest.port = 22;
      }
      {
        from = "host";
        host.port = 8080;
        guest.port = 8080;
      }
      {
        from = "host";
        host.port = 3000;
        guest.port = 3000;
      }
      {
        from = "host";
        host.port = 8888;
        guest.port = 8888;
      }
    ];
  };

  # static avatar host. svg rasterised to png at build time so forgejo's
  # Go image decoder (no svg support) can ingest it on SSO. virtualHost
  # name doubles as server_name; "localhost" matches the Host header from
  # both the host browser and forgejo's avatar fetcher inside the vm.
  services.nginx = {
    enable = true;
    virtualHosts.localhost = {
      default = true;
      listen = [
        {
          addr = "0.0.0.0";
          port = 8888;
        }
      ];
      root = pkgs.runCommand "avatars" { nativeBuildInputs = [ pkgs.librsvg ]; } ''
        mkdir -p $out
        rsvg-convert -w 200 -h 200 -o $out/jhalpert.png ${./avatars/jhalpert.svg}
      '';
    };
  };

  services.keycloak = {
    enable = true;
    initialAdminPassword = "hackme";
    settings = {
      hostname = "localhost";
      http-port = 8080;
      http-enabled = true;
      hostname-strict = false;
    };
    database.passwordFile = "/etc/secrets/keycloak-db-password";

    themes.dunder_mifflin = pkgs.runCommand "keycloak-theme-dunder-mifflin" { } ''
      cp -r ${./themes/dunder_mifflin} $out
    '';

    runtime = {
      enable = true;
      bootstrapAdminPasswordFile = "/etc/secrets/keycloak-admin-password";

      realms.dunder_mifflin = {
        display_name = "Dunder Mifflin Paper Company";
        login_theme = "dunder_mifflin";
      };

      # declare picture (and the four standard attrs) and flip unmanaged
      # to ENABLED so keycloak v24+'s declarative profile stores
      # users.jhalpert.attributes.picture instead of silently dropping it.
      realm_user_profiles.dunder_mifflin =
        let
          stdPerms = {
            view = [
              "admin"
              "user"
            ];
            edit = [
              "admin"
              "user"
            ];
          };
          stdAttr = name: {
            inherit name;
            permissions = stdPerms;
          };
        in
        {
          realm = "dunder_mifflin";
          unmanaged_attribute_policy = "ENABLED";
          attribute = [
            (stdAttr "username")
            (stdAttr "email")
            (stdAttr "firstName")
            (stdAttr "lastName")
            {
              name = "picture";
              display_name = "Avatar URL";
              permissions = stdPerms;
            }
          ];
        };

      users.jhalpert = {
        realm = "dunder_mifflin";
        username = "jhalpert";
        email = "jim@dundermifflin.com";
        first_name = "Jim";
        last_name = "Halpert";
        enabled = true;
        email_verified = true;
        # default `profile` client scope maps this into the OIDC `picture`
        # claim; forgejo pulls it on SSO when UPDATE_AVATAR=true.
        attributes.picture = "http://localhost:8888/jhalpert.png";
        initial_password = {
          valueFile = "/etc/secrets/jhalpert-password";
          temporary = false;
        };
      };

      openid_clients.dunder_mifflin_infinity = {
        realm = "dunder_mifflin";
        client_id = "dunder-mifflin-infinity";
        name = "Dunder Mifflin Infinity";
        access_type = "CONFIDENTIAL";
        client_secretFile = "/etc/secrets/dunder-mifflin-app-client-secret";
        valid_redirect_uris = [ "http://localhost:3000/user/oauth2/DunderMifflinInfinity/callback" ];
        web_origins = [ "http://localhost:3000" ];
        standard_flow_enabled = true;
      };
    };
  };

  services.forgejo = {
    enable = true;
    settings.server = {
      HTTP_PORT = 3000;
      DOMAIN = "localhost";
      ROOT_URL = "http://localhost:3000/";
    };
    settings.security.MIN_PASSWORD_LENGTH = 6;
    # forgejo's HTTP client blocks RFC1918 + loopback by default (anti-SSRF);
    # avatar pulls go through that same client, so the local nginx is
    # unreachable without this flip.
    settings.migrations.ALLOW_LOCALNETWORKS = true;
    settings.oauth2_client = {
      ENABLE_AUTO_REGISTRATION = true;
      USERNAME = "preferred_username";
      ACCOUNT_LINKING = "auto";
      UPDATE_AVATAR = true;
    };

    runtime = {
      enable = true;

      organizations.dunder_mifflin = {
        visibility = "public";
        description = "Dunder Mifflin Paper Company, Inc.";
      };

      repositories.scranton_branch = {
        owner = "dunder_mifflin";
        description = "The best branch in the company";
        private = false;
      };

      # internal repo: only collaborators can see it. forgejo's SSO
      # auto-registration creates a user with login = preferred_username
      # (`jhalpert`); pre-creating jhalpert here lets us name him as a
      # collaborator. ACCOUNT_LINKING=auto matches by email on first SSO,
      # so the pre-created + SSO accounts are the same forgejo user.
      repositories.intranet = {
        owner = "dunder_mifflin";
        description = "Internal Dunder Mifflin intranet -- not for the warehouse";
        private = true;
      };

      users.jhalpert = {
        email = "jim@dundermifflin.com";
        full_name = "Jim Halpert";
        passwordFile = "/etc/secrets/jhalpert-forgejo-password";
        must_change_password = false;
      };

      users.dschrute = {
        email = "dschrute@dundermifflin.com";
        passwordFile = "/etc/secrets/dschrute-password";
        must_change_password = false;
      };

      collaborators.jhalpert_intranet = {
        repository = "intranet";
        user = "jhalpert";
        permission = "write";
      };
    };
  };

  # SSO glue: the svalabs/forgejo terraform provider doesn't model auth
  # sources, so this oneshot calls `forgejo admin auth add-oauth` after
  # both reconcilers are done. The source name doubles as the URL slug
  # in the OAuth2 callback path (must match keycloak's valid_redirect_uris).
  systemd.services.forgejo-oauth-setup =
    let
      fcfg = config.services.forgejo;
      appIni = "${fcfg.customDir}/conf/app.ini";
    in
    {
      description = "Register Keycloak as a forgejo OAuth2 login source";
      after = [
        "forgejo.service"
        "declarative-keycloak.service"
      ];
      requires = [
        "forgejo.service"
        "declarative-keycloak.service"
      ];
      wantedBy = [ "multi-user.target" ];
      path = [
        fcfg.package
        pkgs.gawk
        pkgs.curl
      ];
      environment = {
        GITEA_WORK_DIR = fcfg.stateDir;
        GITEA_CUSTOM = fcfg.customDir;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = fcfg.user;
        Group = fcfg.group;
        LoadCredential = [ "client-secret:/etc/secrets/dunder-mifflin-app-client-secret" ];
      };
      script = ''
        set -euo pipefail
        sso_name=DunderMifflinInfinity
        if forgejo --config '${appIni}' admin auth list | awk 'NR>1 {print $2}' | grep -qx "$sso_name"; then
          exit 0
        fi
        for _ in $(seq 1 60); do
          if curl -fsS -o /dev/null \
               http://localhost:8080/realms/dunder_mifflin/.well-known/openid-configuration; then
            break
          fi
          sleep 2
        done
        secret="$(cat "$CREDENTIALS_DIRECTORY/client-secret")"
        forgejo --config '${appIni}' admin auth add-oauth \
          --name "$sso_name" \
          --provider openidConnect \
          --key dunder-mifflin-infinity \
          --secret "$secret" \
          --scopes "openid email profile" \
          --auto-discover-url http://localhost:8080/realms/dunder_mifflin/.well-known/openid-configuration
      '';
    };

  system.stateVersion = "26.05";
}
