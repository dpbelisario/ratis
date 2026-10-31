#!/usr/bin/env bash
# scenario.sh -- drive the Ozone incident lab (read HANDOFF.md first).
#
#   ./scenario.sh up                  start the cluster (profile from LAB_PROFILE, default realtime)
#   ./scenario.sh seed [N]            pre-load N keys (default SEED_KEYS)
#   ./scenario.sh start               start the scheduler daemon (runs SCHEDULE on the lab clock)
#   ./scenario.sh stop                stop the scheduler and all client load
#   ./scenario.sh status              key metrics as a table (from Prometheus)
#   ./scenario.sh job01 | job10       run one job now (01:00 bulk delete / 10:00 write burst)
#   ./scenario.sh writer-on|writer-off  normal background traffic
#   ./scenario.sh fault-on [cpu|pause|delay] | fault-off   make the SCM leader slow / undo
#   ./scenario.sh restart             restart RESTART_TARGET (om-leader|scm-leader|om-all|none)
#   ./scenario.sh accel-day           compressed day: 1 real minute = 1 lab hour, then export
#   ./scenario.sh export [name]       Prometheus snapshot -> exports/<name>.tar.gz
#   ./scenario.sh replay <tar.gz>     view an export in a local Prometheus (9091) + Perses (8081)
#   ./scenario.sh check-panels        run every dashboard query, report empty ones
#   ./scenario.sh ensure              idempotent: up + seed if empty + scheduler running
#   ./scenario.sh clock | leaders | down | reset
#
# Settings: environment variables (see the defaults below), or put them in ./lab.env.
set -uo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$LAB_DIR" || exit 1
# shellcheck disable=SC1091
[ -f ./lab.env ] && . ./lab.env

: "${LAB_PROFILE:=realtime}"           # realtime (1 lab min = 1 real min) | accel (1 real min = 1 lab hour)
: "${LAB_TZ:=Asia/Tokyo}"              # the realtime lab clock
: "${SCHEDULE:=schedules/incident.conf}"
: "${SEC_PER_LAB_HOUR:=60}"            # accel only: real seconds per lab hour
: "${ACCEL_START:=00:00}"              # accel only: lab time when the scheduler starts
: "${ACCEL_END:=12:00}"                # accel only: scheduler stops at this lab time (empty = never)
: "${GRACE_MIN:=20}"                   # an event fires up to this many lab minutes after its time, not later
: "${VOLUME:=vol1}"
: "${BUCKET:=obs}"                     # obs (OBJECT_STORE) or fso (FILE_SYSTEM_OPTIMIZED)
: "${SEED_KEYS:=30000}"                # 30,000 lab keys ~ 6,000,000 production keys at 1:200
: "${SEED_THREADS:=20}"
: "${KEY_SIZE:=1024}"                  # bytes per key; key COUNT matters for OM/SCM, not bytes
: "${WRITER_INTERVAL:=10}"             # normal traffic: start one client every N real seconds ...
: "${WRITER_KEYS:=50}"                 # ... that writes this many keys ...
: "${WRITER_THREADS:=5}"               # ... with this many threads ...
: "${WRITER_MAX_CLIENTS:=8}"           # ... and at most this many clients alive (stuck clients pile up)
                                      # 8 x 5 threads = 8 waiting client threads per OM handler (production ~830/100)
: "${JOB01_THREADS:=10}"               # 01:00 bulk delete: delete threads per batch
: "${JOB01_PARALLEL:=8}"               # 01:00 bulk delete: batches deleted at the same time (1 JVM each)
: "${JOB01_KEYS:=60000}"              # 01:00 bulk delete: oldest written batches up to this many keys
                                      # (60,000 at 100 per minute keeps the delete backlog busy until ~11:00,
                                      #  like production's pending-delete backlog during the incident)
: "${JOB10_KEYS:=10000}"               # 10:00 burst: keys to write ...
: "${JOB10_THREADS:=40}"               # ... with this many threads
: "${FAULT_MODE:=scm-stuck}"           # scm-stuck | scm-ratis-stuck | scm-slow | cpu-all | cpu | followers | pause | delay
: "${FAULT_BLOCK_DELAY_MS:=2000}"       # scm-slow: sleep per SCM 9863 block call (5 handlers -> 2.5 calls/s max)
: "${FAULT_CPUS:=0.02}"                # cpu faults: CPUs left to each throttled SCM
: "${FAULT_DELAY:=500ms}"              # delay fault: added latency on the SCM leader's network
: "${RESTART_TARGET:=om-leader}"       # default target of "restart" (a schedule line can name one)
: "${RESTART_GRACE:=60}"               # seconds a stopping service gets before it is killed
: "${CLIENT_HEAP:=384m}"               # heap of each freon client JVM
: "${PROM_URL:=http://localhost:9090}"
# OM log lines that show OM -> SCM retries / failover (startup lines excluded)
FAILOVER_RE='failover attempts|Trying to failover|Failing over|NotLeaderException|LeaderNotReadyException|not the leader' 
export LAB_PROFILE

mkdir -p state/jobs state/clients state/metrics logs exports
chmod 755 state/metrics 2>/dev/null || true

# ---------- helpers ----------
dc() { docker compose "$@"; }
now_lab() { TZ="$LAB_TZ" date '+%F %T %Z'; }
log() { echo "$(now_lab) [$(lab_clock | cut -d' ' -f2)] $*" | tee -a logs/events.log >&2; }
die() { echo "error: $*" >&2; exit 1; }
cid() { dc ps -q "$1" 2>/dev/null; }
freon() {  # freon <args...>   runs in the client container (stdin from /dev/null: it is often
           # called inside "while read" loops, and docker compose exec would eat the loop's input)
  dc exec -T -e OZONE_HEAPSIZE_MAX="$CLIENT_HEAP" client ozone freon "$@" < /dev/null
}
succ() { sed -n 's/.*Successful executions: \([0-9]*\).*/\1/p' "$1" | tail -1; }

hm2min() { local h=${1%%:*} m=${1##*:}; echo $((10#$h * 60 + 10#$m)); }

# Lab clock: prints "<day> <HH:MM>". realtime: JST date and time. accel: virtual day and time.
lab_clock() {
  if [ "$LAB_PROFILE" = accel ]; then
    local t0 start el vmin
    t0=$(cat state/t0 2>/dev/null || date +%s)   # no t0 yet (before the scheduler starts) = lab ACCEL_START
    start=$(hm2min "$ACCEL_START")
    el=$(( $(date +%s) - t0 ))
    vmin=$(( start + el * 60 / SEC_PER_LAB_HOUR ))
    printf 'vday%d %02d:%02d\n' $((vmin / 1440)) $(((vmin % 1440) / 60)) $((vmin % 60))
  else
    TZ="$LAB_TZ" date '+%F %H:%M'
  fi
}

running() { local f="state/jobs/$1.pid"; [ -f "$f" ] && kill -0 "$(cat "$f")" 2>/dev/null; }
n_clients() {
  local n=0 f
  for f in state/clients/*.pid; do
    [ -e "$f" ] || continue
    if kill -0 "$(cat "$f")" 2>/dev/null; then n=$((n + 1)); else rm -f "$f"; fi
  done
  echo $n
}

# The pool lists written key batches ("prefix count") that the 01:00 job may delete.
pool_add() { ( flock 9; echo "$1 $2 ${3:-$BUCKET}" >> state/pool.txt ) 9> state/pool.lock; }
pool_take() { ( flock 9; [ -f state/pool.txt ] && cat state/pool.txt; : > state/pool.txt ) 9> state/pool.lock; }
pool_take_upto() {  # oldest whole batches until the next one would pass the limit (at least one batch)
  ( flock 9
    [ -f state/pool.txt ] || exit 0
    awk -v lim="$1" 'BEGIN {s = 0} { if (NR == 1 || s + $2 <= lim) { s += $2; print > "/dev/stdout" } else print > "state/pool.rest" }' state/pool.txt
    if [ -f state/pool.rest ]; then mv state/pool.rest state/pool.txt; else : > state/pool.txt; fi
  ) 9> state/pool.lock
}
pool_keys() { awk '{s += $2} END {print s + 0}' state/pool.txt 2>/dev/null || echo 0; }

leaders() {
  local scm om
  scm=$(timeout 90 docker compose exec -T client ozone admin scm roles 2>/dev/null | awk -F: '$3 == "LEADER" {print $1}')
  om=$(timeout 90 docker compose exec -T client ozone admin om roles -id omservice 2>/dev/null | awk '/LEADER/ {print $1}')
  echo "scm=${scm:-unknown} om=${om:-unknown}"
}
scm_leader() {  # from "ozone admin scm roles"; if SCM cannot answer, the SCM that served 9863 calls
  local l
  l=$(leaders | sed -n 's/.*scm=\([^ ]*\).*/\1/p')
  if [ -z "$l" ] || [ "$l" = unknown ]; then
    l=$(curl -s "$PROM_URL/api/v1/query" --data-urlencode 'query=topk(1, sum by (hostname) (increase(rpc_rpc_processing_time_num_ops{servername="ScmBlockLocationProtocolService"}[6h])))' |
        python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["metric"]["hostname"] if r else "unknown")')
  fi
  echo "$l"
}
om_leader() { leaders | sed -n 's/.*om=\([^ ]*\).*/\1/p'; }

write_metrics() {
  local f=state/metrics/.metrics.tmp hour fault=0 mode=none
  hour=$(lab_clock | awk '{split($2, a, ":"); printf "%.3f", a[1] + a[2] / 60}')
  if [ -s state/fault ]; then fault=1; mode=$(awk '{print $1}' state/fault); fi
  {
    echo "# HELP lab_clock_hour Lab clock (hour of day, JST in realtime profile, virtual in accel)."
    echo "# TYPE lab_clock_hour gauge"
    echo "lab_clock_hour{profile=\"$LAB_PROFILE\"} $hour"
    echo "# TYPE lab_job_running gauge"
    for j in seed job01 job10; do echo "lab_job_running{task=\"$j\"} $(running $j && echo 1 || echo 0)"; done
    echo "# TYPE lab_fault_active gauge"
    echo "lab_fault_active $fault"
    echo "# TYPE lab_writer_on gauge"
    echo "lab_writer_on $([ -f state/writer.on ] && echo 1 || echo 0)"
    echo "# TYPE lab_writer_clients gauge"
    echo "lab_writer_clients $(n_clients)"
    echo "# HELP lab_om_failover_log_lines_total OM log lines with SCM retry / failover / not-leader messages."
    echo "# TYPE lab_om_failover_log_lines_total counter"
    echo "lab_om_failover_log_lines_total $(cat state/failover.total 2>/dev/null || echo 0)"
    echo "# TYPE lab_pool_keys gauge"
    echo "lab_pool_keys $(pool_keys)"
  } > "$f" && chmod 644 "$f" && mv -f "$f" state/metrics/metrics
}

prom_targets_up() {
  curl -s "$PROM_URL/api/v1/targets" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(0); sys.exit()
print(sum(1 for t in d["data"]["activeTargets"] if t["health"] == "up" and t["labels"]["job"].startswith("ozone")))'
}

# ---------- cluster ----------
cmd_up() {
  write_metrics
  echo "$LAB_PROFILE" > state/profile
  log "up: profile=$LAB_PROFILE"
  dc up -d || die "docker compose up failed"
  local i n
  for i in $(seq 1 60); do
    n=$(prom_targets_up)
    [ "$n" = 7 ] && break
    sleep 5
  done
  [ "$n" = 7 ] || die "only $n/7 Ozone targets up after 5 min (docker compose ps; docker compose logs scm1 om1)"
  for i in $(seq 1 30); do
    dc exec -T client ozone sh volume info "/$VOLUME" >/dev/null 2>&1 && break
    dc exec -T client ozone sh volume create "/$VOLUME" >/dev/null 2>&1 && break
    sleep 5
  done
  dc exec -T client ozone sh bucket info "/$VOLUME/obs" >/dev/null 2>&1 ||
    dc exec -T client ozone sh bucket create "/$VOLUME/obs" --layout OBJECT_STORE
  dc exec -T client ozone sh bucket info "/$VOLUME/fso" >/dev/null 2>&1 ||
    dc exec -T client ozone sh bucket create "/$VOLUME/fso" --layout FILE_SYSTEM_OPTIMIZED
  log "up: 7/7 Ozone targets up, $(leaders)"
  echo "Perses:     http://localhost:8080/projects/ozone/dashboards/ozone-rpc"
  echo "Prometheus: http://localhost:9090"
}

cmd_seed() {
  local n=${1:-$SEED_KEYS} p
  p="seed-$(date +%s)"
  log "seed: start $n keys into /$VOLUME/$BUCKET prefix $p"
  echo $$ > state/jobs/seed.pid
  write_metrics
  freon ockg -v "$VOLUME" -b "$BUCKET" -p "$p" -n "$n" -t "$SEED_THREADS" -s "$KEY_SIZE" > "logs/seed-$p.log" 2>&1
  local ok
  ok=$(succ "logs/seed-$p.log")
  rm -f state/jobs/seed.pid
  [ "${ok:-0}" -gt 0 ] && pool_add "$p" "$n"
  log "seed: done, ${ok:-0}/$n keys written ($(grep -o 'Total execution time (sec): [0-9]*' "logs/seed-$p.log" | tail -1))"
  write_metrics
}

# ---------- jobs ----------
run_job() {  # run_job <name> <function>: background, pid file, log file
  local name=$1 fn=$2
  if running "$name"; then log "$name: still running from before, not started again"; return; fi
  ( "$fn" > "logs/$name-$(date +%Y%m%d-%H%M%S).log" 2>&1; rm -f "state/jobs/$name.pid"; write_metrics ) &
  echo $! > "state/jobs/$name.pid"
  write_metrics
}

job01_body() {  # the "01:00" bulk delete: the oldest written batches, up to JOB01_KEYS keys
  # obs bucket: one DeleteKey RPC per key (freon ockr), JOB01_PARALLEL batches at a time
  # fso bucket: one directory delete per batch (ozone fs -rm -r -skipTrash); the OM
  #             DirectoryDeletingService then moves the files to deletedTable in the background
  local list total=0 p n b nb
  list=$(mktemp)
  pool_take_upto "$JOB01_KEYS" > "$list"
  total=$(awk '{s += $2} END {print s + 0}' "$list"); nb=$(grep -c . "$list")
  log "job01: bulk delete of $total keys ($nb batches, $JOB01_PARALLEL at a time, $JOB01_THREADS threads each)"
  local t0=$SECONDS
  while read -r p n b <&3; do
    [ -n "$p" ] || continue
    b=${b:-$BUCKET}
    while [ "$(jobs -rp | wc -l)" -ge "$JOB01_PARALLEL" ]; do wait -n; done
    if [ "$b" = fso ]; then
      dc exec -T client ozone fs -rm -r -skipTrash "ofs://omservice/$VOLUME/$b/$p" < /dev/null > /dev/null 2>&1 &
    else
      freon ockr -v "$VOLUME" -b "$b" -p "$p" -n "$n" -t "$JOB01_THREADS" -f > /dev/null 2>&1 &
    fi
  done 3< "$list"
  wait
  rm -f "$list"
  log "job01: done in $((SECONDS - t0)) s"
}

job10_body() {  # the "10:00" write burst
  local p
  p="burst-$(date +%s)"
  log "job10: write burst $JOB10_KEYS keys, $JOB10_THREADS threads, prefix $p"
  local t0=$SECONDS f
  f=$(mktemp)
  freon ockg -v "$VOLUME" -b "$BUCKET" -p "$p" -n "$JOB10_KEYS" -t "$JOB10_THREADS" -s "$KEY_SIZE" 2>&1 | tee "$f"
  pool_add "$p" "$JOB10_KEYS"
  log "job10: done in $((SECONDS - t0)) s, $(succ "$f") keys"
  rm -f "$f"
}

cmd_job01() { run_job job01 job01_body; log "job01: started (log: logs/job01-*.log)"; }
cmd_job10() { run_job job10 job10_body; log "job10: started (log: logs/job10-*.log)"; }

# ---------- normal traffic ----------
writer_client() {
  local p
  p="w-$(date +%s%N | cut -c1-13)"
  (
    # -f: a failed key does not stop the client; like an application, it goes on and retries
    freon ockg -v "$VOLUME" -b "$BUCKET" -p "$p" -n "$WRITER_KEYS" -t "$WRITER_THREADS" -s "$KEY_SIZE" -f > "state/clients/$p.log" 2>&1
    [ "$(succ "state/clients/$p.log")" = "$WRITER_KEYS" ] || cp "state/clients/$p.log" logs/
    pool_add "$p" "$WRITER_KEYS"
    rm -f "state/clients/$p.log" "state/clients/$p.pid"
  ) &
  echo $! > "state/clients/$p.pid"
}
writer_tick() {  # called by the scheduler loop
  [ -f state/writer.on ] || return 0
  local last now
  last=$(cat state/writer.last 2>/dev/null || echo 0)
  now=$(date +%s)
  [ $((now - last)) -ge "$WRITER_INTERVAL" ] || return 0
  echo "$now" > state/writer.last
  if [ "$(n_clients)" -lt "$WRITER_MAX_CLIENTS" ]; then writer_client; fi
}
failover_tick() {  # every 30 s: count new OM failover log lines into state/failover.total
  local last now n total
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  last=$(cat state/failover.last 2>/dev/null || echo "$now")
  [ $(( $(date -d "$now" +%s) - $(date -d "$last" +%s) )) -ge 30 ] || { [ -f state/failover.last ] || echo "$now" > state/failover.last; return 0; }
  n=$(dc logs --since "$last" --until "$now" om1 om2 om3 2>/dev/null | grep -v STARTUP_MSG | grep -ciE "$FAILOVER_RE" || true)
  total=$(cat state/failover.total 2>/dev/null || echo 0)
  echo $((total + ${n:-0})) > state/failover.total
  echo "$now" > state/failover.last
}
cmd_writer_on() { touch state/writer.on; log "writer: on (1 client / ${WRITER_INTERVAL}s, $WRITER_KEYS keys x $WRITER_THREADS threads, max $WRITER_MAX_CLIENTS clients)"; write_metrics; }
cmd_writer_off() { rm -f state/writer.on; log "writer: off"; write_metrics; }

kill_load() {
  local f
  for f in state/clients/*.pid state/jobs/*.pid; do [ -e "$f" ] && kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
  dc exec -T client pkill -f org.apache.hadoop.ozone.freon 2>/dev/null || true
}

# ---------- faults ----------
cmd_fault_on() {
  # cpu:     throttle the SCM leader only (the followers may elect a new leader: failover helps)
  # cpu-all: throttle all 3 SCMs (the SCM state machine is slow everywhere: failover does not help)
  # pause:   freeze the SCM leader process
  # delay:   add network latency on the SCM leader (Linux/WSL with sch_netem only)
  # followers: freeze both SCM followers (the leader is up but cannot commit Ratis writes)
  # scm-slow: every 9863 AllocateScmBlock / DeleteScmKeyBlocks call sleeps FAULT_BLOCK_DELAY_MS
  #           inside the SCM handler (Byteman, byteman/scm-fault.btm); SCM stays healthy and leader
  # scm-stuck: every 9863 AllocateScmBlock / DeleteScmKeyBlocks call blocks until fault-off
  # scm-ratis-stuck: the SCM Ratis state machine stops applying transactions (all SCMs)
  local mode=${1:-$FAULT_MODE} leader targets s id pid
  [ -s state/fault ] && { log "fault: already on ($(cat state/fault))"; return; }
  if [ "$mode" = cpu-all ] || [ "$mode" = scm-slow ] || [ "$mode" = scm-stuck ] || [ "$mode" = scm-ratis-stuck ]; then
    targets="scm1 scm2 scm3"
  elif [ "$mode" = followers ]; then
    leader=$(scm_leader)
    [ -n "$leader" ] && [ "$leader" != unknown ] || { log "fault: cannot find the SCM leader"; return 1; }
    targets=$(echo scm1 scm2 scm3 | tr ' ' '\n' | grep -vx "$leader" | xargs)
  else
    leader=$(scm_leader)
    [ -n "$leader" ] && [ "$leader" != unknown ] || { log "fault: cannot find the SCM leader"; return 1; }
    targets=$leader
  fi
  for s in $targets; do
    id=$(cid "$s")
    case "$mode" in
      cpu|cpu-all) docker update --cpus "$FAULT_CPUS" "$id" >/dev/null ;;
      pause|followers) dc pause "$s" ;;
      scm-slow)
        dc exec -T "$s" sh -c "mkdir -p /tmp/lab-fault && echo $FAULT_BLOCK_DELAY_MS > /tmp/lab-fault/block-delay-ms.tmp &&
          echo $FAULT_BLOCK_DELAY_MS > /tmp/lab-fault/delete-delay-ms && mv /tmp/lab-fault/block-delay-ms.tmp /tmp/lab-fault/block-delay-ms" ;;
      scm-stuck) dc exec -T "$s" sh -c "mkdir -p /tmp/lab-fault && touch /tmp/lab-fault/hold" ;;
      scm-ratis-stuck) dc exec -T "$s" sh -c "mkdir -p /tmp/lab-fault && touch /tmp/lab-fault/apply-hold" ;;
      delay)
        pid=$(docker inspect -f '{{.State.Pid}}' "$id")
        sudo_if nsenter -t "$pid" -n tc qdisc add dev eth0 root netem delay "$FAULT_DELAY" ||
          { log "fault: netem failed (needs root, iproute2 and the sch_netem kernel module)"; return 1; } ;;
      *) die "unknown fault mode $mode (scm-stuck|scm-ratis-stuck|scm-slow|cpu|cpu-all|followers|pause|delay)" ;;
    esac
  done
  echo "$mode $targets" > state/fault
  log "fault: ON  mode=$mode on $targets ($(case $mode in cpu*) echo "cpus=$FAULT_CPUS";; scm-slow) echo "delay=${FAULT_BLOCK_DELAY_MS}ms per 9863 call";; scm-stuck) echo "9863 block calls held";; scm-ratis-stuck) echo "SCM state machine apply held";; delay) echo "delay=$FAULT_DELAY";; *) echo frozen;; esac))"
  write_metrics
}
cmd_fault_off() {
  [ -s state/fault ] || { log "fault: none active"; return 0; }
  local mode targets s id pid
  read -r mode targets < state/fault
  for s in $targets; do
    id=$(cid "$s")
    case "$mode" in
      cpu|cpu-all) docker update --cpus "$(nproc)" "$id" >/dev/null ;;
      pause|followers) dc unpause "$s" ;;
      scm-slow|scm-stuck|scm-ratis-stuck) dc exec -T "$s" rm -rf /tmp/lab-fault ;;
      delay) pid=$(docker inspect -f '{{.State.Pid}}' "$id"); sudo_if nsenter -t "$pid" -n tc qdisc del dev eth0 root ;;
    esac
  done
  : > state/fault
  log "fault: OFF mode=$mode on $targets"
  write_metrics
}
sudo_if() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }

cmd_restart() {  # stop with RESTART_GRACE seconds, then start; logs whether each stop was graceful
  local t=${1:-$RESTART_TARGET} svc x id code took t0
  case "$t" in
    none) log "restart: none"; return ;;
    om-leader) svc=$(om_leader) ;;
    scm-leader) svc=$(scm_leader) ;;
    om-all) svc="om1 om2 om3" ;;
    scm-all) svc="scm1 scm2 scm3" ;;
    *) svc=$t ;;
  esac
  log "restart: $t -> $svc (stop grace ${RESTART_GRACE}s)"
  t0=$(date +%s)
  # shellcheck disable=SC2086
  dc stop -t "$RESTART_GRACE" $svc > /dev/null 2>&1
  for x in $svc; do
    id=$(dc ps -a -q "$x"); code=$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null)
    took=$(( $(date -d "$(docker inspect -f '{{.State.FinishedAt}}' "$id")" +%s) - t0 ))
    log "restart: stop $x took ${took}s, exit $code $([ "$code" = 137 ] && echo "(KILLED: did not stop within ${RESTART_GRACE}s)" || echo "(graceful)")"
  done
  # shellcheck disable=SC2086
  dc start $svc > /dev/null 2>&1
  log "restart: done, $(leaders)"
}

# ---------- scheduler ----------
fire() {
  local action=$1 arg=${2:-}
  case "$action" in
    writer-on) cmd_writer_on ;;
    writer-off) cmd_writer_off ;;
    job01) cmd_job01 ;;
    job10) cmd_job10 ;;
    fault-on) cmd_fault_on $arg ;;
    fault-off) cmd_fault_off ;;
    restart) cmd_restart $arg ;;
    *) log "scheduler: unknown action $action" ;;
  esac
}

scheduler_loop() {
  set +u  # the loop runs unattended for days: an unset variable must not end it
  [ -f "$SCHEDULE" ] || die "no schedule file $SCHEDULE"
  [ "$LAB_PROFILE" = accel ] && date +%s > state/t0
  : > state/fired.txt
  local day hm nowm t action key first=1 endm=""
  [ "$LAB_PROFILE" = accel ] && [ -n "$ACCEL_END" ] && endm=$(hm2min "$ACCEL_END")
  log "scheduler: start profile=$LAB_PROFILE schedule=$SCHEDULE clock=$(lab_clock)"
  while true; do
    read -r day hm < <(lab_clock)
    nowm=$(hm2min "$hm")
    while read -r t action arg; do
      case "$t" in ''|\#*) continue ;; esac
      key="$day $t $action${arg:+ $arg}"
      grep -qxF "$key" state/fired.txt && continue
      local tm
      tm=$(hm2min "$t")
      [ "$nowm" -ge "$tm" ] || continue
      echo "$key" >> state/fired.txt
      if [ $((nowm - tm)) -gt "$GRACE_MIN" ] && [ "$action" != writer-on ]; then
        # started late, resumed after a pause, or the line was added later: do not run it now
        [ $first = 1 ] && log "scheduler: skip $t $action (already past when the scheduler started)" ||
          log "scheduler: skip $t $action (more than ${GRACE_MIN} min late)"
        continue
      fi
      log "scheduler: fire $t $action${arg:+ $arg}"
      # own subshell + stdin from /dev/null: an action that fails cannot stop the scheduler,
      # and docker compose exec cannot read the schedule file as its stdin
      ( fire "$action" "$arg" ) < /dev/null || log "scheduler: $t $action failed (exit $?)"
    done < "$SCHEDULE"
    first=0
    writer_tick
    failover_tick
    write_metrics
    if [ -n "$endm" ] && [ "${day#vday}" = 0 ] && [ "$nowm" -ge "$endm" ]; then
      log "scheduler: reached ACCEL_END $ACCEL_END, stopping"
      break
    fi
    sleep 2
  done
}

# a bare kill -0 is not enough: after a machine restart the old pid can belong to another process
sched_alive() { local p; p=$(cat state/scheduler.pid 2>/dev/null) && [ -n "$p" ] && grep -qa scheduler-loop "/proc/$p/cmdline" 2>/dev/null; }
cmd_start() {
  if sched_alive; then
    echo "scheduler already running (pid $(cat state/scheduler.pid))"; return 0
  fi
  echo "$LAB_PROFILE" > state/profile
  nohup setsid "$0" scheduler-loop >> logs/scheduler.log 2>&1 < /dev/null &
  echo $! > state/scheduler.pid
  log "scheduler: daemon started (pid $!), log logs/scheduler.log, events logs/events.log"
}
cmd_stop() {
  if [ -f state/scheduler.pid ]; then sched_alive && kill "$(cat state/scheduler.pid)" 2>/dev/null; rm -f state/scheduler.pid; fi
  rm -f state/writer.on
  kill_load
  log "stop: scheduler and client load stopped"
  write_metrics
}

# ---------- observe ----------
cmd_status() {
  PROM_URL="$PROM_URL" CLOCK="$(lab_clock)" PROFILE="$LAB_PROFILE" FAULT="$(cat state/fault 2>/dev/null)" \
  CLIENTS="$(n_clients)" POOL="$(pool_keys)" WRITER="$([ -f state/writer.on ] && echo on || echo off)" \
  JOBS="$(for j in seed job01 job10; do running $j && printf '%s ' $j; done)" \
  python3 - <<'EOF'
import json, os, urllib.parse, urllib.request
P = os.environ["PROM_URL"]
def q(expr):
    try:
        url = P + "/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        return json.load(urllib.request.urlopen(url, timeout=10))["data"]["result"]
    except Exception:
        return []
def by_host(expr):
    return {r["metric"].get("hostname", r["metric"].get("instance", "?")): float(r["value"][1]) for r in q(expr)}
def one(expr):
    r = q(expr)
    return float(r[0]["value"][1]) if r else float("nan")
OM = 'job="ozone-om",port="9862"'
SCM = 'job="ozone-scm",servername="ScmBlockLocationProtocolService"'
rows = [
    ("call queue", f"rpc_call_queue_length{{{OM}}}", f"rpc_call_queue_length{{{SCM}}}"),
    ("busy handlers", f"rpc_num_in_process_handler{{{OM}}}", f"rpc_num_in_process_handler{{{SCM}}}"),
    ("completed/s", f"rate(rpc_rpc_processing_time_num_ops{{{OM}}}[1m])", f"rate(rpc_rpc_processing_time_num_ops{{{SCM}}}[1m])"),
    ("avg queue ms", f"rpc_rpc_queue_time_avg_time{{{OM}}}", f"rpc_rpc_queue_time_avg_time{{{SCM}}}"),
    ("avg proc ms", f"rpc_rpc_processing_time_avg_time{{{OM}}}", f"rpc_rpc_processing_time_avg_time{{{SCM}}}"),
    ("open conns", f"rpc_num_open_connections{{{OM}}}", f"rpc_num_open_connections{{{SCM}}}"),
]
hosts = ["om1", "om2", "om3", "scm1", "scm2", "scm3"]
print(f"lab clock {os.environ['CLOCK']} ({os.environ['PROFILE']})  fault: {os.environ['FAULT'] or 'none'}  "
      f"writer: {os.environ['WRITER']} ({os.environ['CLIENTS']} clients)  jobs: {os.environ['JOBS'] or '-'}  pool: {os.environ['POOL']} keys")
print(f"{'':16}" + "".join(f"{h:>9}" for h in hosts) + "    (OM port 9862 | SCM port 9863)")
for name, oq, sq in rows:
    v = by_host(oq); v.update(by_host(sq))
    print(f"{name:16}" + "".join(f"{v[h]:9.1f}" if h in v else f"{'-':>9}" for h in hosts))
def rate_type(t):
    c = one(f'sum(rate(scm_block_location_protocol_counter{{type="{t}"}}[1m]))')
    ms = one(f'sum(rate(scm_block_location_protocol_time{{type="{t}"}}[1m])) / sum(rate(scm_block_location_protocol_counter{{type="{t}"}}[1m]))')
    return f"{c:8.2f}/s  avg {ms:8.1f} ms" if ms == ms else f"{c:8.2f}/s"
print("delete path / SCM:")
print(f"  OM key deletes/s (max host)     {one('max(rate(om_metrics_num_key_deletes[1m]))'):10.1f}")
print(f"  OM key commits/s (max host)     {one('max(rate(om_metrics_num_key_commits[1m]))'):10.1f}")
print(f"  OM deletedTable keys (max)      {one('max(rocksdb_om_db_deletedtable_estimate_num_keys)'):10.0f}")
print(f"  KeyDeletingService sent/s       {one('max(rate(deleting_service_metrics_num_keys_sent_for_purge[1m]))'):10.1f}")
print(f"  FSO: files moved by DirDeleting/s {one('max(rate(deleting_service_metrics_num_sub_files_moved_to_deleted_table[1m]))'):8.1f}  deletedDirectoryTable {one('max(rocksdb_om_db_deleteddirectorytable_estimate_num_keys)'):6.0f}")
print(f"  SCM DeleteScmKeyBlocks          {rate_type('DeleteScmKeyBlocks')}")
print(f"  SCM AllocateScmBlock            {rate_type('AllocateScmBlock')}")
print(f"  SCM deletedBlocks table (max)   {one('max(rocksdb_scm_db_deletedblocks_estimate_num_keys)'):10.0f}")
print(f"  SCM block-delete tx created/s   {one('sum(rate(scm_block_deleting_service_num_block_deletion_transaction_created[1m]))'):10.2f}")
lag = one('max(scalar(max(ratis_server_peerCommitIndex{job="ozone-scm"})) - ratis_state_machine_applyCompletedIndex{job="ozone-scm"})')
el_scm = one('sum(ratis_leader_election_electionCount{job="ozone-scm"})')
el_om = one('sum(ratis_leader_election_electionCount{job="ozone-om"})')
up = one('count(up{job=~"ozone.*"} == 1)')
print(f"  SCM Ratis apply lag (max)       {lag:10.0f}")
print(f"  leader elections (SCM, OM sum)  {el_scm:6.0f} {el_om:6.0f}")
print(f"  Ozone targets up                {up:10.0f} / 7")
EOF
  local fo
  fo=$(dc logs --since 5m om1 om2 om3 2>/dev/null | grep -v STARTUP_MSG | grep -ciE "$FAILOVER_RE" || true)
  echo "  OM log lines with failover/not-leader (last 5 min, all OMs): $fo"
}

cmd_check_panels() {
  local bad=0 total=0 title query n
  while IFS=$'\t' read -r title query; do
    total=$((total + 1))
    n=$(curl -s "$PROM_URL/api/v1/query" --data-urlencode "query=$query" |
        python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d["data"]["result"]) if d.get("status")=="success" else "ERR " + d.get("error",""))')
    if [ "$n" = 0 ] || [ "${n#ERR}" != "$n" ]; then bad=$((bad + 1)); printf 'EMPTY  %-50s %s\n' "$title" "$n"; else printf 'ok %3s %s\n' "$n" "$title"; fi
  done < <(python3 perses/make-dashboard.py --list-queries)
  echo "$((total - bad))/$total queries return series"
}

# ---------- export / replay ----------
cmd_export() {
  local name=${1:-lab-$LAB_PROFILE-$(TZ="$LAB_TZ" date +%Y%m%d-%H%M)} snap tmp
  snap=$(curl -s -XPOST "$PROM_URL/api/v1/admin/tsdb/snapshot" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["name"])') ||
    die "snapshot failed (is Prometheus up with --web.enable-admin-api?)"
  tmp=$(mktemp -d)
  mkdir -p "$tmp/$name/tsdb"
  dc exec -T prometheus tar -C "/prometheus/snapshots/$snap" -cf - . | tar -C "$tmp/$name/tsdb" -xf -
  dc exec -T prometheus rm -rf "/prometheus/snapshots/$snap"
  cp logs/events.log "$tmp/$name/events.log" 2>/dev/null || true
  cp "$SCHEDULE" "$tmp/$name/schedule.conf"
  { echo "profile=$LAB_PROFILE"; echo "lab_tz=$LAB_TZ"; echo "exported_at=$(now_lab)"; } > "$tmp/$name/run.txt"
  tar -C "$tmp" -czf "exports/$name.tar.gz" "$name"
  rm -rf "$tmp"
  echo "exports/$name.tar.gz ($(du -h "exports/$name.tar.gz" | cut -f1))"
}

cmd_replay() {
  local f=${1:-} name
  [ -f "$f" ] || die "usage: $0 replay exports/<name>.tar.gz"
  name=$(tar -tzf "$f" | head -1 | cut -d/ -f1)
  docker compose -f docker-compose.replay.yaml -p ozone-replay down >/dev/null 2>&1 || true
  rm -rf replay/data && mkdir -p replay/data
  tar -C replay -xzf "$f" && mv "replay/$name/tsdb"/* replay/data/ && cp "replay/$name/events.log" replay/ 2>/dev/null
  rm -rf "replay/$name"
  chmod -R a+rwX replay/data
  docker compose -f docker-compose.replay.yaml -p ozone-replay up -d || die "replay stack failed"
  local i r
  for i in $(seq 1 30); do
    r=$(curl -s 'http://localhost:9091/api/v1/query' --data-urlencode 'query=min_over_time(timestamp(up{job="ozone-om"})[30d:1m])' 2>/dev/null) && echo "$r" | grep -q '"result":\[{' && break
    sleep 2
  done
  LAB_TZ="$LAB_TZ" python3 - "$r" <<'EOF'
import json, os, sys, time
from datetime import datetime
from zoneinfo import ZoneInfo
try:
    res = json.loads(sys.argv[1])["data"]["result"]
except Exception:
    res = []
print("Replay Prometheus: http://localhost:9091   (no scraping, data from the export only)")
if res:
    import urllib.parse, urllib.request
    start = min(float(r["value"][1]) for r in res)
    q = 'max_over_time(timestamp(up{job="ozone-om"})[30d:1m])'
    u = "http://localhost:9091/api/v1/query?" + urllib.parse.urlencode({"query": q})
    end = max(float(r["value"][1]) for r in json.load(urllib.request.urlopen(u))["data"]["result"])
    tz = ZoneInfo(os.environ["LAB_TZ"])
    fmt = lambda t: datetime.fromtimestamp(t, tz).strftime("%Y-%m-%d %H:%M %Z")
    print(f"Data from {fmt(start)} to {fmt(end)}")
    print(f"Perses: http://localhost:8081/projects/ozone/dashboards/ozone-rpc?start={int(start*1000)}&end={int(end*1000)}")
else:
    print("Perses: http://localhost:8081/projects/ozone/dashboards/ozone-rpc  (set the time range to the run)")
EOF
  [ -f replay/events.log ] && { echo "Events in this run (replay/events.log):"; grep -E 'scheduler: fire|done|fault|restart' replay/events.log | tail -20; }
}

cmd_ensure() {  # cloud helper: safe to run any number of times, also after the machine rebooted
  local rebooted=0 fault_mode=""
  docker info >/dev/null 2>&1 || {
    echo "starting dockerd"
    rebooted=1
    (setsid nohup dockerd > /var/log/dockerd.log 2>&1 &)
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
  }
  [ -s state/fault ] && fault_mode=$(awk '{print $1}' state/fault)
  if [ $rebooted = 1 ]; then
    # after a reboot, containers that docker restarts by itself can come back without their
    # network (no DNS): recreate them all; the data stays in the volumes
    log "ensure: dockerd was down (machine restarted); recreating the containers"
    dc up -d --force-recreate
    : > state/fault   # the fault flags lived inside the old containers
    rm -f state/scheduler.pid   # the old scheduler died with the machine
  fi
  if [ "$(prom_targets_up)" != 7 ]; then cmd_up; fi
  if [ -n "$fault_mode" ] && [ ! -s state/fault ]; then
    log "ensure: re-applying the fault that was on before ($fault_mode)"
    cmd_fault_on "$fault_mode"
  fi
  if [ ! -s state/pool.txt ] && ! running job01 && [ ! -f state/seeded ]; then cmd_seed && touch state/seeded; fi
  cmd_start
  cmd_status
}

cmd_accel_day() {
  export LAB_PROFILE=accel
  rm -f state/t0
  [ "$(cat state/profile 2>/dev/null)" = accel ] && [ "$(prom_targets_up)" = 7 ] || cmd_up
  [ "$(pool_keys)" -gt 0 ] || cmd_seed
  log "accel-day: lab $ACCEL_START -> $ACCEL_END, 1 lab hour = $SEC_PER_LAB_HOUR s, schedule $SCHEDULE"
  "$0" scheduler-loop >> logs/scheduler.log 2>&1 &
  local sp=$!
  echo $sp > state/scheduler.pid
  while kill -0 $sp 2>/dev/null; do
    sleep 60
    echo "================ $(lab_clock)"; cmd_status
  done
  rm -f state/scheduler.pid state/writer.on state/t0
  kill_load
  cmd_fault_off >/dev/null 2>&1
  cmd_export "lab-accel-$(TZ="$LAB_TZ" date +%Y%m%d-%H%M)"
}

cmd_down() { cmd_stop >/dev/null 2>&1; dc down; }
cmd_reset() { cmd_stop >/dev/null 2>&1; dc down -v; rm -rf state/* logs/*; mkdir -p state/metrics; }

case "${1:-help}" in
  up) cmd_up ;;
  down) cmd_down ;;
  reset) cmd_reset ;;
  seed) shift; cmd_seed "$@" ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  scheduler-loop) scheduler_loop ;;
  status) cmd_status ;;
  job01) cmd_job01 ;;
  job10) cmd_job10 ;;
  writer-on) cmd_writer_on ;;
  writer-off) cmd_writer_off ;;
  fault-on) shift; cmd_fault_on "$@" ;;
  fault-off) cmd_fault_off ;;
  restart) shift; cmd_restart "$@" ;;
  accel-day) cmd_accel_day ;;
  export) shift; cmd_export "$@" ;;
  replay) shift; cmd_replay "$@" ;;
  check-panels) cmd_check_panels ;;
  ensure) cmd_ensure ;;
  clock) lab_clock ;;
  leaders) leaders ;;
  *) sed -n '2,22p' "$0"; exit 1 ;;
esac
