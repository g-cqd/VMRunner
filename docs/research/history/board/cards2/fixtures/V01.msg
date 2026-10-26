Hold an activity while a container runs and log where a stop spends its time

A stop of a running container took 72 s in the first real run, where the
design says a stop line, SIGTERM at 10 s and SIGKILL at 15 s. The stop
escalation is carried by timers on the main actor, and an app macOS thinks
idle (no window, never frontmost) gets App Nap, which coalesces timers. A
container workload held no activity, unlike a virtual machine.

The workload now begins a user-initiated activity once its runner started and
ends it when the runner ends or the workload is released. It is not
latency-critical and does not keep the Mac awake. A start that throws holds
nothing.

The process now logs, with the runner pid and no path or container text, the
stop line, the SIGTERM and SIGKILL of the escalation (with whether the runner
still ran), a kill, the runner exit with the state of its streams, the drain
wait running out, and the report of the run. The next real run can then show
which step lost the time.

