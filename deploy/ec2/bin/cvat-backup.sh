#!/bin/bash
# CVAT backup -> NAS (//192.168.0.32/robomy/cvat_backups), reached via the Tailscale subnet route on robomyserver-1.
# Every run: full DB dump + keys + .env (secrets like TAILSCALE_AUTH_KEY stripped) + row counts + media id list.
# Media: per-directory tars, only for dirs new/changed since last successful upload (fingerprint = count+bytes+max mtime).
# Models (serverless weights + cvat-models/): one tar, only when changed.
# If the NAS is unreachable, the run is kept locally under /var/backups/cvat and uploaded on the next successful run.
set -uo pipefail
umask 077   # dumps, keys and env contain secrets
exec 9>/run/cvat-backup.lock
flock -n 9 || { echo "backup already running"; exit 0; }

# NAS share + credentials live on the host only (not in git): /etc/cvat-backup.conf, mode 600, e.g.
#   NAS=//192.168.0.32/robomy
#   NASUSER='<user>%<password>'
#   ROOT=cvat_backups
CONF=/etc/cvat-backup.conf
[ -r "$CONF" ] || { echo "missing $CONF (NAS, NASUSER, ROOT)"; exit 1; }
. "$CONF"
: "${NAS:?set in $CONF}" "${NASUSER:?set in $CONF}"; ROOT=${ROOT:-cvat_backups}
REPO=/home/ubuntu/cvat_robolyze
MEDIA=/var/lib/docker/volumes/cvat_cvat_data/_data/data
STATE=/var/lib/cvat-backup; LOCAL=/var/backups/cvat
TS=$(date +%Y%m%d_%H%M); RUN=$LOCAL/runs/$TS
mkdir -p $STATE $RUN $LOCAL/media $LOCAL/models
touch $STATE/media.fp $STATE/models.fp
log(){ echo "$(date +%T) $*"; }
smb(){ timeout 3600 smbclient "$NAS" -U "$NASUSER" -c "$1" >/dev/null 2>&1; }

# ---- 1. DB, keys, env, counts (always full) ----
if docker ps --format '{{.Names}}' | grep -qx cvat_db; then
  docker exec cvat_db pg_dump -U root -d cvat | gzip -6 > $RUN/cvat_db.sql.gz || { log "pg_dump FAILED"; exit 1; }
  gzip -t $RUN/cvat_db.sql.gz && zcat $RUN/cvat_db.sql.gz | tail -5 | grep -q "dump complete" || { log "dump incomplete"; exit 1; }
  docker exec cvat_db psql -U root -d cvat -tAc "select 'tasks',count(*) from engine_task union all select 'jobs',count(*) from engine_job union all select 'shapes',count(*) from engine_labeledshape union all select 'tracks',count(*) from engine_labeledtrack union all select 'users',count(*) from auth_user union all select 'data',count(*) from engine_data" > $RUN/counts.txt
  docker exec cvat_db psql -U root -d cvat -tAc "select id from engine_data order by id" > $RUN/data_ids.txt
else
  log "cvat_db not running - skipping DB dump"; exit 1
fi
tar czf $RUN/cvat_keys.tar.gz -C /var/lib/docker/volumes/cvat_cvat_keys/_data .
grep -v -E '^(TAILSCALE_AUTH_KEY|TS_AUTHKEY)=' $REPO/.env > $RUN/env.txt; chmod 600 $RUN/env.txt
cp $REPO/docker-compose.override.yml $RUN/ 2>/dev/null || true
# host automation as actually installed (scripts + systemd units), so a rebuilt host can match it
tar czf $RUN/automation.tar.gz -C / opt/cvat $(cd / && ls etc/systemd/system/cvat*.service etc/systemd/system/cvat*.timer)
git -c safe.directory=$REPO -C $REPO rev-parse HEAD > $RUN/git_head.txt

# ---- 2. media: tar changed dirs ----
: > $RUN/media_changed.txt
for d in $(ls $MEDIA 2>/dev/null | sort -n); do
  fp="$d $(find $MEDIA/$d -type f -printf '%s %T@\n' | awk '{n++; s+=$1; if($2>m)m=$2} END {printf "%d-%d-%d", n, s, m}')"
  if ! grep -qx "$fp" $STATE/media.fp; then
    tar cf $LOCAL/media/data_$d.tar -C $MEDIA $d && echo "$fp" >> $RUN/media_changed.txt
  fi
done
log "media dirs changed: $(wc -l < $RUN/media_changed.txt)"

# ---- 3. models: tar when changed ----
mfp=$(cd $REPO && find serverless/pytorch/ultralytics cvat-models -type f -printf '%p %s %T@\n' 2>/dev/null | sort | sha256sum | cut -c1-16)
if [ "$(cat $STATE/models.fp)" != "$mfp" ]; then
  tar czf $LOCAL/models/models_$mfp.tar.gz -C $REPO serverless/pytorch/ultralytics cvat-models && echo "$mfp" > $RUN/models_changed.txt
fi

(cd $RUN && sha256sum * > MANIFEST.sha256)
echo "$TS" >> $STATE/pending_runs

# ---- 4. upload to NAS (all pending runs + media/model tars not yet uploaded) ----
if ! timeout 20 smbclient -L 192.168.0.32 -U "$NASUSER" >/dev/null 2>&1; then
  log "NAS UNREACHABLE - kept locally in $RUN"
  wc -l < $STATE/pending_runs > $STATE/NAS_PENDING
  # keep local disk bounded: last 10 runs
  ls -1d $LOCAL/runs/* | head -n -10 | xargs -r rm -rf
  exit 2
fi
smb "mkdir $ROOT; mkdir $ROOT/runs; mkdir $ROOT/media; mkdir $ROOT/models" || true
ok=1
for r in $(sort -u $STATE/pending_runs); do
  [ -d $LOCAL/runs/$r ] || continue
  # media tars referenced by this run
  if [ -s $LOCAL/runs/$r/media_changed.txt ]; then
    while read -r id _; do
      f=$LOCAL/media/data_$id.tar; [ -f $f ] || continue
      smb "cd $ROOT/media; lcd $LOCAL/media; put data_$id.tar" || { ok=0; break; }
      rsz=$(timeout 120 smbclient "$NAS" -U "$NASUSER" -c "cd $ROOT/media; ls data_$id.tar" 2>/dev/null | awk -v f=data_$id.tar '$1==f {print $3}')
      [ "$rsz" = "$(stat -c %s $f)" ] || { log "media verify FAILED data_$id"; ok=0; break; }
    done < $LOCAL/runs/$r/media_changed.txt
  fi
  [ $ok = 1 ] || break
  if [ -s $LOCAL/runs/$r/models_changed.txt ]; then
    m=$(cat $LOCAL/runs/$r/models_changed.txt)
    smb "cd $ROOT/models; lcd $LOCAL/models; put models_$m.tar.gz" || { ok=0; break; }
  fi
  smb "cd $ROOT/runs; mkdir $r; cd $r; lcd $LOCAL/runs/$r; prompt off; mput *" || { ok=0; break; }
  # verify sizes on NAS
  remote=$(timeout 120 smbclient "$NAS" -U "$NASUSER" -c "cd $ROOT/runs/$r; ls" 2>/dev/null | awk 'NF>=8 && $2 ~ /^[AHNRS]+$/ {print $1, $3}' | LC_ALL=C sort)
  local_l=$(cd $LOCAL/runs/$r && stat -c '%n %s' * | LC_ALL=C sort)
  [ "$remote" = "$local_l" ] || { log "verify FAILED for run $r"; ok=0; break; }
  # mark uploaded
  cat $LOCAL/runs/$r/media_changed.txt >> $STATE/media.fp
  [ -s $LOCAL/runs/$r/models_changed.txt ] && cp $LOCAL/runs/$r/models_changed.txt $STATE/models.fp
  grep -vx "$r" $STATE/pending_runs > $STATE/pending_runs.tmp; mv $STATE/pending_runs.tmp $STATE/pending_runs
  log "uploaded run $r"
done
# drop superseded fingerprints (keep latest per dir)
awk '{last[$1]=$0} END {for (k in last) print last[k]}' $STATE/media.fp | sort -n > $STATE/media.fp.tmp && mv $STATE/media.fp.tmp $STATE/media.fp

if [ $ok = 1 ]; then
  rm -f $STATE/NAS_PENDING
  rm -f $LOCAL/media/*.tar $LOCAL/models/*.tar.gz
  ls -1d $LOCAL/runs/* | head -n -3 | xargs -r rm -rf      # keep last 3 runs locally
  # ---- 5. NAS retention: keep 14 newest runs, + newest run of each of the last 8 Sundays, + first run of every month ----
  runs=$(timeout 120 smbclient "$NAS" -U "$NASUSER" -c "cd $ROOT/runs; ls" 2>/dev/null | awk '$1 ~ /^[0-9]{8}_[0-9]{4}$/ {print $1}' | sort)
  keep=$( { echo "$runs" | tail -14
            for r in $runs; do [ "$(date -d ${r:0:8} +%u)" = 7 ] && echo "${r:0:8} $r"; done | sort | awk '{l[$1]=$2} END {for (k in l) print l[k]}' | sort | tail -8
            echo "$runs" | awk '{m=substr($1,1,6); if (!(m in f)) {f[m]=$1; print $1}}'; } | sort -u)
  for r in $runs; do echo "$keep" | grep -qx "$r" || { smb "cd $ROOT/runs; deltree $r"; log "retention: removed $r"; }; done
  log "BACKUP OK $TS -> $NAS/$ROOT"
  date -Is > $STATE/last_success
  exit 0
fi
wc -l < $STATE/pending_runs > $STATE/NAS_PENDING
log "NAS upload incomplete - will retry next run"; exit 2
