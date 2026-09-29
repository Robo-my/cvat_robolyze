# CVAT on EC2: host automation

systemd units and scripts for the CVAT EC2 host (`robolyze-cvat`, reached over Tailscale).
Install or update on the host with:

```bash
cd ~/cvat_robolyze && git pull   # or copy this folder over
sudo deploy/ec2/install.sh
```

Scripts are installed to `/opt/cvat/`, units to `/etc/systemd/system/`. The repo is expected at
`/home/ubuntu/cvat_robolyze`.

## Email (invitations, password resets)

CVAT ships `EMAIL_BACKEND = None`, so organization invitations fail with *"Email backend is not
configured."* `cvat/settings/robolyze.py` (baked into the image) adds an env-driven SMTP backend and
is activated by `components/email/docker-compose.email.yml`, which `cvat-start.sh` always passes.

Set these in the host `.env` (mode 600, gitignored — never commit them):

| key | value used here |
|---|---|
| `EMAIL_HOST` / `EMAIL_PORT` / `EMAIL_USE_TLS` | `smtp.gmail.com` / `587` / `true` |
| `EMAIL_HOST_USER` / `EMAIL_HOST_PASSWORD` | the Gmail account + **app password** |
| `DEFAULT_FROM_EMAIL` | `CVAT Robolyze <…>` |
| `ACCOUNT_EMAIL_VERIFICATION` | `optional` (`none`/`mandatory` also valid) |

To switch provider, change those values only. Links in the mail come from the Django **sites** row,
not from `.env`: it must not be `example.com`, or every link is wrong.

```bash
docker exec -w /opt/cvat cvat_server python3 -c "
import django; django.setup()
from django.contrib.sites.models import Site
Site.objects.update_or_create(pk=1, defaults={'domain':'100.68.135.83:8080','name':'CVAT Robolyze'})"
```

The health check verifies the backend and the sites row (`email backend ok …`). Inviting an address
that belongs to more than one user account fails with HTTP 500 (`More than one user has this email`)
— that is a CVAT constraint, not a mail problem.

| Unit | When | What |
|---|---|---|
| `cvat.service` | boot | `cvat-start.sh`: `docker compose` with **both** `docker-compose.yml` and `components/serverless/docker-compose.serverless.yml`, then starts the nuclio model containers. On stop, `cvat-stop.sh` shuts the stack down cleanly. |
| `cvat-healthcheck.timer` | 3 min after boot | `cvat-healthcheck.sh`: API check + invokes every model through CVAT's `LambdaGateway`. Result in `/var/log/cvat-health.last`. |
| `cvat-autostop.timer` | 21:00 Asia/Kuala_Lumpur | `cvat-autostop.sh`: waits for a running backup (max 25 min), stops CVAT, powers off. The instance must use shutdown behaviour **stop**, not terminate. Starting is manual. |
| `cvat-backup.timer` | 13:00 and 20:30 Asia/Kuala_Lumpur | `cvat-backup.sh`: see below. |

## Backups (`cvat-backup.sh`)
Target: `//<nas>/robomy/cvat_backups/` (WD My Cloud Mirror, DHCP: the script rediscovers the IP on the LAN prefix if it moves). The share and credentials are read from
`/etc/cvat-backup.conf` (mode 600, host only, never committed; see `cvat-backup.conf.example`). The EC2 reaches it through the Tailscale
subnet route `192.168.0.0/24`, advertised by robomyserver-1; the EC2 runs `tailscale up --accept-routes`.

- `runs/<YYYYMMDD_HHMM>/`: full DB dump, keys volume, `.env` (Tailscale key stripped), compose override,
  row counts, media id list, the installed automation, `MANIFEST.sha256`.
- `media/data_<id>.tar`: one tar per task data dir, re-uploaded only when the dir changes.
- `models/models_<hash>.tar.gz`: model weights + `cvat-models/`, uploaded only when changed.
- Uploaded sizes are verified on the NAS. If the NAS is unreachable, the run stays in `/var/backups/cvat`
  and is uploaded on the next successful run (state: `/var/lib/cvat-backup`, `NAS_PENDING`).
- Retention on the NAS: 14 newest runs + newest run of the last 8 Sundays + first run of every month.

Manual run: `sudo systemctl start cvat-backup.service && journalctl -u cvat-backup -n 20`.

## Restore (outline)
1. Clone the repo, restore the `.env` from `runs/<ts>/env.txt`, build/pull images, start `cvat_db` only.
2. `zcat cvat_db.sql.gz | docker exec -i cvat_db psql -U root -d cvat`, and untar `cvat_keys.tar.gz` into
   the `cvat_cvat_keys` volume.
3. Untar every `media/data_<id>.tar` listed in `runs/<ts>/data_ids.txt` into
   `/var/lib/docker/volumes/cvat_cvat_data/_data/data/`.
4. Redeploy models with `serverless/pytorch/ultralytics/add_yolo_model.sh` (weights from `models/`).
5. `sudo deploy/ec2/install.sh`.

## Gotchas
- CVAT v2.74 code lives in `/opt/cvat` inside the server image, not `/home/django/cvat`.
- Models must use pinned ports (`add_yolo_model.sh --port`, default from 49100) and
  `CVAT_NUCLIO_INVOKE_METHOD: direct`. Nuclio's `dashboard` mode calls container IPs recorded at deploy
  time, and Docker reassigns those on reboot.
