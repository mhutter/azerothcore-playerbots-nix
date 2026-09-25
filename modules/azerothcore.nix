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
  # <pkg>/etc/*.conf.dist with our overrides appended (the last duplicate key wins).
  # Passwords never hit the store: @DB_PASSWORD@ is substituted in preStart.
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

  preStart = pkgs.writeShellScript "azerothcore-render-conf" ''
    set -eu
    pw=""
    [ -n "${cfg.database.passwordFile}" ] && pw=$(cat "$CREDENTIALS_DIRECTORY/dbpass")
    mkdir -p ${runDir}/modules
    render() { cat "$1" - "$2" <<< "" | sed "s|@DB_PASSWORD@|$pw|g" > "$3"; }
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
    Restart = "always";
    RestartSec = 5;
    StandardInput = "null"; # no interactive console under systemd
    LoadCredential = lib.optional (
      cfg.database.passwordFile != ""
    ) "dbpass:${cfg.database.passwordFile}";
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
        description = "Run MySQL 8.4 here with the playerbots wiki tuning.";
      };
      bufferPoolSize = lib.mkOption {
        type = lib.types.str;
        default = "4G";
      };
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
      LogsDir = "${cfg.stateDir}/logs";
      "Console.Enable" = 0; # use RA/SOAP for GM commands
      "Ra.Enable" = 1;
      "Ra.IP" = "127.0.0.1";
      "MapUpdate.Threads" = 4; # wiki: cores-2, never >8
      LoginDatabaseInfo = dbInfo "acore_auth";
      WorldDatabaseInfo = dbInfo "acore_world";
      CharacterDatabaseInfo = dbInfo "acore_characters";
      "Updates.EnableDatabases" = 7; # auto-updater populates all DBs
    };
    services.azerothcore.authserver.settings = {
      LogsDir = "${cfg.stateDir}/logs";
      LoginDatabaseInfo = dbInfo "acore_auth";
    };
    services.azerothcore.moduleSettings."playerbots.conf" = {
      PlayerbotsDatabaseInfo = dbInfo "acore_playerbots";
    };

    # ---- MySQL 8.4 LTS with the wiki's tuning ----
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
      settings.mysqld = {
        skip-log-bin = true;
        innodb_buffer_pool_size = cfg.database.bufferPoolSize;
        innodb_io_capacity = 500;
        innodb_io_capacity_max = 2500;
        transaction_isolation = "READ-COMMITTED";
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 azerothcore azerothcore -"
      "d ${cfg.stateDir}/logs 0750 azerothcore azerothcore -"
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
