#!/bin/bash

############
# SETTINGS #
############

# All variables can be set in the container environment for
# each container, or can be hard-set here.

# Whether or not to use TellAPort to update torrent
# client ports from Gluetun's forwarded port. Script will
# not run if this isn't set to true:
#TELLAPORT_ENABLED="true"

# Which torrent client is in use. Will try to auto-detect
# if one of the following accepted answers aren't seen:
# deluge / qbittorrent / transmission
#TELLAPORT_TORRENT_CLIENT=""

# Torrent client username / password - if 127.0.0.1 is
# added to authentication bypass, these can be left blank:
#TELLAPORT_USER=""
#TELLAPORT_PASS=""

# This is the IP address you want the torrent client API to
# be accessed from - this only needs to be set if you've set
# the UI / API to be bound only to specific IPs:
#TELLAPORT_IP="127.0.0.1"

# This is a "prefix" folder that shows up in the URL, which
# is sometimes used if you use a "subfolder" style of reverse
# proxy. An example of what this looks like in a full URL:
#     https://domain.com/qbittorrent/
# An example of setting this for the above example:
#     TELLAPORT_URL_BASE="/qbittorrent/"
# This defaults to "/" for every client EXCEPT Transmission,
# which defaults to "/transmission/". If you have explicitly
# disabled the default subfolder URL for Transmission, you
# MUST set this to "/":
# TELLAPORT_URL_BASE="/"

# Web UI / API port for the torrent client - this will use
# the default ports when unset, or WEBUI_PORT if your
# container uses that environment variable. This is NOT the
# peer-listening port:
#TELLAPORT_PORT=""

# Protocol used for communicating to qBittorrent - this can
# be set to "http" or "https", and the default is http:
#TELLAPORT_PROTOCOL="http"

# IP address configured for the local tun0 / wg0 adapter,
# this is used to self-test if a port is able to listen
# on that specific IP. This can catch failing port bindings
# after VPN tunnel reconnection events, which is an issue
# that can affect Deluge and qBittorrent as of 2024-02-27:
#TELLAPORT_TUN_IP="10.2.0.2"

# Install and run the script, but don't set the port and
# print the settings to console. For testing:
#TELLAPORT_DRY_RUN="false"

##############
# PRE-CHECKS #
##############

# Check if the user wants to update ports from Gluetun, exit if not:
if ! [ "$TELLAPORT_ENABLED" = "true" ]; then
  echo "TellAPort: Environment variable TELLAPORT_ENABLED is not set to true, exiting script with no changes."
  exit 0
fi

# Check if curl is installed - if not, install it:
if ! which curl &> /dev/null; then
  echo "TellAPort: curl utility was not found, attempting to install..."
  apk add --no-cache curl
fi

# Check if jq is installed - if not, install it:
if ! which jq &> /dev/null; then
  echo "TellAPort: jq utility was not found, attempting to install..."
  apk add --no-cache jq
fi

# Check if nc is installed - if not, install it:
if ! which nc &> /dev/null; then
  echo "TellAPort: nc utility was not found, attempting to install..."
  apk add --no-cache netcat-openbsd
fi

# Wait for the Gluetun API to become available before proceeding:
until nc -zvw10 127.0.0.1 8000 &> /dev/null;
do
  sleep 1;
done;



##################
# INITIALIZATION #
##################

# If the script doesn't exist in the /etc/periodic/1min/ folder,
# run the initial install process:
if [ ! -f /etc/periodic/1min/tellaport.sh ]; then

  # Check if /etc/periodic/1min/ exists - if not, create it:
  if [ ! -d /etc/periodic/1min ]; then
    mkdir -p /etc/periodic/1min
  fi

  # Copy tellaport.sh into place:
  cp -af /custom-cont-init.d/tellaport.sh /etc/periodic/1min/
  chmod +x /etc/periodic/1min/tellaport.sh

  # Add the crontab entry to run the script every minute:
  if ! cat /etc/crontabs/root | grep -q "/etc/periodic/1min"; then
    echo "*       *       *       *       *       run-parts /etc/periodic/1min" >> /etc/crontabs/root
  fi

  echo "TellAPort: Initial script installation completed, script will run per-minute."
  exit 0
fi

# Check if TELLAPORT_TORRENT_CLIENT is set, and auto-detect the
# client if it's not set:
if [ "${TELLAPORT_TORRENT_CLIENT}" = "deluge" ] \
   || [ "${TELLAPORT_TORRENT_CLIENT}" = "qbittorrent" ] \
   || [ "${TELLAPORT_TORRENT_CLIENT}" = "transmission" ]; then
  torrentClient="${TELLAPORT_TORRENT_CLIENT}"
else
  if which deluge &> /dev/null; then
    torrentClient="deluge"
  elif which qbittorrent-nox &> /dev/null; then
    torrentClient="qbittorrent"
  elif which transmission-remote &> /dev/null; then
    torrentClient="transmission"
  else
    echo "TellAPort: Unable to automatically detect the torrent client in use. Please set TELLAPORT_TORRENT_CLIENT to deluge, qbittorrent, or transmission."
    exit 1
  fi
fi

# Set user:
torrentApiUser=${TELLAPORT_USER:-}

# Set pass:
torrentApiPass=${TELLAPORT_PASS:-}

# Set the base URL folder for the torrent API:
if ! [ -z "${TELLAPORT_URL_BASE}" ] 2> /dev/null; then
  torrentApiUrlBase="${TELLAPORT_URL_BASE}"
  # Check for missing leading slash:
  if ! [[ "${torrentApiUrlBase}" =~ ^/.*$ ]] 2> /dev/null; then
    torrentApiUrlBase="/${torrentApiUrlBase}"
  fi
  # Check for missing trailing slash:
  if ! [[ "${torrentApiUrlBase}" =~ ^.*/$ ]] 2> /dev/null; then
    torrentApiUrlBase="${torrentApiUrlBase}/"
  fi
else
  # Defaults in case it's not set:
  case $torrentClient in
  deluge) torrentApiUrlBase="/";;
  qbittorrent) torrentApiUrlBase="/";;
  transmission) torrentApiUrlBase="/transmission/";;
  *)
    echo "TellAPort: Unable to set the torrent client API URL base automatically, please set TELLAPORT_URL_BASE."
    exit 1
  ;;
  esac
fi

# Set the torrent client API port:
if ! [ -z "${TELLAPORT_PORT}" ] \
   && [ "${TELLAPORT_PORT}" -eq "${TELLAPORT_PORT}" ] 2> /dev/null; then
  torrentApiPort="${TELLAPORT_PORT}"
elif ! [ -z "${WEBUI_PORT}" ] \
     && [ "${WEBUI_PORT}" -eq "${WEBUI_PORT}" ] 2> /dev/null; then
      torrentApiPort="${WEBUI_PORT}"
else
  case $torrentClient in
  deluge) torrentApiPort="8112";;
  qbittorrent) torrentApiPort="8080";;
  transmission) torrentApiPort="9091";;
  *)
    echo "TellAPort: Unable to set the torrent client API port automatically, please set TELLAPORT_PORT."
    exit 1
  ;;
  esac
fi

# Set the torrent client API protocol:
if [ "${TELLAPORT_PROTOCOL}" = "http" ] \
   || [ "${TELLAPORT_PROTOCOL}" = "https" ]; then
  torrentApiProtocol="${TELLAPORT_PROTOCOL}"
else
  torrentApiProtocol="http"
fi

# Set the torrent client API IP address:
if [[ "${TELLAPORT_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  torrentApiIpAddress="${TELLAPORT_TORRENT_CLIENT}"
else
  torrentApiIpAddress="127.0.0.1"
fi

# Set the VPN tunnel adapter IP address:
vpnAdapterIpAddress=$(ip a s $(curl -fs http://127.0.0.1:8000/v1/openvpn/settings \
    | jq -r .interface) \
    | awk '/inet / {print $2}' \
    | cut -d "/" -f 1)



##########
# SCRIPT #
##########

# Attempt to connect to the Gluetun API and confirm the current forwarded port:
forwardedPort=$(curl -fs http://127.0.0.1:8000/v1/openvpn/portforwarded \
    | jq -r .port)

# Confirm the Gluetun port result is an integer:
if [ "$forwardedPort" -ne "$forwardedPort" ] 2> /dev/null; then
  echo "TellAPort: Failed to get a Gluetun forwarded port - is the Gluetun API accessible at 127.0.0.1:8000?"
  exit 1
fi

# Confirm the Gluetun port isn't 0:
if [ "$forwardedport" -eq 0 ] 2> /dev/null; then
  echo "TellAPort: Gluetun VPN port is currently 0, waiting for it to update to a non-zero port number..."
  until ! [ "$forwardedport" -eq 0 ]
  do
  sleep 10
  forwardedPort=$(curl -fs http://127.0.0.1:8000/v1/openvpn/portforwarded \
      | jq -r .port)
  done
fi

# Obtain API login cookies for Deluge or qBittorrent clients:
case $torrentClient in
deluge)
  if ! curl -c /tmp/torrentApiCookie -fks \
        --header "Content-Type: application/json" \
        --data "{\"method\": \"auth.login\", \"params\": [\"${torrentApiPass}\"], \"id\": 1}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json" &> /dev/null; then
    echo "TellAPort: Failed to get Deluge cookie, is the torrent client information correct?"
    echo "Torrent client detected: ${torrentClient}"
    echo "User: ${torrentApiUser}"
    # echo "Pass: ${torrentApiPass}"
    echo "Protocol: ${torrentApiProtocol}"
    echo "IP Address: ${torrentApiIpAddress}"
    echo "Port: ${torrentApiPort}"
    echo "URL Base: ${torrentApiUrlBase}"
    echo "Contents of /tmp/torrentApiCookie file:"
    cat /tmp/torrentApiCookie
    exit 1
  fi
;;
qbittorrent)
  if ! curl -c /tmp/torrentApiCookie -fks \
        --data "username=${torrentApiUser}" \
        --data-urlencode "password=${torrentApiPass}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/auth/login" &> /dev/null; then
    echo "TellAPort: Failed to get qBittorrent cookie, is the torrent client information correct?"
    echo "Torrent client detected: ${torrentClient}"
    echo "User: ${torrentApiUser}"
    # echo "Pass: ${torrentApiPass}"
    echo "Protocol: ${torrentApiProtocol}"
    echo "IP Address: ${torrentApiIpAddress}"
    echo "Port: ${torrentApiPort}"
    echo "URL Base: ${torrentApiUrlBase}"
    echo "Contents of /tmp/torrentApiCookie file:"
    cat /tmp/torrentApiCookie
    exit 1
  fi
;;
transmission)
  transmissionSessionId=$(curl -u "${torrentApiUser}:${torrentApiPass}" -fvks \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}rpc" 2>&1 \
      | awk '/X-Transmission-Session-Id:/ { print $3 }')
  
  if ! [[ ${transmissionSessionId} =~ ^[[:alnum:]]{48}$ ]]; then
    echo "TellAPort: Failed to get Transmission session ID, is the torrent client information correct?"
    echo "Torrent client detected: ${torrentClient}"
    echo "User: ${torrentApiUser}"
    # echo "Pass: ${torrentApiPass}"
    echo "Protocol: ${torrentApiProtocol}"
    echo "IP Address: ${torrentApiIpAddress}"
    echo "Port: ${torrentApiPort}"
    echo "URL Base: ${torrentApiUrlBase}"
    echo "Transmission Session ID: ${transmissionSessionId}"
    exit 1
  fi
;;
esac

# Attempt to obtain the current torrent client listening port:
case $torrentClient in
deluge)
  listeningPort=$(curl -b /tmp/torrentApiCookie -fks \
      --header "Content-Type: application/json" \
      --data "{\"method\": \"core.get_config\", \"params\": \"\", \"id\": 1}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json" \
      | jq -r .result.listen_ports[0])
;;
qbittorrent)
  listeningPort=$(curl -b /tmp/torrentApiCookie -fks \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/app/preferences" \
      | jq -r .listen_port)
;;
transmission)
  listeningPort=$(curl -u "${torrentApiUser}:${torrentApiPass}" -fks \
      --header "Content-Type: application/json" \
      --header "x-transmission-session-id: ${transmissionSessionId}" \
      --data '{"method":"session-get"}' \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}rpc" \
      | jq -r .arguments.[\"peer-port\"])
;;
esac

# Confirm the listening port result is an integer:
if [ "$forwardedPort" -ne "$forwardedPort" ] 2> /dev/null && ! [ -z "$forwardedPort" ] 2> /dev/null; then
  echo "TellAPort: Failed to get the current torrent client listening port, is the torrent client information correct? (Protocol, password, port, etc.)"
  exit 1
fi

# If TELLAPORT_DRY_RUN has been enabled, report the port information and exit:
if [ "${TELLAPORT_DRY_RUN}" = "true" ]; then
  echo "TellAPort: Dry Run Results:"
  echo "Torrent client detected: ${torrentClient}"
  echo "User: ${torrentApiUser}"
  # echo "Pass: ${torrentApiPass}"
  echo "Protocol: ${torrentApiProtocol}"
  echo "IP Address: ${torrentApiIpAddress}"
  echo "Port: ${torrentApiPort}"
  echo "URL Base: ${torrentApiUrlBase}"
  echo "Torrent client listening port: ${listeningPort}"
  echo "Gluetun forwarded port: ${forwardedPort}"
  exit 0
fi

# Check if the ports match - if they don't match, update the port:
if [ ${forwardedPort} -ne ${listeningPort} ] 2> /dev/null; then
  echo "TellAPort: Updating torrent client listening port ${listeningPort} to new forwarded port ${forwardedPort}"
  case $torrentClient in
  deluge)
    curl -b /tmp/torrentApiCookie -fks \
      --header "Content-Type: application/json" \
      --data "{\"method\": \"core.set_config\", \"params\": [{\"random_port\": false}], \"id\": 1}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json"
    curl -b /tmp/torrentApiCookie -fks \
      --header "Content-Type: application/json" \
      --data "{\"method\": \"core.set_config\", \"params\": [{\"listen_ports\": [${forwardedPort},${forwardedPort}]}], \"id\": 1}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json"
  ;;
  qbittorrent)
    curl -b /tmp/torrentApiCookie -fks \
      --data-urlencode "json={\"listen_port\":${forwardedPort},\"random_port\":false,\"upnp\":false}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/app/setPreferences"
  ;;
  transmission)
    curl -u "${torrentApiUser}:${torrentApiPass}" -fks \
      --header "Content-Type: application/json" \
      --header "x-transmission-session-id: ${transmissionSessionId}" \
      --data "{\"method\":\"session-set\",\"arguments\":{\"peer-port\":${forwardedPort},\"peer-port-random-on-start\":false,\"port-forwarding-enabled\": true}}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}rpc"
  ;;
  esac
fi

# After the port has been updated, test the port with nc:
if nc -zvw10 ${vpnAdapterIpAddress} ${forwardedPort} &> /dev/null; then
  exit 0
else
  echo "TellAPort: WARNING: Torrent client (${torrentClient}) listening port didn't respond on VPN adapter IP ${vpnAdapterIpAddress}:${forwardedPort}"
  
  case $torrentClient in
  deluge)
    echo "TellAPort: Attempting to toggle listening IP address to potentially work around issue."

    # Get the current torrent client listening IP:
    currentListeningIpAddress=$(curl -b /tmp/torrentApiCookie -fks \
      --header "Content-Type: application/json" \
      --data "{\"method\": \"core.get_config\", \"params\": \"\", \"id\": 1}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json" \
      | jq -r .result.listen_interface)

    # Set the listening IP to something else:
    if [ ${currentListeningIpAddress} =  "0.0.0.0" ]; then
      curl -b /tmp/torrentApiCookie -fks \
        --header "Content-Type: application/json" \
        --data "{\"method\": \"core.set_config\", \"params\": [{\"listen_interface\": \"${vpnAdapterIpAddress}\"}], \"id\": 1}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json"
    else
      curl -b /tmp/torrentApiCookie -fks \
        --header "Content-Type: application/json" \
        --data "{\"method\": \"core.set_config\", \"params\": [{\"listen_interface\": \"0.0.0.0\"}], \"id\": 1}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json"
    fi
    
    sleep 1

    # Set the listening IP back:
    curl -b /tmp/torrentApiCookie -fks \
      --header "Content-Type: application/json" \
      --data "{\"method\": \"core.set_config\", \"params\": [{\"listen_interface\": \"${currentListeningIpAddress}\"}], \"id\": 1}" \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}json"
  ;;
  qbittorrent)
    echo "TellAPort: Attempting to toggle listening IP address to work around issue."

    # Get the current torrent client listening IP:
    currentListeningIpAddress=$(curl -b /tmp/torrentApiCookie -fks \
      "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/app/preferences" \
      | jq -r .current_interface_address)

    # Set the listening IP to something else:
    if [ ${currentListeningIpAddress} =  "0.0.0.0" ]; then
      curl -b /tmp/torrentApiCookie -fks \
        --data-urlencode "json={\"current_interface_address\":\"${vpnAdapterIpAddress}\"}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/app/setPreferences"
    else
      curl -b /tmp/torrentApiCookie -fks \
        --data-urlencode "json={\"current_interface_address\":\"0.0.0.0\"}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/app/setPreferences"
    fi
    
    sleep 1

    # Set the listening IP back:
    curl -b /tmp/torrentApiCookie -fks \
        --data-urlencode "json={\"current_interface_address\":\"${currentListeningIpAddress}\"}" \
        "${torrentApiProtocol}://${torrentApiIpAddress}:${torrentApiPort}${torrentApiUrlBase}api/v2/app/setPreferences"
  ;;
  transmission)
    # It appears Transmission cannot change the listening address live, so we exit here:
    exit 0
  ;;
  esac

  # Test port again:
  sleep 5
  if nc -zvw10 ${vpnAdapterIpAddress} ${forwardedPort} &> /dev/null; then
    echo "TellAPort: ${vpnAdapterIpAddress}:${forwardedPort} is now responding to network requests."
    exit 0
  else
    echo "TellAPort: ${vpnAdapterIpAddress}:${forwardedPort} is still not responding to network requests, please investigate."
    exit 1
  fi
fi
