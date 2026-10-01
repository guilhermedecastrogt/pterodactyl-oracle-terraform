# Pterodactyl on Oracle Cloud with Terraform

[![terraform](https://github.com/guilhermedecastrogt/pterodactyl-oracle-terraform/actions/workflows/terraform.yml/badge.svg)](https://github.com/guilhermedecastrogt/pterodactyl-oracle-terraform/actions/workflows/terraform.yml)

Infrastructure as code for running a full **Pterodactyl** game-server panel on
an ARM VM in Oracle Cloud's **Always Free** tier. One `terraform apply` creates
the network, the firewall rules and the machine, then brings up the panel, its
database, the Wings daemon and an HTTPS reverse proxy — with a working
certificate and an admin account already created.

On top of Pterodactyl it installs [Blueprint](https://github.com/BlueprintFramework/framework)
with two extensions, so it behaves like a small Minecraft hosting panel: a
sidebar navigation, and **Library** / **Modpack** tabs on every server for
searching and installing mods, plugins, datapacks, resource packs and modpacks
from Modrinth or CurseForge. SSH is for the infrastructure, not for adding a
plugin. See [Minecraft Hosting Panel](#minecraft-hosting-panel).

```
terraform apply
      │
      ▼
 Oracle Cloud (home region only — Always Free is region-locked)
      │
      ├── VCN 10.0.0.0/16
      │     ├── Internet Gateway · Route Table
      │     ├── Security List  :22 · :80 · :443 · :2022 · :25565-25585 (tcp+udp)
      │     └── Subnet 10.0.1.0/24 (public)
      │
      └── VM  VM.Standard.A1.Flex · Ubuntu 24.04 ARM
            │
            └── cloud-init (first boot)
                  ├── installs Docker
                  ├── opens the same ports in the in-VM iptables
                  └── docker compose up
                        ├── caddy      → TLS for panel.<domain> and node.<domain>
                        ├── panel      → Pterodactyl + Blueprint
                        │                 (Ptero Sidebar, Minecraft Library Manager)
                        ├── database   → MariaDB
                        ├── cache      → Redis
                        └── wings      → spawns one container per game server
```

**Cost: $0** within Always Free, with a USD 1 budget alert wired in as a
tripwire in case anything ever leaves the free tier.

---

## Layout

```
.
├── .github/workflows/terraform.yml   CI: fmt, validate and cloud-init lint
├── scripts/
│   ├── check-cloud-init.sh           renders the template and validates it
│   ├── sync-bootstrap.sh             pushes template changes to a running VM
│   └── apply-retry.sh                reapplies until ARM capacity frees up
└── terraform/
    ├── versions.tf                   Terraform and provider constraints
    ├── providers.tf                  OCI authentication
    ├── variables.tf                  every knob the project exposes
    ├── secrets.tf                    generated DB, app and admin credentials
    ├── network.tf                    VCN, IGW, route table, security list, subnet
    ├── compute.tf                    Ubuntu ARM image lookup + A1.Flex instance
    ├── budget.tf                     spend tripwire (required)
    ├── outputs.tf                    panel URL and credentials after apply
    ├── templates/
    │   ├── cloud-init.yaml.tftpl     the whole stack, written at first boot
    │   └── extensions/
    │       └── mclibrarymgr-authz.patch   access-control fix for the Library Manager
    └── terraform.tfvars.example
```

## Sizing

Pterodactyl is a stack, not a container: panel, MariaDB, Redis, Caddy and Wings
together take roughly **1.5 GB of RAM** before a single game server starts.

| Setup | `instance_ocpus` | `instance_memory_gb` | Room left for servers |
|---|---|---|---|
| Minimum that makes sense | 2 | 12 | ~10 GB |
| Comfortable | 4 | 24 | ~22 GB |

The default is 2 / 12. Larger requests are meaningfully harder to schedule on
the free ARM pool — see [when ARM capacity runs out](#when-arm-capacity-runs-out).

## Requirements

| What | How to get it |
|---|---|
| Oracle Cloud account | [cloud.oracle.com](https://cloud.oracle.com) — a card is required, but Always Free resources are not billed |
| Terraform ≥ 1.5 | `brew install terraform` |
| SSH key pair | `ssh-keygen -t ed25519` |
| OCI API key | Console → profile → **My profile** → **API keys** → **Add API key** |
| A domain | **optional** — see below |

### About the domain

The panel needs real DNS to get a real certificate. If you leave `panel_domain`
empty, the stack uses [sslip.io](https://sslip.io), a public resolver that maps
any hostname containing an IP back to that IP. The VM discovers its own public
address at boot and serves:

```
https://panel.<your-ip>.sslip.io
https://node.<your-ip>.sslip.io
```

No DNS to configure, and Let's Encrypt still issues a valid certificate. Set
`panel_domain = "example.com"` if you own one and prefer `panel.example.com`;
point an `A` record for `panel` and `node` at the instance IP first.

## Deploying

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars      # credentials, SSH key, panel_admin_email

terraform init
terraform plan
terraform apply
```

Passwords for MariaDB, the Laravel `APP_KEY` and the panel admin are generated
by Terraform, so there is nothing to invent. Read them back with:

```bash
terraform output panel_url
terraform output panel_admin_username
terraform output -raw panel_admin_password
```

First boot takes **10 to 15 minutes**: Docker install, five images pulled for
arm64, database migrations, two Blueprint extension builds (each rebuilds the
panel frontend) and certificate issuance. Follow along with:

```bash
ssh ubuntu@<IP> 'sudo tail -f /var/log/cloud-init-output.log'
```

The bootstrap reports one line per component, and stops at the first failure
with the reason, where to look and what to do:

```
[OK] Docker
[OK] MariaDB
[OK] Redis
[OK] Pterodactyl (admin admin, location oci)
[OK] Blueprint (ghcr.io/blueprintframework/blueprint:v1.15.1)
[OK] Ptero Sidebar
[OK] Minecraft Library Manager
[OK] Wings (node node.150.230.x.x.sslip.io, ports 25565-25585)
[OK] Caddy (HTTPS for panel.150.230.x.x.sslip.io and node.150.230.x.x.sslip.io)

panel ready at https://panel.150.230.x.x.sslip.io
```

## First Login

Everything up to a working node is automated: the admin account, the `oci`
location, the node, its game-port allocations and the Wings configuration.

1. Open the `panel_url` output and log in with `panel_admin_username` and
   `terraform output -raw panel_admin_password`.
2. **Admin → Nodes**: the node should show a green heart within a minute. Its
   memory and disk limits leave about 4 GB of RAM and 10 GB of disk to the host.
3. *(Optional, CurseForge only)* **Admin → Extensions → Minecraft Library
   Manager**: paste a CurseForge API key. Modrinth needs nothing.
4. **Admin → Servers → Create New**, nest **Minecraft**, egg **Paper**,
   **Vanilla**, **Forge**, **Sponge** or **BungeeCord**, default allocation
   `<public ip>:25565`. Pick the Java image matching the game version (Java 21
   for 1.20.5 and later).
5. Leave Admin, open the server, press **Start**. Players connect to
   `<public ip>:25565`.

Nothing here needs SSH. The one step that cannot be automated is the
CurseForge key: it is personal, and the extension keeps it in the panel's
database rather than in Terraform, so it never lands in state or in Git.

## Minecraft Hosting Panel

```
Pterodactyl  →  Blueprint  →  Ptero Sidebar
                           →  Minecraft Library Manager  →  Library · Modpack tabs
```

| Piece | What it does | Source, pinned at |
|---|---|---|
| [Blueprint](https://github.com/BlueprintFramework/framework) | Extension framework. Ships as the official panel image with Blueprint added | `ghcr.io/blueprintframework/blueprint:<panel_version>`, amd64 + **arm64** |
| [Ptero Sidebar](https://github.com/zephrynis/ptero-sidebar) | Replaces the top navigation with a sidebar. CSS only, no server code | release `1.0`, SHA-256 checked |
| [Minecraft Library Manager](https://github.com/nicolasjm0702/mclibrarymgr) | Adds **Library** and **Modpack** tabs to each server | commit `0797d87`, built from source + local patch |

All three are free and open source (MIT, GPL-3.0, MPL-2.0). No theme is
installed on top: the sidebar already changes the navigation, and a second
navigation addon would fight it.

**How it is installed.** `panel_version` selects the image. Blueprint rewrites
the panel's code when it installs an extension, so `/app` lives in a named
Docker volume (`pterodactyl_app`). The bootstrap downloads the sidebar release
and checks its hash, builds the Library Manager from the pinned commit the
same way its own `build.sh` does, and runs `blueprint -i` for each, inside the
panel container. A re-run skips any extension whose exact build is already
installed, so nothing is rebuilt needlessly.

**Why the Library Manager is patched.** Blueprint mounts extension routes
without the middleware that guards the panel's own `/servers/{server}` routes,
and the extension does not check access itself. Unpatched, any logged-in user
could install or delete files on any server, and a crafted filename could slip
an extra command into a server console. `templates/extensions/mclibrarymgr-authz.patch`
adds the panel's own access middleware to every route, requires the matching
subuser file permission (`file.read`, `file.create`, `file.delete`), makes the
panel-wide provider switch admin-only and rejects control characters in
console commands. CI checks the patch still applies to the pinned commit.

**Installing content.** Open a server, then:

- **Library** → search (or paste a Modrinth / CurseForge link) → **Install**.
  The extension reads the server's game version and loader, picks a compatible
  file and puts it where it belongs: `/mods`, `/plugins`, `/world/datapacks`.
  Resource packs are set in `server.properties` so clients download them. The
  same tab lists what is installed and removes it.
- **Modpack** → search → pick a version → **Install**. Modrinth packs are
  installed file by file; CurseForge server packs are downloaded and extracted
  by Wings. Files that fail are listed in `mclibrarymgr-failed-files.txt` in
  the server root. Uninstall removes exactly what the install added.
- Restart from **Console** and watch the server load the new content.

Datapacks are enabled and disabled with console commands, so the server
should be running when you add or remove one.

**Modrinth or CurseForge.** Modrinth works without a key. CurseForge requires
an API key from [console.curseforge.com](https://console.curseforge.com),
entered under Admin → Extensions → Minecraft Library Manager. The admin page
also turns either tab off.

**Eggs.** The panel's stock Minecraft eggs (Paper, Vanilla, Forge, Sponge,
BungeeCord) are untouched. Fabric, NeoForge and Purpur are not stock: they
come from community egg collections such as
[pelican-eggs/minecraft](https://github.com/pelican-eggs/minecraft). They are
not imported at boot, because an egg's install script runs on the node with
nobody having read it. Review one and import it under Admin → Nests →
Import Egg when you need it; the Library tab then works with that loader.

**Backups** stay the panel's own, per server, from the **Backups** tab. The
extensions do not add a second system. Blueprint's own state lives in the
`pterodactyl_app` volume and is rebuilt from the pinned sources by the
bootstrap; the Library Manager's settings and records live in the panel
database.

**ARM64.** Every image in the stack is published for arm64. Most Minecraft
server software is plain Java and runs fine on it; the Java images Pterodactyl
uses are multi-arch. Mods with native libraries built only for x86 will not.

**Always Free.** The extensions run inside the existing panel container on the
existing VM. Nothing new is created in Oracle Cloud, so the cost is unchanged.

**Upgrading.** Bump `panel_version` (forward only), or a pin in
`bootstrap.sh`, then run `./scripts/sync-bootstrap.sh`. A panel version change
rebuilds the app volume from the new image and installs the extensions again.

## Running it

```bash
ptero ps               # stack status
ptero-logs             # all panel logs
wings-logs             # daemon logs
ptero-artisan          # php artisan inside the panel container
```

| Path | Contents |
|---|---|
| `/opt/pterodactyl/docker-compose.yml` | the stack |
| `/opt/pterodactyl/bootstrap.sh` | first-boot script, safe to re-run |
| `/opt/pterodactyl/data/` | database, panel state, Caddy certificates |
| `/etc/pterodactyl/config.yml` | Wings configuration |
| `/var/lib/pterodactyl/volumes/` | the game servers' files |

Backups are configured per server from the panel, which is why this project no
longer ships a backup container.

**Tearing everything down** (every server goes with it):

```bash
terraform destroy
```

## How the pieces fit together

**There are two firewalls, and both must allow the port.** The OCI security
list filters before packets reach the VM; iptables inside Ubuntu filters after,
and Oracle's image ships blocking everything except SSH. cloud-init opens the
same ports on the inside. Forgetting one of them is the usual cause of "the
panel is up but the server is unreachable".

**Wings publishes ports it does not own.** Game containers are created by Wings
through the Docker socket as siblings, and they bind the host directly. That is
why the `wings` service publishes only SFTP (2022): publishing the game range
there too would collide with "port is already allocated" the moment a server
starts.

**cloud-init runs exactly once.** Terraform ignores changes to `user_data`,
because applying them would recreate the machine and take every game server
with it. To bring a template change to a running VM:

```bash
DRY_RUN=1 SSH_KEY=~/.ssh/your_key ./scripts/sync-bootstrap.sh   # show what changes
SSH_KEY=~/.ssh/your_key ./scripts/sync-bootstrap.sh             # back up the DB, push, re-run
```

It renders the template exactly as Terraform would, diffs it against the VM
(without printing secrets), dumps the panel database to
`/opt/pterodactyl/backups/`, installs the new files and re-runs the bootstrap.
Terraform owns the infrastructure; the panel owns the servers.

**`user_data` is gzipped.** OCI caps instance metadata at 32 KB and the
rendered cloud-init is larger; cloud-init unpacks gzip on its own.

**The base image is looked up, not pinned.** `compute.tf` queries the newest
Ubuntu ARM image instead of hardcoding an OCID. An `ignore_changes` on
`source_id` keeps a new Oracle image release from recreating the VM.

## Cost guardrail

Everything here is meant to sit inside Always Free, so **any spend at all is a
bug**. `budget.tf` encodes that as a USD 1 monthly budget alerting at 1% of
actual spend, so it fires on the first cent, plus a forecast alert that warns
when Oracle projects the month ending above the budget.

```hcl
budget_alert_email = "you@example.com"
```

`budget_alert_email` is required: Terraform refuses to plan without it, so the
budget is always created. This matters most on **Pay As You Go**
accounts: a trial account refuses to exceed the free quota, while a PAYG
account happily does and charges the card.

## CI

Every push and pull request runs:

- `terraform fmt -check -recursive`
- `terraform init -backend=false` + `terraform validate`
- `scripts/check-cloud-init.sh` — renders the template and asserts the
  cloud-init document, the five-service compose file and the bootstrap script
  come out intact, with no unrendered interpolation leaking through; that the
  panel runs the pinned Blueprint image with `/app` in a volume; that the
  gzipped `user_data` fits OCI's 32 KB limit; that the bootstrap parses as
  bash; and that the Library Manager patch still applies to its pinned commit

Validation only; there is no automatic `apply`, which would need OCI
credentials as repository secrets.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Out of host capacity` | free ARM capacity exhausted. See below |
| Panel unreachable, certificate errors | Caddy could not complete the ACME challenge. Check `docker logs panel-proxy`; port 80 must be open |
| Node stays red | `/etc/pterodactyl/config.yml` missing or stale. Delete it and re-run `bootstrap.sh`, which regenerates it from the panel |
| Wings: `Pool overlaps with other one` | Wings' default Docker network collides with compose's. The bootstrap sets 172.30.0.0/16 in `config.yml`; a hand-pasted config loses that |
| `[ERROR] Ptero Sidebar` / `Minecraft Library Manager` | read `/opt/pterodactyl/logs/blueprint-<id>.log`. A patch that no longer applies means the pin moved; refresh the patch |
| Library tab: `API key not configured` | CurseForge selected without a key. Add one under Admin → Extensions, or switch to Modrinth |
| `Table '...' doesn't exist` / panel 500s | MariaDB lost access to its datadir: `sudo chown -R 999:999 /opt/pterodactyl/data/database` then `docker compose restart database` |
| SSH times out but the panel works | your public IP changed and `allowed_ssh_cidr` no longer matches it |
| `port is already allocated` | something else claimed a port in the allocation range |
| Server won't start, out of memory | the panel lets you over-allocate; leave ~2 GB for the host |

## When ARM capacity runs out

`Out of host capacity` is not a configuration error: the region's free Ampere
A1 pool is full. The apply creates everything else and fails only on the
instance, so reapplying resumes from there.

```bash
./scripts/apply-retry.sh                            # retry every 3 minutes
INTERVAL=300 ./scripts/apply-retry.sh               # every 5 minutes
MAX_TRIES=20 ./scripts/apply-retry.sh               # give up after 20 attempts
LOG_FILE=~/retry.log ./scripts/apply-retry.sh       # also append to a file
caffeinate -i ./scripts/apply-retry.sh              # macOS: keep the machine awake
```

The script sorts failures into three buckets. Capacity errors retry forever.
Transient ones — DNS blips, dropped connections, throttling, Oracle 5xx — also
retry, but a streak of `MAX_TRANSIENT` (default 20) in a row aborts, so a
genuinely broken network does not spin silently. Anything else stops
immediately and prints the error.

Three things improve the odds:

1. **Ask for less.** Smaller shapes are far easier to place. 2 OCPUs and 12 GB
   is the floor for this stack.
2. **Check your home region before switching regions.** Always Free resources
   only exist in the tenancy's home region, fixed at account creation.
   Deploying elsewhere works, but is billed.
3. **Leave the trial.** Trial accounts sit lower in the capacity queue, and the
   upgrade to Pay As You Go keeps Always Free resources free.

`availability_domain_index` only helps in regions with more than one
availability domain — `sa-saopaulo-1`, for instance, has a single one.

## Roadmap

- [ ] Remote state in OCI Object Storage + CI-driven `apply` via OIDC
- [x] Register the node automatically
- [ ] Ship panel backups to Object Storage with `rclone`
- [ ] Metrics with Prometheus + Grafana

## License

MIT.
