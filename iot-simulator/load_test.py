import argparse
import json
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a bounded sensor-reading load to a local MecaniQA port-forward."
    )
    parser.add_argument("--url", default="http://127.0.0.1:8080/readings")
    parser.add_argument("--duration", type=int, default=30, help="Test duration in seconds (1-600)")
    parser.add_argument("--rate", type=int, default=25, help="Offered requests per second (1-1000)")
    parser.add_argument("--concurrency", type=int, default=8, help="Concurrent clients (1-64)")
    args = parser.parse_args()

    parsed_url = urlparse(args.url)
    allowed_hosts = {
        "127.0.0.1",
        "localhost",
        "::1",
        "iot-simulator",
        "iot-simulator.default.svc.cluster.local",
    }
    if parsed_url.scheme != "http" or parsed_url.hostname not in allowed_hosts:
        parser.error("--url must target loopback or the lab's iot-simulator Service")
    if not parsed_url.path.endswith("/readings"):
        parser.error("--url path must end in /readings")
    if not 1 <= args.duration <= 600:
        parser.error("--duration must be between 1 and 600 seconds")
    if not 1 <= args.rate <= 1000:
        parser.error("--rate must be between 1 and 1000 requests per second")
    if not 1 <= args.concurrency <= 64:
        parser.error("--concurrency must be between 1 and 64")
    return args


def main() -> None:
    args = parse_args()
    request_count = args.duration * args.rate
    start = time.monotonic()
    lock = threading.Lock()
    accepted = 0
    failed = 0
    next_index = 0
    sensor_types = ("engine_temperature", "electrical")

    def send_readings() -> None:
        nonlocal accepted, failed, next_index
        while True:
            with lock:
                index = next_index
                next_index += 1
            if index >= request_count:
                return

            due = start + index / args.rate
            if due - start >= args.duration:
                return
            delay = due - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            if time.monotonic() >= start + args.duration:
                return

            payload = {
                "sensor_type": sensor_types[index % len(sensor_types)],
                "value": 90.0 if index % 2 == 0 else 0.0,
                "fault_detected": index % 100 == 1,
            }
            request = Request(
                args.url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urlopen(request, timeout=5) as response:
                    succeeded = 200 <= response.status < 300
            except HTTPError:
                succeeded = False
            except (URLError, TimeoutError, OSError):
                succeeded = False

            with lock:
                if succeeded:
                    accepted += 1
                else:
                    failed += 1

    print(
        f"Sending at most {args.rate} requests/s for {args.duration}s "
        f"({request_count} requests) to local lab endpoint {args.url}"
    )
    with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        list(executor.map(lambda _: send_readings(), range(args.concurrency)))

    elapsed = time.monotonic() - start
    print(
        f"Completed in {elapsed:.1f}s: accepted={accepted}, "
        f"failed={failed}, achieved={accepted / elapsed:.1f} accepted requests/s"
    )
    if failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
