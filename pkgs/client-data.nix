{ fetchzip }:

fetchzip {
  name = "wotlk-client-data";
  url = "https://github.com/wowgaming/client-data/releases/download/v20.0/Data.zip";
  hash = "sha256-xZJvdDNyV0gv7mbFhutLSbETqEWPUlcBgPnB44eCbuA=";
  stripRoot = false;
}
