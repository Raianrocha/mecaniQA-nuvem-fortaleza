import json
import math
import os
import random
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from time import perf_counter

from prometheus_client import Counter, Gauge, Histogram, start_http_server


API_PORT = int(os.getenv("API_PORT", "8080"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
SENSOR_COUNT = int(os.getenv("SENSOR_COUNT", "5000"))
CPU_WORK_ITERATIONS = int(os.getenv("CPU_WORK_ITERATIONS", "100"))
MEMORY_WORK_MB = int(os.getenv("MEMORY_WORK_MB", "0"))
PROCESSING_DELAY_SECONDS = float(os.getenv("PROCESSING_DELAY_SECONDS", "0"))
SIMULATED_ERROR_RATE = float(os.getenv("SIMULATED_ERROR_RATE", "0"))
SENSOR_TYPES = {"engine_temperature", "electrical"}

if (
    API_PORT < 1
    or METRICS_PORT < 1
    or SENSOR_COUNT < 1
    or CPU_WORK_ITERATIONS < 0
    or MEMORY_WORK_MB < 0
    or not 0 <= PROCESSING_DELAY_SECONDS <= 2
):
    raise ValueError("Invalid port, sensor count, or test workload setting")
if not 0 <= SIMULATED_ERROR_RATE <= 1:
    raise ValueError("SIMULATED_ERROR_RATE must be between 0 and 1")

READINGS = Counter(
    "mecaniqa_iot_readings_total",
    "Sensor readings processed, partitioned by sensor type.",
    ["sensor_type"],
)
READING_RESULTS = Counter(
    "mecaniqa_iot_reading_results_total",
    "Received sensor readings partitioned by processing outcome.",
    ["result"],
)
ELECTRICAL_FAULTS = Counter(
    "mecaniqa_iot_electrical_faults_total",
    "Electrical faults reported by accepted electrical sensor readings.",
)
DIAGNOSTICS_SUCCESS = Counter(
    "mecaniqa_iot_diagnostics_success_total",
    "Successfully completed simulated diagnostics.",
)
DIAGNOSTICS_ERRORS = Counter(
    "mecaniqa_iot_diagnostics_errors_total",
    "Simulated diagnostics completed with an error.",
)

ACTIVE_SENSORS = Gauge(
    "mecaniqa_iot_active_sensors",
    "Number of sensors represented by the simulator.",
)
ENGINE_TEMPERATURE = Gauge(
    "mecaniqa_iot_engine_temperature_celsius",
    "Most recently accepted engine temperature in degrees Celsius.",
)
PROCESSING_TIME = Histogram(
    "mecaniqa_iot_batch_processing_seconds",
    "Time spent processing one received sensor reading.",
)

ACTIVE_SENSORS.set(SENSOR_COUNT)
MEMORY_RESERVATION = bytearray(MEMORY_WORK_MB * 1024 * 1024)


class ReadingHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path != "/readings":
            self.send_error(404)
            return

        started_at = perf_counter()
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > 4096:
                self._record_error("client_error")
                self.send_error(400, "Invalid request size")
                return

            payload = json.loads(self.rfile.read(content_length))
            if not isinstance(payload, dict):
                self._record_error("client_error")
                self.send_error(400, "Expected a JSON object")
                return
            sensor_type = payload.get("sensor_type")
            value = payload.get("value")
            fault_detected = payload.get("fault_detected", False)
            if (
                sensor_type not in SENSOR_TYPES
                or isinstance(value, bool)
                or not isinstance(value, (int, float))
                or not math.isfinite(value)
                or not isinstance(fault_detected, bool)
            ):
                self._record_error("client_error")
                self.send_error(400, "Expected a supported sensor_type and numeric value")
                return

            if random.random() < SIMULATED_ERROR_RATE:
                self._record_error()
                DIAGNOSTICS_ERRORS.inc()
                self.send_error(503, "Simulated processing failure")
                return

            work = 0.0
            for index in range(CPU_WORK_ITERATIONS):
                work += math.sqrt(index + 1)
            if PROCESSING_DELAY_SECONDS:
                time.sleep(PROCESSING_DELAY_SECONDS)

            READINGS.labels(sensor_type=sensor_type).inc()
            READING_RESULTS.labels(result="success").inc()
            DIAGNOSTICS_SUCCESS.inc()
            if sensor_type == "engine_temperature":
                ENGINE_TEMPERATURE.set(value)
            elif fault_detected:
                ELECTRICAL_FAULTS.inc()
            self.send_response(202)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "accepted"}).encode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
            self._record_error("client_error")
            self.send_error(400, "Invalid JSON payload")
        except (BrokenPipeError, ConnectionResetError):
            self._record_error()
        finally:
            PROCESSING_TIME.observe(perf_counter() - started_at)

    @staticmethod
    def _record_error(result: str = "error") -> None:
        READING_RESULTS.labels(result=result).inc()

    def log_message(self, format_string: str, *args: object) -> None:
        return


def main() -> None:
    start_http_server(METRICS_PORT)
    server = ThreadingHTTPServer(("0.0.0.0", API_PORT), ReadingHandler)
    print(
        f"Accepting sensor readings on :{API_PORT}/readings; "
        f"Prometheus metrics on :{METRICS_PORT}/metrics",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
