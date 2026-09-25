# Reference: https://www.azerothcore.org/wiki/linux-core-installation
{
  lib,
  llvmPackages, # wiki recommends clang; swap for `stdenv` for gcc
  cmake,
  ninja,
  pkg-config,
  git,
  boost183, # wiki: Boost >= 1.74; 1.87+ reported problematic
  openssl, # >= 3.0
  # libmysqlclient is an alias for the mariadb-client, but this project requires the real mysql client libaray.
  mysql84,
  readline,
  ncurses,
  bzip2,
  zlib,
  src,
  version,
  modules ? { },
  # Where the servers look for modules/*.conf at runtime (and for the default -c).
  # Must be writable config, not the store; matches the NixOS module's runDir.
  runtimeConfDir ? "/run/azerothcore",
}:

llvmPackages.stdenv.mkDerivation (finalAttrs: {
  pname = "azerothcore-playerbots";
  inherit version src;

  # AC's CMake globs modules/*; store paths are read-only -> copy, don't symlink.
  postUnpack = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: modSrc: ''
      cp -r ${modSrc} "$sourceRoot/modules/${name}"
      chmod -R u+w "$sourceRoot/modules/${name}"
    '') modules
  );

  postPatch = ''
    # The DB auto-updater locates data/sql via the source directory baked in
    # at configure time. In the sandbox that is /build/source, which does not
    # exist at runtime -> point it at what we install under $out/share.
    substituteInPlace src/cmake/revision.h.in.cmake \
      --replace-fail '@CMAKE_SOURCE_DIR@' "${placeholder "out"}/share/azerothcore"

    # Module configs are read from <_CONF_DIR>/modules/, independent of -c.
    # _CONF_DIR defaults to $out/etc (install target, read-only) -> decouple
    # the runtime lookup path from where the .dist files get installed.
    substituteInPlace src/cmake/showoptions.cmake \
      --replace-fail 'add_definitions(-D_CONF_DIR=$<1:"''${CONF_DIR}">)' \
                     'add_definitions(-D_CONF_DIR=$<1:"${runtimeConfDir}">)'
  '';

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    git
  ];
  buildInputs = [
    boost183
    openssl
    mysql84
    readline
    ncurses
    bzip2
    zlib
  ];

  cmakeFlags = [
    "-DCMAKE_BUILD_TYPE=RelWithDebInfo"
    "-DTOOLS_BUILD=all" # extractors, needed once for client data
    "-DSCRIPTS=static"
    "-DMODULES=static"
    "-DWITH_WARNINGS=0" # playerbots fork is very noisy otherwise
    "-DWITH_COREDEBUG=0"
    # If FindMySQL does not pick up mariadb-connector-c:
    # "-DMYSQL_INCLUDE_DIR=${lib.getDev libmysqlclient}/include/mysql"
    # "-DMYSQL_LIBRARY=${lib.getLib libmysqlclient}/lib/mariadb/libmysqlclient.so"
  ];

  enableParallelBuilding = true;

  # `make install` ships binaries + *.conf.dist but not the SQL.
  # Ship core SQL and every module's SQL so the auto-updater finds them.
  postInstall = ''
    mkdir -p $out/share/azerothcore/modules
    cp -r ../data $out/share/azerothcore/data
    for m in ../modules/*/; do
      n=$(basename "$m")
      [ -d "$m/data/sql" ] && mkdir -p $out/share/azerothcore/modules/$n/data \
        && cp -r "$m/data/sql" $out/share/azerothcore/modules/$n/data/sql
    done
  '';

  meta = {
    description = "AzerothCore WotLK server (Playerbot fork) with mod-playerbots";
    homepage = "https://github.com/mod-playerbots/mod-playerbots";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "worldserver";
  };
})
