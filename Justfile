host := "rhea"
port := "50642"
remote_dir := "/nix/persist/home/mh/wow"

# List available recipes
default:
    @just --list

# Copy this repo to the host — uncommitted changes included, .git excluded
sync:
    rsync -a --delete -e 'ssh -p {{ port }}' \
      --exclude .direnv --exclude .env \
      {{ justfile_directory() }}/ {{ host }}:{{ remote_dir }}/

# Build a package
build pkg="default": (nix-build pkg)

# Everything runs on the host: `nixos-rebuild --build-host/--target-host` would
# evaluate the flake locally and only copy the derivations over.
[private]
nix-build pkg: sync
    ssh -t -p {{ port }} {{ host }} 'nix build -L {{ remote_dir }}#{{ pkg }} --option abort-on-warn true --show-trace'
