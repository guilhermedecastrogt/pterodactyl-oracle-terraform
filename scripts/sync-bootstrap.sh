#!/usr/bin/env bash
# Pushes the files cloud-init wrote at first boot (compose file, bootstrap,
# extension patch) to the running VM as the current template renders them,
# then re-runs the bootstrap. Terraform ignores user_data changes so that a
# template edit never recreates the VM; this is how those edits get there.
#
#   SSH_KEY=~/.ssh/my_key ./scripts/sync-bootstrap.sh
#   DRY_RUN=1 ./scripts/sync-bootstrap.sh    # only show what would change
set -euo pipefail

cd "$(dirname "$0")/../terraform"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
[ -n "${SSH_KEY:-}" ] && SSH_OPTS+=(-i "$SSH_KEY")
HOST="ubuntu@$(terraform output -raw public_ip)"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo 'nonsensitive(jsonencode(local.cloud_init))' | terraform console | tail -n1 > "$WORK/rendered.json"

python3 - "$WORK" <<'PY'
import base64, json, os, sys, yaml

work = sys.argv[1]
doc = yaml.safe_load(json.loads(json.loads(open(f"{work}/rendered.json").read())))
for f in doc["write_files"]:
    content = f["content"]
    if f.get("encoding") == "b64":
        content = base64.b64decode(content).decode()
    path = os.path.join(work, "root", f["path"].lstrip("/"))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as out:
        out.write(content)
    os.chmod(path, int(f.get("permissions", "0644"), 8))
PY

echo "== changes against the VM"
for file in $(cd "$WORK/root" && find . -type f | sed 's|^\.||'); do
  if ssh "${SSH_OPTS[@]}" "$HOST" "sudo cat $file" 2>/dev/null | diff -u --label "vm:$file" --label "new:$file" - "$WORK/root$file" >"$WORK/diff"; then
    echo "unchanged  $file"
  else
    echo "changed    $file"
    # Never print secrets: show the shape of the diff, not the lines.
    grep -vE 'PASSWORD|APP_KEY|password=' "$WORK/diff" | sed 's/^/    /' | head -80
  fi
done

if [ -n "${DRY_RUN:-}" ]; then
  echo "DRY_RUN set, nothing was changed"
  exit 0
fi

echo "== backing up the panel database"
ssh "${SSH_OPTS[@]}" "$HOST" 'set -euo pipefail
  sudo mkdir -p /opt/pterodactyl/backups
  backup=/opt/pterodactyl/backups/panel-$(date +%Y%m%d-%H%M%S).sql.gz
  sudo docker exec panel-database sh -c "exec mariadb-dump -uroot -p\"\$MYSQL_ROOT_PASSWORD\" --single-transaction --all-databases" \
    | gzip | sudo tee "$backup" >/dev/null
  echo "saved $backup ($(sudo du -h "$backup" | cut -f1))"'

echo "== installing files and re-running the bootstrap"
COPYFILE_DISABLE=1 tar --no-xattrs -C "$WORK/root" -czf - . | ssh "${SSH_OPTS[@]}" "$HOST" 'set -euo pipefail
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git zip jq >/dev/null
  sudo tar --no-same-owner -xzf - -C /
  sudo bash /opt/pterodactyl/bootstrap.sh'
