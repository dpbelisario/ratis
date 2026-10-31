#!/bin/bash
# night.sh -- one wake of the daily cloud run. Window: 00:30-11:35 JST.
# In the window: recover the lab if the machine paused or restarted, then keep the machine
# busy for up to 115 minutes (status every 10 minutes, recovery if Docker or the scheduler
# dies). The session runs it as a background task: its exit wakes the session, which runs it
# again until it prints WINDOW-CLOSED. After 11:30 JST it exports the day once.
cd "$(dirname "$0")/.." || exit 1
export LAB_PROFILE=realtime
jst() { TZ=Asia/Tokyo date "$@"; }
day=$(jst +%Y%m%d)
now=$((10#$(jst +%H%M)))
healthy() { docker info >/dev/null 2>&1 && grep -qa scheduler-loop "/proc/$(cat state/scheduler.pid 2>/dev/null)/cmdline" 2>/dev/null; }
export_day() {
  [ -f "exports/lab-realtime-$day.tar.gz" ] && return 0
  docker info >/dev/null 2>&1 || ./scenario.sh ensure > logs/night-ensure.log 2>&1
  ./scenario.sh export "lab-realtime-$day" > /dev/null 2>&1
  find exports -name 'lab-realtime-*.tar.gz' -mtime +14 -delete   # keep two weeks
}
summary() {
  ./scenario.sh status 2>/dev/null | awk 'NR==1 {print} /call queue|completed\/s/ {print}' | tr -s ' ' | tr '\n' '|'
  echo
  grep "$(jst +%F)" logs/events.log | grep -E "scheduler: fire|done in|fault: O|restart: done|ensure|failed" | tail -4
}
if [ "$now" -ge 1130 ] || [ "$now" -lt 30 ]; then
  [ "$now" -ge 1130 ] && export_day
  echo "WINDOW-CLOSED $(jst '+%F %H:%M JST') export: $(ls "exports/lab-realtime-$day.tar.gz" 2>/dev/null || echo none)"
  exit 0
fi
healthy || ./scenario.sh ensure > logs/night-ensure.log 2>&1
# containers left in another profile (an accel test) or with old settings: recreate in realtime
[ "$(cat state/profile 2>/dev/null)" = realtime ] || ./scenario.sh up > logs/night-ensure.log 2>&1
end=$(( $(date +%s) + 115 * 60 ))
stop=$(date -d "$(jst +%F) 11:35 +0900" +%s)
[ "$stop" -lt "$end" ] && end=$stop
n=0
while [ "$(date +%s)" -lt "$end" ]; do
  healthy || { echo "$(jst '+%F %T JST') night: lab down, running ensure"; ./scenario.sh ensure > logs/night-ensure.log 2>&1; }
  if [ $((n % 10)) = 0 ]; then
    { echo "===== $(jst '+%F %T JST')"; ./scenario.sh status 2>&1; } >> logs/status-history.log
  fi
  n=$((n + 1))
  sleep 60
done
now=$((10#$(jst +%H%M)))
[ "$now" -ge 1130 ] && export_day
echo "NIGHT-OK $(jst '+%F %H:%M JST') $([ "$now" -ge 1130 ] && echo "export: exports/lab-realtime-$day.tar.gz")"
summary
