#!/bin/bash
##Script to setup FalcoSidekick to forward Falco Metrics to Prometheus Agents
## run as sudo ./falco_sidekick_setup.sh

if [[ $EUID -ne 0 ]]; then
    echo "$0 is not running as root. Try using sudo."
    exit 2
fi


VER=$(curl --silent -qI https://github.com/falcosecurity/falcosidekick/releases/latest | awk -F '/' '/^location/ {print  substr($NF, 1, length($NF)-1)}')
wget -c https://github.com/falcosecurity/falcosidekick/releases/download/${VER}/falcosidekick_${VER}_linux_arm64.tar.gz -O - | tar -xz
or
wget -c https://github.com/falcosecurity/falcosidekick/releases/download/${VER}/falcosidekick_${VER}_linux_amd64.tar.gz -O - | tar -xz
chmod +x falcosidekick
mv falcosidekick /usr/local/bin/

## Setup config file in /etc/falcosidekick/config.yaml

cat > /etc/falcosidekick/config.yaml << 'EOF'
#listenaddress: "" # ip address to bind falcosidekick to (default: "" meaning all addresses)
#listenport: 2801 # port to listen for daemon (default: 2801)
debug: false # if true all outputs will print in stdout the payload they send (default: false)
customfields: # custom fields are added to falco events, if the value starts with % the relative env var is used
  # Akey: "AValue"
  # Bkey: "BValue"
  # Ckey: "CValue"
templatedfields: # templated fields are added to falco events and metrics, it uses Go template + output_fields values
  # Dkey: '{{ or (index . "k8s.ns.labels.foo") "bar" }}'
customtags: # custom tags are added to the falco events, if the value starts with % the relative env var is used
  # - tagA
  # - tagB
# bracketreplacer: "_" # if not empty, replace the brackets in keys of Output Fields
outputFieldFormat: "<timestamp>: <priority> <output> <custom_fields> <templated_fields>" # if not empty, allow to change the format of the output field. (default: "<timestamp>: <priority> <output>")
mutualtlsfilespath: "/etc/certs" # folder which will used to store client.crt, client.key and ca.crt files for mutual tls for outputs, will be deprecated in the future (default: "/etc/certs")
mutualtlsclient: # takes priority over mutualtlsfilespath if not emtpy
  certfile: "/etc/certs/client/client.crt" # client certification file
  keyfile: "/etc/certs/client/client.key" # client key
  cacertfile: "/etc/certs/client/ca.crt" # for server certification
tlsclient:
  cacertfile: "/etc/certs/client/ca.crt" # CA certificate file for server certification on TLS connections, appended to the system CA pool if not empty
tlsserver:
  deploy: false # if true, TLS server will be deployed instead of HTTP
  certfile: "/etc/certs/server/server.crt" # server certification file
  keyfile: "/etc/certs/server/server.key" # server key
  mutualtls: false # if true, mTLS server will be deployed instead of TLS, deploy also has to be true
  cacertfile: "/etc/certs/server/ca.crt" # for client certification if mutualtls is true
  notlsport: 2810 # port to serve http server serving selected endpoints (default: 2810)
  notlspaths: # if not empty, and tlsserver.deploy is true, a separate http server will be deployed for the specified endpoints
    - "/ping"
    # - "/metrics"
    # - "/healthz"
EOF

touch /etc/systemd/system/falcosidekick.service
chmod 664 /etc/systemd/system/falcosidekick.service
cat > /etc/systemd/system/falcosidekick.service << 'EOF'
[Unit]
Description=Falcosidekick
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=1
ExecStart=/usr/local/bin/falcosidekick -c /etc/falcosidekick/config.yaml

[Install]
WantedBy=default.target
EOF

systemctl daemon-reload
systemctl enable falcosidekick
systemctl start falcosidekick
curl localhost:2801/healthz
