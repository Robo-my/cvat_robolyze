# CVAT on a single EC2 instance: daily schedule and tuning

This folder contains:
- a daily on/off schedule (**06:30–21:00 IST**) for a CVAT instance on EC2 that users reach over Tailscale at `http://<tailscale-ip>:8080/`;
- tuning for 5–13 concurrent annotators.

| File | What it does |
|---|---|
| `scheduler.tf` | Creates the following in AWS:<br>• EventBridge Scheduler start/stop schedules (Asia/Kolkata)<br>• a least-privilege IAM role<br>• alerts for failed starts (SNS email)<br>• a status-check alarm<br>• optional daily EBS snapshots (DLM, off by default) |
| `host-setup.sh` | One-time host setup:<br>• enables `docker` and `tailscaled` at boot<br>• lets Postgres shut down cleanly<br>• lists containers that won't restart after boot |
| `docker-compose.tuning.yml` | More server and chunk-worker processes, so job opening doesn't queue. |
| `diagnose.sh` | Shows where a slow host spends its time: CPU per container, RQ queue lengths, disk, and Tailscale direct vs relay. |

## Why the URL keeps working after a stop/start

- The Tailscale IP (`100.x.y.z`) belongs to the node identity stored in `/var/lib/tailscale` on the root EBS volume, and stopping an instance keeps EBS.
- The AWS public IP changes on every start. Users never use it, so that doesn't matter.
- Every CVAT container has `restart: always`, so once Docker starts at boot, CVAT starts as well.

The one thing that breaks the URL is **Tailscale node key expiry**, after 180 days by default. Disable it (step 2).

## Setup

### 1. On the CVAT host

Run this from the CVAT checkout on the instance:

```bash
sudo deploy/aws/host-setup.sh                   # safe, no downtime
sudo deploy/aws/host-setup.sh --restart-docker  # optional: apply now (CVAT down ~1-2 min)
```

### 2. In the Tailscale admin console

Go to **Machines → this machine → ⋯ → Disable key expiry**.

### 3. In AWS (run from a laptop with AWS credentials, not from the instance)

```bash
cd deploy/aws
terraform init
terraform apply \
  -var 'instance_id=i-xxxxxxxxxxxxxxxxx' \
  -var 'alert_email=ops@example.com'
```

Then confirm the SNS subscription email that arrives in the inbox.

Defaults, all overridable with `-var`:

| Variable | Default | Meaning |
|---|---|---|
| `start_cron` | `cron(20 6 * * ? *)` | Start at 06:20 IST. Boot and containers take about 3–5 min, so CVAT is ready by 06:30. |
| `stop_cron` | `cron(0 21 * * ? *)` | Stop at 21:00 IST. |
| `timezone` | `Asia/Kolkata` | Time zone for both cron expressions. |
| `enable_snapshots` | `false` | Daily EBS snapshots through DLM. Off because this AWS organization denies DLM with a service control policy. |
| `snapshot_time_utc` | `15:45` | 21:15 IST. DLM only accepts UTC. |
| `notify_state_changes` | `true` | Email at every start and stop. A missing morning email means something is wrong. |

For weekdays only, use `-var 'start_cron=cron(20 6 ? * MON-SAT *)' -var 'stop_cron=cron(0 21 ? * MON-SAT *)'`.

<details><summary>No Terraform? The same schedule from the AWS console</summary>

1. Go to **EventBridge → Scheduler → Create schedule**.
2. Choose a recurring cron schedule, enter `20 6 * * ? *`, and set the time zone to `Asia/Kolkata`. Set the flexible time window to **Off**.
3. Target: **All APIs → Amazon EC2 → StartInstances**, with input `{"InstanceIds":["i-xxxxxxxx"]}`.
4. Let the console create a new execution role.
5. Repeat with `0 21 * * ? *` and **StopInstances**.

</details>

### 4. Tuning (fixes slow job opening)

1. Measure first. Run `deploy/aws/diagnose.sh` while 3–5 people open jobs.
   - In a browser, open DevTools → Network and see which request is slow when a job opens:
     - `/api/jobs/<id>/data?...type=chunk` is the chunk cache or workers;
     - `/annotations` is the database.
2. Add `CVAT_ALLOW_STATIC_CACHE=yes` to `.env` next to `docker-compose.yml`.
   - New tasks created with **"Use cache" turned off** then build their chunks once, at creation time, instead of when someone opens a job.
   - This costs extra disk space for the chunks and makes task creation slower.
3. Start CVAT with the tuning file. Keep the same `-f` list on every later compose command:
   ```bash
   docker compose -f docker-compose.yml -f deploy/aws/docker-compose.tuning.yml up -d
   ```
   If you also use `components/serverless/docker-compose.serverless.yml`, add it to the list.
4. If `diagnose.sh` shows Tailscale peers on `relay`, allow inbound **UDP 41641** in the instance Security Group. Other inbound ports don't need to be open to the internet; access goes through Tailscale.
5. If `iostat` shows the disk near 100% `%util`, raise the gp3 volume to about 6000 IOPS and 250 MB/s. This is done in the EC2 console and needs no downtime.

## Verifying

1. Run `sudo reboot`. Within about 5 minutes, `http://<tailscale-ip>:8080/` loads, you can log in, and an existing job opens with its annotations.
2. Temporarily set `stop_cron` and then `start_cron` to a few minutes from now and run `terraform apply`. Check that:
   - the instance stops and `tailscale status` shows it offline;
   - it starts again with the **same** Tailscale IP;
   - CVAT is reachable.

   Then apply the real times.
3. The next morning, the "running" email should arrive around 06:20–06:25 IST.

## Things to tell users

- The server shuts down at **21:00 IST**. Saved annotations are safe. Imports, exports, or auto-annotation still running at 21:00 are stopped and have to be re-run.
- To start it outside hours, run `aws ec2 start-instances --instance-ids i-xxxx`. It still stops at 21:00.
