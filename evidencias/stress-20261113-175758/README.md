# MecaniQA stress test evidence

- Run: 20261113-175758
- Kubernetes context: docker-desktop
- Target: http://iot-simulator:8080/readings inside the local cluster only.
- Phases: CPU/error injection (480s, 150 req/s, concurrency 32); memory/latency injection (480s, 50 req/s, concurrency 64).
- Injection parameters are lab-only and the captured simulator environment is restored by the script.
- Phase results: [{"Name":"cpu-memory-errors","Phase":"Failed","ExpectedFailures":true},{"Name":"latency","Phase":"Succeeded","ExpectedFailures":false}]
- Grafana alert names observed firing: IoT reading error ratio above 5%, IoT simulator CPU above 80% of request
- Expected alert names not observed firing: IoT simulator memory above 85% of request, IoT reading p95 processing latency above 800ms
- Review hpa-watch.log, pods-watch.log, both *-top-pods.log files, load logs, events, grafana-alert-states.jsonl, and final resources.
- Grafana alert-state snapshots are captured every 30 seconds; configured or: 5m rules may need evaluation time during a phase.

