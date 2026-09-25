# azerothcore-playerbots-nix

Nix packaging and a NixOS module for the
[AzerothCore Playerbot fork](https://github.com/mod-playerbots/azerothcore-wotlk)
with [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots).

Flake outputs (`x86_64-linux` only):

| Output                            | Description                                |
| --------------------------------- | ------------------------------------------ |
| `packages.azerothcore-playerbots` | `worldserver`, `authserver`, `.conf.dist`s |
| `packages.wotlk-client-data`      | Prebuilt dbc/maps/vmaps/mmaps (WotLK)      |
| `overlays.default`                | Adds both packages to `pkgs`               |
| `nixosModules.default`            | `services.azerothcore`                     |

## NixOS module

### Minimal setup

```nix
# flake.nix
{
  inputs.azerothcore.url = "github:mhutter/azerothcore-playerbots-nix";

  outputs = { nixpkgs, azerothcore, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        azerothcore.nixosModules.default
        {
          services.azerothcore = {
            enable = true;
            clientData.enable = true;
          };
        }
      ];
    };
  };
}
```

The module builds the server with your system's `pkgs`; no overlay needed.
`overlays.default` is only useful if you want the packages in `pkgs` yourself.

This gives you:

- `ac-authserver.service` and `ac-worldserver.service`, running as user
  `azerothcore`
- A local MySQL 8.4 with databases `acore_auth`, `acore_characters`,
  `acore_world` and `acore_playerbots`, tuned as recommended by the
  mod-playerbots wiki
- TCP ports 3724 (auth) and 8085 (world) opened in the firewall
- Database schemas created and updated automatically by the worldserver on start
  (`Updates.EnableDatabases = 7`)

### Database

With `database.createLocally = true` (default), the servers connect through the
MySQL unix socket as user `azerothcore`, authenticated via `auth_socket`. No
password needed; the user and its grants are created by the module.

To use an external MySQL instead:

```nix
services.azerothcore.database = {
  createLocally = false;
  host = "db.example.com";
  user = "acore";
  passwordFile = "/run/secrets/azerothcore-db"; # sops-nix, agenix, ...
};
```

The user needs all privileges on `acore_auth`, `acore_characters`,
`acore_world` and `acore_playerbots`. The password is substituted into the
config at service start and never ends up in the Nix store. It must not contain
`|`, `&` or `\` (it is inserted via `sed`).

### Client data

The worldserver needs `dbc`, `maps`, `vmaps` and `mmaps` (enUS DBCs). Either:

- use the prebuilt package:
  `clientData.enable = true;` (sets `dataDir` to it)
- or keep the default (`/var/lib/azerothcore/data`) and fill it with the output
  of the AzerothCore extractors.

### Configuration

Settings are rendered into `worldserver.conf`, `authserver.conf` and
`modules/playerbots.conf` under `/run/azerothcore`. The packaged `.conf.dist`
files are loaded first, so you only need to set what differs from upstream
defaults. Keys are the upstream config keys, values are strings or integers:

```nix
services.azerothcore = {
  worldserver.settings = {
    "MapUpdate.Threads" = 6; # wiki: cores - 2, never more than 8
    "GameType" = 0;
    "Rate.XP.Kill" = 2;
  };
  authserver.settings = {
    "RealmServerPort" = 3724;
  };
  playerbots.settings = {
    "AiPlayerbot.MinRandomBots" = 200;
    "AiPlayerbot.MaxRandomBots" = 500;
  };
};
```

Module defaults (paths, database connection strings, `Console.Enable = 0`,
`Ra.Enable = 1` on `127.0.0.1`, `MapUpdate.Threads = 4`, ...) can be overridden
with `lib.mkForce`:

```nix
services.azerothcore.worldserver.settings."Ra.IP" = lib.mkForce "0.0.0.0";
```

### GM commands

The worldserver has no interactive console under systemd. Use Remote Access
(RA, telnet on `127.0.0.1:3443` by default) with a GM account instead. See the
[GM command reference](https://www.azerothcore.org/wiki/gm-commands).

#### Initial admin account

RA needs a GM account, so the first one has to be created on the console:

1. Enable the console and roll out the change (`nixos-rebuild switch`):

   ```nix
   services.azerothcore.worldserver.settings."Console.Enable" = lib.mkForce 1;
   ```

2. Stop the service and start the worldserver manually in the foreground, with
   the same user, working directory and config as the unit:

   ```sh
   sudo systemctl stop ac-worldserver
   cmd=$(systemctl cat ac-worldserver | sed -n 's/^ExecStart=//p')
   sudo -u azerothcore sh -c "cd /var/lib/azerothcore && exec $cmd"
   ```

3. Once the `AC>` prompt appears, create the account and make it an
   administrator (level 3) on all realms (`-1`):

   ```
   account create admin <password>
   account set gmlevel admin 3 -1
   server exit
   ```

4. Remove the `Console.Enable` override and roll out again. This changes the
   unit, so the worldserver is started again; if not,
   `sudo systemctl start ac-worldserver`.

### Remote clients

Clients get the world server address from the `realmlist` table. For
connections from other hosts, update it once:

```sql
UPDATE acore_auth.realmlist SET address = '<public ip or hostname>' WHERE id = 1;
```

### Options

| Option                    | Default                                                   | Description                                             |
| ------------------------- | --------------------------------------------------------- | ------------------------------------------------------- |
| `enable`                  | `false`                                                   | Enable the auth- and worldserver                        |
| `package`                 | `azerothcore-playerbots` from this flake                  | Server package                                          |
| `stateDir`                | `/var/lib/azerothcore`                                    | Working directory, logs in `<stateDir>/logs`            |
| `clientData.enable`       | `false`                                                   | Use the prebuilt client data as `dataDir`               |
| `clientData.package`      | `wotlk-client-data` from this flake                       | Client data package                                     |
| `dataDir`                 | `clientData.package` if enabled, else `<stateDir>/data`   | Client data (dbc/maps/vmaps/mmaps)                      |
| `database.host`           | `127.0.0.1`                                               | MySQL host (TCP)                                        |
| `database.port`           | `3306`                                                    | MySQL port (TCP)                                        |
| `database.socket`         | `/run/mysqld/mysqld.sock` if `createLocally`, else `null` | Unix socket; overrides host/port                        |
| `database.user`           | `azerothcore`                                             | MySQL user                                              |
| `database.passwordFile`   | `""`                                                      | File containing the MySQL password; empty = no password |
| `database.createLocally`  | `true`                                                    | Run and tune a local MySQL 8.4                          |
| `database.bufferPoolSize` | `4G`                                                      | `innodb_buffer_pool_size` of the local MySQL            |
| `worldserver.settings`    | `{ }`                                                     | Overrides for `worldserver.conf`                        |
| `authserver.settings`     | `{ }`                                                     | Overrides for `authserver.conf`                         |
| `playerbots.settings`     | `{ }`                                                     | Overrides for `modules/playerbots.conf`                 |
