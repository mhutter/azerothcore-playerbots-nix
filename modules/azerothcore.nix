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

  # Runtime config = <pkg>/etc/*.conf.dist (loaded first) + our overrides.
  # Passwords never hit the store: @DB_PASSWORD@ is substituted in preStart.
  worldConf = pkgs.writeText "worldserver.conf" (toConf cfg.worldserver.settings);
  authConf = pkgs.writeText "authserver.conf" (toConf cfg.authserver.settings);
  botsConf = pkgs.writeText "playerbots.conf" (toConf cfg.playerbots.settings);

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
    for f in worldserver authserver; do
      ln -sfn ${cfg.package}/etc/$f.conf.dist ${runDir}/$f.conf.dist
    done
    ln -sfn ${cfg.package}/etc/modules/playerbots.conf.dist ${runDir}/modules/playerbots.conf.dist
    sed "s|@DB_PASSWORD@|$pw|g" ${worldConf} > ${runDir}/worldserver.conf
    sed "s|@DB_PASSWORD@|$pw|g" ${authConf}  > ${runDir}/authserver.conf
    cp ${botsConf} ${runDir}/modules/playerbots.conf
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

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.stateDir}/data";
      description = "dbc/maps/vmaps/mmaps: the flake's client-data package or a dir filled by the extractors (enUS DBCs required).";
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
    playerbots.settings = lib.mkOption {
      type = settingsType;
      default = { };
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
    services.azerothcore.playerbots.settings = {
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
