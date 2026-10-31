#!/bin/bash
set +x
set -euo pipefail
umask 077
# Public defaults. Leave credentials blank when publishing to GitHub.
# For EC2 User Data, fill these values in your PRIVATE copy before launch.
# DNSPod account: fanchuniceboy@gmail.com (API uses SecretId/SecretKey).
DNSPOD_SECRET_ID=IKIDS6mNsQn14wjMmy03tVu77ye9SaO6cuzq
DNSPOD_SECRET_KEY=lKH7mHZgaJrBJNH2fppeIk06ziJjyzqj
DNSPOD_DOMAIN=nianjiushiwodewenti.com
DNSPOD_SUBDOMAIN=aws6

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo 'Usage: sudo bash dnspod-ddns-v6.sh'
  echo 'Environment: DNSPOD_SECRET_ID, DNSPOD_SECRET_KEY, DNSPOD_DOMAIN, DNSPOD_SUBDOMAIN'
  echo 'Missing credentials are prompted for on a terminal; subdomain defaults to aws6.'
  exit 0
fi
if [[ "$#" -ne 0 ]]; then
  echo 'Unknown argument. Use --help for usage.' >&2
  exit 1
fi
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
if [ "$(id -u)" -ne 0 ]; then
  echo 'Run this installer as root.' >&2
  exit 1
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo 'A Linux instance using systemd is required.' >&2
  exit 1
fi

# Read from the terminal, so interactive use also works with curl | sudo bash.
prompt_value() {
  local name="$1" label="$2" secret="$3" fallback="$4" value="${!1}"
  if [[ -z "$value" ]]; then
    if { : </dev/tty; } 2>/dev/null; then
      if [[ "$secret" == "yes" ]]; then
        IFS= read -r -s -p "$label: " value </dev/tty || return 1
        printf '\n' >/dev/tty
      else
        IFS= read -r -p "$label [$fallback]: " value </dev/tty || return 1
      fi
    elif [[ -z "$fallback" ]]; then
      echo "Missing $name. Set it at the top of this script for EC2 User Data." >&2
      return 1
    fi
    value="${value:-$fallback}"
  fi
  if [[ -z "$value" ]]; then
    echo "$name cannot be empty." >&2
    return 1
  fi
  printf -v "$name" '%s' "$value"
}
prompt_value DNSPOD_SECRET_ID 'Tencent Cloud SecretId' yes ''
prompt_value DNSPOD_SECRET_KEY 'Tencent Cloud SecretKey' yes ''
prompt_value DNSPOD_SUBDOMAIN 'Subdomain (use @ for root domain)' no 'aws6'

if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y python3 ca-certificates
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y python3 ca-certificates
elif command -v yum >/dev/null 2>&1; then
  yum install -y python3 ca-certificates
else
  echo 'Supported package managers: apt-get, dnf, yum.' >&2
  exit 1
fi
install -d -m 700 /etc/dnspod-ddns-v6
install -d -m 755 /opt/dnspod-ddns-v6
# Encode credentials as JSON data, never interpolate them into executable code.
DNSPOD_SECRET_ID="$DNSPOD_SECRET_ID" DNSPOD_SECRET_KEY="$DNSPOD_SECRET_KEY" \
DNSPOD_DOMAIN="$DNSPOD_DOMAIN" DNSPOD_SUBDOMAIN="$DNSPOD_SUBDOMAIN" \
python3 - <<'DNSPOD_SETTINGS_EOF'
import json
import os
from pathlib import Path
import re
import sys

config = {
    "secret_id": os.environ["DNSPOD_SECRET_ID"],
    "secret_key": os.environ["DNSPOD_SECRET_KEY"],
    "domain": os.environ["DNSPOD_DOMAIN"].strip().lower(),
    "subdomain": os.environ["DNSPOD_SUBDOMAIN"].strip().lower(),
    "line": "默认", "line_id": "0", "ttl": 600,
}
label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
name = label + r"(?:\." + label + r")*"
if (not re.fullmatch(name, config["domain"]) or len(config["domain"]) > 253
        or (config["subdomain"] != "@" and not re.fullmatch(name, config["subdomain"]))):
    sys.exit("Invalid domain or subdomain. Use a prefix such as aws, home or @.")
if len(config["domain"]) + len(config["subdomain"]) + 1 > 253:
    sys.exit("The resulting domain name is too long.")
if any(not config[key].strip() or "REPLACE_WITH" in config[key]
       for key in ("secret_id", "secret_key")):
    sys.exit("Set valid SecretId and SecretKey values before installation.")
path = Path("/etc/dnspod-ddns-v6/config.json")
# Replace atomically; an interrupted reinstall keeps the previous config intact.
temporary = path.with_suffix(".tmp")
fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as stream:
    os.fchmod(stream.fileno(), 0o600)
    json.dump(config, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
temporary.replace(path)
print("Target: " + (config["domain"] if config["subdomain"] == "@" else
                   config["subdomain"] + "." + config["domain"]))
DNSPOD_SETTINGS_EOF
unset DNSPOD_SECRET_ID DNSPOD_SECRET_KEY
cat > /opt/dnspod-ddns-v6/ddns.py <<'DNSPOD_PYTHON_EOF'
#!/usr/bin/env python3
"""EC2 IPv6 -> DNSPod AAAA record. Python standard library only."""
import argparse
import datetime
import hashlib
import hmac
import ipaddress
import json
import logging
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request

HOST = "dnspod.tencentcloudapi.com"
CONTENT_TYPE = "application/json; charset=utf-8"
LOG = logging.getLogger("dnspod-ddns-v6")


class DDNSError(Exception):
    """Safe to display; never includes credentials or request headers."""


def load_config(path):
    config = json.loads(Path(path).read_text(encoding="utf-8"))
    for key in ("secret_id", "secret_key", "domain", "subdomain", "line", "line_id"):
        value = config.get(key)
        if not isinstance(value, str) or not value.strip() or "REPLACE_WITH" in value:
            raise DDNSError("Missing or placeholder config field: " + key)
    if not isinstance(config.get("ttl"), int) or not 1 <= config["ttl"] <= 604800:
        raise DDNSError("TTL must be an integer between 1 and 604800")
    return config


def signed_headers(config, action, payload, timestamp, host=HOST, service="dnspod"):
    date = datetime.datetime.fromtimestamp(
        timestamp, datetime.timezone.utc
    ).strftime("%Y-%m-%d")
    names = "content-type;host;x-tc-action"
    canonical_headers = "content-type:{}\nhost:{}\nx-tc-action:{}\n".format(
        CONTENT_TYPE, host, action.lower()
    )
    canonical = "POST\n/\n\n{}\n{}\n{}".format(
        canonical_headers, names, hashlib.sha256(payload).hexdigest()
    )
    scope = date + "/" + service + "/tc3_request"
    to_sign = "TC3-HMAC-SHA256\n{}\n{}\n{}".format(
        timestamp, scope, hashlib.sha256(canonical.encode()).hexdigest()
    )

    def sign(key, message):
        return hmac.new(key, message.encode(), hashlib.sha256).digest()

    key = sign(("TC3" + config["secret_key"]).encode(), date)
    key = sign(key, service)
    key = sign(key, "tc3_request")
    signature = sign(key, to_sign).hex()
    return {
        "Authorization": "TC3-HMAC-SHA256 Credential={}/{}, SignedHeaders={}, Signature={}".format(
            config["secret_id"], scope, names, signature
        ),
        "Content-Type": CONTENT_TYPE,
        "Host": host,
        "X-TC-Action": action,
        "X-TC-Version": "2021-03-23",
        "X-TC-Timestamp": str(timestamp),
    }


class DNSPod:
    def __init__(self, config):
        self.config = config
        # Do not forward signed requests to another host on redirects.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        self.opener = urllib.request.build_opener(NoRedirect())

    def call(self, action, params):
        payload = json.dumps(params, ensure_ascii=False, separators=(",", ":")).encode()
        headers = signed_headers(self.config, action, payload, int(time.time()))
        request = urllib.request.Request("https://" + HOST + "/", payload, headers)
        try:
            with self.opener.open(request, timeout=15) as response:
                result = json.load(response)["Response"]
        except urllib.error.HTTPError as exc:
            raise DDNSError("DNSPod HTTP error: {}".format(exc.code)) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise DDNSError("Cannot reach DNSPod; check HTTPS egress and system clock") from None
        except (ValueError, KeyError):
            raise DDNSError("Invalid DNSPod response") from None
        if "Error" in result:
            # Code and request ID help diagnostics without echoing server messages.
            raise DDNSError("DNSPod API error: {} (RequestId={})".format(
                result["Error"].get("Code", "Unknown"), result.get("RequestId", "unknown")
            ))
        return result

    def records(self):
        records = []
        offset = 0
        while True:
            result = self.call("DescribeRecordList", {
                "Domain": self.config["domain"],
                "SubDomain": self.config["subdomain"],
                "Offset": offset, "Limit": 100, "ErrorOnEmpty": "no",
            })
            page = result.get("RecordList") or []
            records.extend(page)
            if len(page) < 100:
                return records
            offset += len(page)


def public_ipv6():
    # IMDS /ipv6 returns the first IPv6 on the primary network interface.
    # Try the IPv6 IMDS endpoint too when IPv4 link-local access is unavailable.
    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    for base in ("http://169.254.169.254/latest/", "http://[fd00:ec2::254]/latest/"):
        try:
            request = urllib.request.Request(base + "api/token", method="PUT", headers={
                "X-aws-ec2-metadata-token-ttl-seconds": "60"
            })
            with opener.open(request, timeout=3) as response:
                token = response.read().decode().strip()
            request = urllib.request.Request(base + "meta-data/ipv6", headers={
                "X-aws-ec2-metadata-token": token
            })
            with opener.open(request, timeout=3) as response:
                value = response.read().decode().strip()
        except (urllib.error.URLError, TimeoutError, OSError):
            continue
        try:
            address = ipaddress.IPv6Address(value)
        except ValueError:
            raise DDNSError("IMDS returned an invalid IPv6 address") from None
        if (not address.is_global or address.is_multicast or address.is_site_local
                or address.ipv4_mapped is not None or "%" in value):
            raise DDNSError("EC2 address is not a public unicast IPv6; DNS was not changed")
        return str(address)
    raise DDNSError("Cannot read EC2 IPv6 via IMDSv2; enable metadata and assign IPv6 to the primary interface")


def select_record(config, records):
    exact = [record for record in records if record["Name"] == config["subdomain"]]
    if any(record["Type"] in ("CNAME", "URL", "FRAME_URL") for record in exact):
        raise DDNSError("Conflicting CNAME/URL record exists; resolve it in DNSPod first")
    matches = [record for record in exact
               if record["Type"] == "AAAA" and str(record.get("LineId")) == config["line_id"]]
    if len(matches) > 1:
        raise DDNSError("Multiple AAAA records on this line; refusing to choose one")
    record = matches[0] if matches else None
    if record and str(record.get("Status", "")).upper() not in ("ENABLE", "ENABLED"):
        raise DDNSError("AAAA record is disabled; enable it in DNSPod first")
    return record


def synchronize(config, api, ip, record, dry_run=False):
    fqdn = config["domain"] if config["subdomain"] == "@" else (
        config["subdomain"] + "." + config["domain"]
    )
    if record and ipaddress.IPv6Address(record["Value"]) == ipaddress.IPv6Address(ip):
        LOG.info("Unchanged: %s -> %s", fqdn, ip)
        return
    action = "ModifyDynamicDNS" if record else "CreateRecord"
    if dry_run:
        LOG.info("Dry run: would %s %s -> %s", action, fqdn, ip)
        return
    params = {
        "Domain": config["domain"], "SubDomain": config["subdomain"],
        "RecordLine": config["line"],
        "RecordLineId": config["line_id"], "Value": ip,
    }
    if record:
        params["RecordId"] = record["RecordId"]
        params["TTL"] = record.get("TTL", config["ttl"])
    else:
        params["RecordType"] = "AAAA"
        params["TTL"] = config["ttl"]
    api.call(action, params)
    LOG.info("%s: %s -> %s", action, fqdn, ip)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/etc/dnspod-ddns-v6/config.json")
    parser.add_argument("--check", action="store_true", help="Read-only credentials and record check; no EC2 needed")
    parser.add_argument("--dry-run", action="store_true", help="Read current EC2 IP and DNS; do not write DNS")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        config = load_config(args.config)
        api = DNSPod(config)
        # Read the local address first; never touch DNS without an EC2 public IP.
        ip = None if args.check else public_ipv6()
        record = select_record(config, api.records())
        if args.check:
            LOG.info("Read-only check OK; target AAAA record %s", "exists" if record else "will be created")
        else:
            synchronize(config, api, ip, record, args.dry_run)
        return 0
    except DDNSError as exc:
        LOG.error("%s", exc)
    except (OSError, ValueError, KeyError, TypeError):
        LOG.error("Invalid configuration or response; check config file and permissions")
    return 1


if __name__ == "__main__":
    sys.exit(main())

DNSPOD_PYTHON_EOF
chmod 700 /opt/dnspod-ddns-v6/ddns.py
cat > /etc/systemd/system/dnspod-ddns-v6.service <<'DNSPOD_SERVICE_EOF'
[Unit]
Description=Sync EC2 public IPv6 to DNSPod
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/bin/python3 /opt/dnspod-ddns-v6/ddns.py --config /etc/dnspod-ddns-v6/config.json
TimeoutStartSec=120
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
DNSPOD_SERVICE_EOF
cat > /etc/systemd/system/dnspod-ddns-v6.timer <<'DNSPOD_TIMER_EOF'
[Unit]
Description=Check DNSPod on every boot and every sixty seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
RandomizedDelaySec=0
AccuracySec=1s
Unit=dnspod-ddns-v6.service

[Install]
WantedBy=timers.target
DNSPOD_TIMER_EOF
systemctl daemon-reload
systemctl enable --now dnspod-ddns-v6.timer
systemctl start dnspod-ddns-v6.service
echo 'DNSPod DDNS installed; logs: journalctl -u dnspod-ddns-v6.service'
