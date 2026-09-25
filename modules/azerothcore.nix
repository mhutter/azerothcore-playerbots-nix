# Takes the flake's overlay so the host does not have to apply it.
overlay:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.azerothcore;
  acPkgs = overlay pkgs pkgs;
  runDir = "/run/azerothcore";

  toConf = lib.generators.toKeyValue { mkKeyValue = k: v: "${k} = ${toString v}"; };

  # AC only reads the .conf, never the .dist. So the runtime config is
  # <pkg>/etc/*.conf.dist with the overridden keys removed and our overrides
  # appended (AC keeps the first duplicate key in a file and ignores the rest).
  # Secrets never hit the store: @DB_PASSWORD@ and @TOTP_MASTER_SECRET@ are
  # substituted in preStart.
  worldConf = pkgs.writeText "worldserver.conf" (toConf cfg.worldserver.settings);
  authConf = pkgs.writeText "authserver.conf" (toConf cfg.authserver.settings);
  # One file per module config, named like the .conf it overrides.
  moduleConfs = pkgs.linkFarm "azerothcore-module-confs" (
    lib.mapAttrs (name: s: pkgs.writeText name (toConf s)) cfg.moduleSettings
  );

  # Host "." makes AzerothCore treat the port field as a unix socket path.
  dbEndpoint =
    if cfg.database.socket != null then
      ".;${cfg.database.socket}"
    else
      "${cfg.database.host};${toString cfg.database.port}";
  dbInfo = db: "${dbEndpoint};${cfg.database.user};@DB_PASSWORD@;${db}";
  totpSetting = lib.optionalAttrs (cfg.totpMasterSecretFile != "") {
    TOTPMasterSecret = "@TOTP_MASTER_SECRET@";
  };

  preStart = pkgs.writeShellScript "azerothcore-render-conf" ''
    set -eu
    pw=""
    [ -n "${cfg.database.passwordFile}" ] && pw=$(cat "$CREDENTIALS_DIRECTORY/dbpass")
    totp=""
    if [ -n "${cfg.totpMasterSecretFile}" ]; then
      totp=$(tr -d "[:space:]" < "$CREDENTIALS_DIRECTORY/totp")
      [[ $totp =~ ^[0-9a-fA-F]{32}$ ]] \
        || { echo "totpMasterSecretFile: expected 32 hex chars (openssl rand -hex 16)" >&2; exit 1; }
    fi
    mkdir -p ${runDir}/modules
    # Drop the .dist lines for overridden keys, then append the overrides.
    render() {
      { ${lib.getExe pkgs.gawk} -F= '
          { k = $1; gsub(/^[ \t]+|[ \t]+$/, "", k) }
          FILENAME == ARGV[1] { if (k != "") o[k] = 1; next }
          !(k in o)
        ' "$2" "$1"; echo; cat "$2"; } \
        | sed -e "s|@DB_PASSWORD@|$pw|g" -e "s|@TOTP_MASTER_SECRET@|$totp|g" > "$3"
    }
    render ${cfg.package}/etc/worldserver.conf.dist ${worldConf} ${runDir}/worldserver.conf
    render ${cfg.package}/etc/authserver.conf.dist ${authConf} ${runDir}/authserver.conf
    for o in ${moduleConfs}/*; do
      [ -e "$o" ] || continue # no moduleSettings at all
      n=$(basename "$o")
      [ -e ${cfg.package}/etc/modules/$n.dist ] \
        || { echo "moduleSettings.\"$n\": package ships no modules/$n.dist" >&2; exit 1; }
    done
    rm -f ${runDir}/modules/*.conf
    for d in ${cfg.package}/etc/modules/*.conf.dist; do
      [ -e "$d" ] || continue # package built without module configs
      n=$(basename "$d" .dist)
      o=${moduleConfs}/$n
      [ -e "$o" ] || o=/dev/null
      render "$d" "$o" ${runDir}/modules/$n
    done
  '';

  serviceCommon = {
    User = "azerothcore";
    Group = "azerothcore";
    WorkingDirectory = cfg.stateDir;
    RuntimeDirectory = "azerothcore";
    RuntimeDirectoryPreserve = true;
    StateDirectory = "azerothcore";
    LogsDirectory = "azerothcore";
    Restart = "always";
    RestartSec = 5;
    StandardInput = "null"; # no interactive console under systemd
    LoadCredential =
      lib.optional (cfg.database.passwordFile != "") "dbpass:${cfg.database.passwordFile}"
      ++ lib.optional (cfg.totpMasterSecretFile != "") "totp:${cfg.totpMasterSecretFile}";
    ExecStartPre = "+${preStart}";
    NoNewPrivileges = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    ReadWritePaths = [
      cfg.stateDir
      runDir
    ];
  };

  settingsType = lib.types.attrsOf (
    lib.types.oneOf [
      lib.types.str
      lib.types.int
    ]
  );
in
{
  options.services.azerothcore = {
    enable = lib.mkEnableOption "AzerothCore (Playerbot fork) with mod-playerbots";

    package = lib.mkOption {
      type = lib.types.package;
      default = acPkgs.azerothcore-playerbots;
      defaultText = lib.literalExpression "azerothcore-playerbots-nix.packages.\${system}.azerothcore-playerbots";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/azerothcore";
    };

    clientData = {
      enable = lib.mkEnableOption "the prebuilt client data package as dataDir";

      package = lib.mkOption {
        type = lib.types.package;
        default = acPkgs.wotlk-client-data;
        defaultText = lib.literalExpression "azerothcore-playerbots-nix.packages.\${system}.wotlk-client-data";
      };
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = if cfg.clientData.enable then "${cfg.clientData.package}" else "${cfg.stateDir}/data";
      defaultText = lib.literalExpression ''if clientData.enable then "''${clientData.package}" else "''${stateDir}/data"'';
      description = "dbc/maps/vmaps/mmaps: set clientData.enable or fill this dir with the extractors' output (enUS DBCs required).";
    };

    database = {
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3306;
      };
      socket = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = if cfg.database.createLocally then "/run/mysqld/mysqld.sock" else null;
        defaultText = lib.literalExpression ''if createLocally then "/run/mysqld/mysqld.sock" else null'';
        description = "Unix socket to connect through; overrides host/port. null = TCP.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "azerothcore";
        description = "MySQL user. With createLocally it is created with socket auth, so it must match the service user.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "File with the MySQL password (sops-nix/agenix). Empty = none, e.g. for socket auth.";
      };
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run MySQL 8.4 here.";
      };
    };

    totpMasterSecretFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "File with the TOTPMasterSecret for world- and authserver (sops-nix/agenix): 32 hex chars, e.g. from `openssl rand -hex 16`. Empty = unset.";
    };

    worldserver.settings = lib.mkOption {
      type = settingsType;
      default = { };
    };
    authserver.settings = lib.mkOption {
      type = settingsType;
      default = { };
    };
    moduleSettings = lib.mkOption {
      type = lib.types.attrsOf settingsType;
      default = { };
      example = lib.literalExpression ''{ "playerbots.conf"."AiPlayerbot.MaxRandomBots" = 500; }'';
      description = "Overrides per module config, keyed by file name under modules/ (the .conf.dist name without .dist). Every module config the package ships is rendered, with or without overrides.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.database.createLocally -> cfg.database.user == "azerothcore";
        message = "services.azerothcore.database.user must be \"azerothcore\" with createLocally: the local MySQL user is authenticated via auth_socket.";
      }
    ];

    users.users.azerothcore = {
      isSystemUser = true;
      group = "azerothcore";
      home = cfg.stateDir;
    };
    users.groups.azerothcore = { };

    # ---- defaults, all overridable via mkForce ----
    services.azerothcore.worldserver.settings = {
      DataDir = cfg.dataDir;
      LogsDir = "/var/log/azerothcore";
      "Console.Enable" = 0; # use RA/SOAP for GM commands
      "Ra.Enable" = 1;
      "Ra.IP" = "127.0.0.1";
      LoginDatabaseInfo = dbInfo "acore_auth";
      WorldDatabaseInfo = dbInfo "acore_world";
      CharacterDatabaseInfo = dbInfo "acore_characters";
      "Updates.EnableDatabases" = 7; # auto-updater populates all DBs
    }
    // totpSetting;
    services.azerothcore.authserver.settings = {
      LogsDir = "/var/log/azerothcore";
      LoginDatabaseInfo = dbInfo "acore_auth";
    }
    // totpSetting;
    services.azerothcore.moduleSettings."playerbots.conf" = {
      PlayerbotsDatabaseInfo = dbInfo "acore_playerbots";
    };

    # ---- MySQL 8.4 LTS ----
    services.mysql = lib.mkIf cfg.database.createLocally {
      enable = true;
      package = pkgs.mysql84;
      ensureDatabases = [
        "acore_auth"
        "acore_characters"
        "acore_world"
        "acore_playerbots"
      ];
      # Created as 'azerothcore'@'localhost' IDENTIFIED WITH auth_socket:
      # the services connect through the socket as unix user azerothcore.
      ensureUsers = [
        {
          name = cfg.database.user;
          ensurePermissions = {
            "acore_auth.*" = "ALL PRIVILEGES";
            "acore_characters.*" = "ALL PRIVILEGES";
            "acore_world.*" = "ALL PRIVILEGES";
            "acore_playerbots.*" = "ALL PRIVILEGES";
          };
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 azerothcore azerothcore -"
    ];

    systemd.services.ac-authserver = {
      description = "AzerothCore authserver";
      after = [
        "network.target"
        "mysql.service"
      ];
      requires = lib.optional cfg.database.createLocally "mysql.service";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = serviceCommon // {
        ExecStart = "${cfg.package}/bin/authserver -c ${runDir}/authserver.conf";
      };
    };

    systemd.services.ac-worldserver = {
      description = "AzerothCore worldserver (playerbots)";
      after = [
        "network.target"
        "mysql.service"
        "ac-authserver.service"
      ];
      requires = lib.optional cfg.database.createLocally "mysql.service";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = serviceCommon // {
        ExecStart = "${cfg.package}/bin/worldserver -c ${runDir}/worldserver.conf";
        TimeoutStopSec = 300; # world save on shutdown
        LimitNOFILE = 65536;
      };
    };

    networking.firewall.allowedTCPPorts = [
      3724
      8085
    ];
  };
}
