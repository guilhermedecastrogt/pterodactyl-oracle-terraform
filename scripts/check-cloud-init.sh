#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../terraform"

EXPR='jsonencode({rendered = templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {timezone="UTC", region="ci", instance_name="ci", panel_version="v1.15.1", panel_domain="", panel_admin_email="ci@example.com", panel_admin_username="admin", panel_admin_first_name="Server", panel_admin_last_name="Admin", panel_admin_password="ci", app_key="base64:ci", db_root_password="ci", db_password="ci", game_port_min=25565, game_port_max=25585, mclibrarymgr_patch=file("${path.module}/templates/extensions/mclibrarymgr-authz.patch")}), gzip_size = length(base64gzip(templatefile("${path.module}/templates/cloud-init.yaml.tftpl", {timezone="UTC", region="ci", instance_name="ci", panel_version="v1.15.1", panel_domain="", panel_admin_email="ci@example.com", panel_admin_username="admin", panel_admin_first_name="Server", panel_admin_last_name="Admin", panel_admin_password="ci", app_key="base64:ci", db_root_password="ci", db_password="ci", game_port_min=25565, game_port_max=25585, mclibrarymgr_patch=file("${path.module}/templates/extensions/mclibrarymgr-authz.patch")})))})'

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

terraform init -backend=false -input=false >/dev/null

echo "$EXPR" | terraform console \
  -var tenancy_ocid=ci \
  -var user_ocid=ci \
  -var fingerprint=ci \
  -var ssh_public_key=ci \
  -var panel_admin_email=ci@example.com \
  -var budget_alert_email=ci@example.com \
  | tail -n1 > "$WORK/rendered.json"

python3 - "$WORK" <<'PY'
import base64, json, sys, yaml

work = sys.argv[1]
out = json.loads(json.loads(open(f"{work}/rendered.json").read()))
doc = yaml.safe_load(out["rendered"])

# OCI rejects instance metadata above 32 KB.
assert out["gzip_size"] < 32000, f"user_data is {out['gzip_size']} bytes after gzip"

files = {}
for f in doc["write_files"]:
    content = f["content"]
    if f.get("encoding") == "b64":
        content = base64.b64decode(content).decode()
    files[f["path"]] = content
compose = yaml.safe_load(files["/opt/pterodactyl/docker-compose.yml"])

expected = {"database", "cache", "panel", "wings", "proxy"}
assert "runcmd" in doc, "cloud-init has no runcmd section"
assert set(compose["services"]) == expected, compose["services"]
assert "/var/run/docker.sock" in str(compose["services"]["wings"]["volumes"])
assert compose["services"]["panel"]["environment"]["APP_URL"].startswith("https://panel.")
assert compose["services"]["panel"]["image"] == "ghcr.io/blueprintframework/blueprint:v1.15.1"
assert "app:/app" in compose["services"]["panel"]["volumes"], "Blueprint needs /app in a named volume"
assert "app" in compose["volumes"]

bootstrap = files["/opt/pterodactyl/bootstrap.sh"]
for needle in ["p:user:make", "blueprint -i", "MCLIB_COMMIT=", "SIDEBAR_SHA256=", "p:node:make"]:
    assert needle in bootstrap, f"bootstrap is missing {needle}"
assert "${" not in bootstrap, "an unrendered Terraform interpolation leaked into the script"
assert not any("chown -R" in str(c) for c in doc["runcmd"]), "a recursive chown would take MariaDB's datadir away from it"

open(f"{work}/bootstrap.sh", "w").write(bootstrap)
open(f"{work}/mclibrarymgr.patch", "w").write(files["/opt/pterodactyl/extensions/mclibrarymgr-authz.patch"])
open(f"{work}/commit", "w").write(bootstrap.split('MCLIB_COMMIT="')[1].split('"')[0])

print("cloud-init, docker-compose and bootstrap render correctly")
PY

bash -n "$WORK/bootstrap.sh"
echo "bootstrap.sh parses"

# The patch is only useful while it still applies to the pinned commit.
git -C "$WORK" init -q mclib
git -C "$WORK/mclib" fetch -q --depth 1 https://github.com/nicolasjm0702/mclibrarymgr "$(cat "$WORK/commit")"
git -C "$WORK/mclib" checkout -q FETCH_HEAD
git -C "$WORK/mclib" apply --check "$WORK/mclibrarymgr.patch"
echo "mclibrarymgr patch applies to the pinned commit"
