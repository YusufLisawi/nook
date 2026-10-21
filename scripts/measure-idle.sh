#!/bin/bash
# Read-only measurement. The lead starts ONE review copy manually; this script never launches Nook.
set -euo pipefail
if [[ ${1:-} == --help || $# -lt 1 ]]; then
  echo 'Usage: scripts/measure-idle.sh PID [seconds=30] [output-directory]'
  echo 'Quit the installed copy, start build/Build/Products/Release/Nook.app manually, close the notch, wait 30s, then measure its PID.'
  echo 'Captures CPU, interrupt/package wakeups per second, phys_footprint, top, footprint, sample, and timer stack evidence. Never uses sudo.'
  exit 0
fi
measure_pid=$1
measure_seconds=${2:-30}
[[ $measure_pid =~ ^[0-9]+$ && $measure_seconds =~ ^[0-9]+$ ]] || { echo 'PID and seconds must be positive integers.' >&2; exit 2; }
(( measure_pid > 0 && measure_seconds >= 1 && measure_seconds <= 600 )) || exit 2
measure_root=$(cd "$(dirname "$0")/.." && pwd -P)
measure_output=${3:-$(mktemp -d /tmp/nook-idle.XXXXXX)}
mkdir -p "$measure_output"
measure_output=$(cd "$measure_output" && pwd -P)
cat > "$measure_output/probe.c" <<'C'
#include <libproc.h>
#include <sys/resource.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    pid_t pid = (pid_t)atoi(argv[1]);
    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) { perror("proc_pidpath"); return 1; }
    if (strcmp(path, argv[3]) != 0) { fprintf(stderr, "Refusing process outside the built review app: %s\n", path); return 2; }
    struct rusage_info_v2 a = {0}, b = {0};
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&a) != 0) { perror("proc_pid_rusage"); return 1; }
    struct timespec begin, end, delay = {.tv_sec = atoi(argv[2])};
    clock_gettime(CLOCK_MONOTONIC, &begin);
    while (nanosleep(&delay, &delay) != 0) {}
    clock_gettime(CLOCK_MONOTONIC, &end);
    if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&b) != 0) { perror("proc_pid_rusage"); return 1; }
    if (a.ri_proc_start_abstime != b.ri_proc_start_abstime) { fprintf(stderr, "Process changed during measurement\n"); return 1; }
    double elapsed = (double)(end.tv_sec - begin.tv_sec) + (double)(end.tv_nsec - begin.tv_nsec) / 1e9;
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    double cpu = (double)((b.ri_user_time - a.ri_user_time) + (b.ri_system_time - a.ri_system_time)) * timebase.numer / timebase.denom / 1e9 / elapsed * 100;
    printf("{\"pid\":%d,\"seconds\":%.3f,\"cpu_percent_one_core\":%.3f,\"interrupt_wakeups_per_second\":%.3f,\"package_idle_wakeups_per_second\":%.3f,\"footprint_start_bytes\":%llu,\"footprint_end_bytes\":%llu}\n",
           pid, elapsed, cpu, (double)(b.ri_interrupt_wkups - a.ri_interrupt_wkups) / elapsed,
           (double)(b.ri_pkg_idle_wkups - a.ri_pkg_idle_wkups) / elapsed,
           (unsigned long long)a.ri_phys_footprint, (unsigned long long)b.ri_phys_footprint);
    return 0;
}
C
xcrun clang -O2 -Wall -Wextra -Werror "$measure_output/probe.c" -o "$measure_output/probe"
# CPU/wakeups first; sampling/footprint instrumentation would otherwise perturb this interval.
"$measure_output/probe" "$measure_pid" "$measure_seconds" "$measure_root/build/Build/Products/Release/Nook.app/Contents/MacOS/Nook" | tee "$measure_output/metrics.json"
top -l 2 -s 2 -pid "$measure_pid" -stats pid,command,cpu,mem,threads,idlew > "$measure_output/top.txt"
footprint -p "$measure_pid" > "$measure_output/footprint.txt" 2>&1 || true
sample "$measure_pid" 5 10 -file "$measure_output/sample.txt" > "$measure_output/sample-command.txt" 2>&1 || true
if [[ -f $measure_output/sample.txt ]]; then
  rg 'Timer|timer|poll|tick|NSMetadataQuery|NotchController' "$measure_output/sample.txt" > "$measure_output/timer-stacks.txt" || true
fi
# sample reveals timer stacks observed during sampling, not a definitive count of registered timers.
echo "Measurements: $measure_output"
