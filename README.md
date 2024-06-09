# 🕳️ tellaport

[Gluetun](https://github.com/qdm12/gluetun) is a VPN container client that works with a large number of VPN providers, and includes nice features such as built-in DNS across the VPN, VPN port-forwarding support for multiple VPN providers, and more.

This shell script is intended to automatically update LinuxServer.io torrent containers (_multiple clients available, see below_) based on the randomized port that Gluetun is given by your VPN provider.

&nbsp;

### 🤔 Do I need this?

If you're using Gluetun VPN, have port-forwarding working, and you're using one of the following LinuxServer.io torrent client containers:

* [Deluge](https://github.com/linuxserver/docker-deluge)
* [qBittorrent](https://github.com/linuxserver/docker-qbittorrent)
* [Transmission](https://github.com/linuxserver/docker-transmission)

Then this script might be for you.

&nbsp;

### 😌 Install / Use:

In order to use this script, you'll need to do two things:

1. Mount it into the `/custom-cont-init.d` folder.
2. Set environment variables or edit the script to set them.

Here is an example from [LinuxServer.io's qBittorrent container](https://github.com/linuxserver/docker-qbittorrent) README - note that more environment variables are available to set that are described below, and these can be hard-set in the script itself or set in the container environment as seen below:

#### Docker Compose:
```yaml
---
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: qbittorrent
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - WEBUI_PORT=8080
      - TORRENTING_PORT=6881
      # This MUST be set in-script or in-environment:
      - TELLAPORT_ENABLED="true"
      # These should be set if login is required:
      - TELLAPORT_USER="user"
      - TELLAPORT_PASS="pass"
      # If you're using HTTPS instead of HTTP:
      - TELLAPORT_PROTOCOL="http"
      # Other options are available - see below!
    volumes:
      - /path/to/qbittorrent/appdata:/config
      - /path/to/downloads:/downloads
      # Add the script as a volume into the /custom-cont-init.d folder:
      - /folder/tellaport.sh:/custom-cont-init.d/01-tellaport.sh:ro
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped
```

#### Command Line:
```bash
docker run -d \
  --name=qbittorrent \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Etc/UTC \
  -e WEBUI_PORT=8080 \
  -e TORRENTING_PORT=6881 \
  # This MUST be set in-script or in-environment:
  -e TELLAPORT_ENABLED="true" \
  # These should be set if login is required:
  -e TELLAPORT_USER="user" \
  -e TELLAPORT_PASS="pass" \
  # If you're using HTTPS instead of HTTP:
  -e TELLAPORT_PROTOCOL="http" \
  # Other options are available - see below!
  -p 8080:8080 \
  -p 6881:6881 \
  -p 6881:6881/udp \
  -v /path/to/qbittorrent/appdata:/config \
  -v /path/to/downloads:/downloads \
  # Add the script as a volume into the /custom-cont-init.d folder:
  -v /folder/tellaport.sh:/custom-cont-init.d/01-tellaport.sh:ro \
  --restart unless-stopped \
  lscr.io/linuxserver/qbittorrent:latest
```
&nbsp;

### 😎 Environment Variables / Options:
| ENV Var | Information |
|---|---|
|`TELLAPORT_ENABLED`|**`false`** / `true` - Whether or not to use TellAPort to update torrent client ports from Gluetun's forwarded port. **Script will not run if this isn't set to true.**|
|`TELLAPORT_TORRENT_CLIENT`|`deluge` / `qbittorrent` / `transmission` - Which torrent client is in use. Will try to auto-detect if this isn't set.|
|`TELLAPORT_USER` `TELLAPORT_PASS`|Only required if authentication is required for the torrent client. For qBittorrent if `127.0.0.1` is added to authentication bypass, these can be left blank.|
|`TELLAPORT_IP`| **`127.0.0.1`** is the default. This is the IP address you want the torrent client API to be accessed from - this only needs to be set if you've set the torrent API to be bound to an IP that isn't 127.0.0.1.|
|`TELLAPORT_PORT`| Web UI / API port for the torrent client - this will use the default ports when unset, or `WEBUI_PORT` if your container uses that environment variable. This is **not** the peer-listening port.|
|`TELLAPORT_PROTOCOL`|**`http`** / `https` - Protocol used for communicating to the torrent client, the torrent clients default to HTTP. Only change this if you know you're using HTTPS instead.|
|`TELLAPORT_TUN_IP`|IP address configured for the local tun0 / wg0 adapter, this is used to self-test if a port is able to listen on that specific IP. This can catch failing port bindings after VPN tunnel reconnection events, which is an issue that can affect Deluge and qBittorrent as of 2024-02-27. This attempts to auto-detect.|
|`TELLAPORT_DRY_RUN`|Install and run the script, but don't set the port and instead print the settings to console. **For testing.**|