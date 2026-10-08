import os
import random
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server


METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
READINGS_PER_SECOND = int(os.getenv("READINGS_PER_SECOND", "1000"))
SENSOR_COUNT = int(os.getenv("SENSOR_COUNT", "5000"))

if READINGS_PER_SECOND < 1 or SENSOR_COUNT < 1:
    raise ValueError("READINGS_PER_SECOND and SENSOR_COUNT must be positive")

READINGS = Counter(
    "mecaniqa_iot_readings_total",
    "Sensor readings processed, partitioned by sensor type.",
    ["sensor_type"],
)
ELECTRICAL_FAULTS = Counter(
    "mecaniqa_iot_electrical_faults_total",
    "Electrical faults detected by the simulator.",
)
ACTIVE_SENSORS = Gauge(
    "mecaniqa_iot_active_sensors",
    "Number of sensors currently sending readings.",
)
ENGINE_TEMPERATURE = Gauge(
    "mecaniqa_iot_engine_temperature_celsius",
    "Most recently simulated engine temperature in degrees Celsius.",
)
PROCESSING_TIME = Histogram(
    "mecaniqa_iot_batch_processing_seconds",
    "Time spent processing one batch of sensor readings.",
)


def simulate_batch() -> None:
    started_at = time.perf_counter()
    temperature_readings = 0
    electrical_readings = 0
    detected_faults = 0

    for _ in range(READINGS_PER_SECOND):
        if random.random() < 0.5:
            temperature_readings += 1
            ENGINE_TEMPERATURE.set(random.uniform(70.0, 115.0))
        else:
            electrical_readings += 1
            if random.random() < 0.01:
                detected_faults += 1

    READINGS.labels(sensor_type="engine_temperature").inc(temperature_readings)
    READINGS.labels(sensor_type="electrical").inc(electrical_readings)
    ELECTRICAL_FAULTS.inc(detected_faults)
    ACTIVE_SENSORS.set(SENSOR_COUNT)
    PROCESSING_TIME.observe(time.perf_counter() - started_at)


def main() -> None:
    ACTIVE_SENSORS.set(SENSOR_COUNT)
    start_http_server(METRICS_PORT)
    print(f"Serving Prometheus metrics on :{METRICS_PORT}/metrics", flush=True)

    while True:
        cycle_started_at = time.monotonic()
        simulate_batch()
        time.sleep(max(0.0, 1.0 - (time.monotonic() - cycle_started_at)))


if __name__ == "__main__":
    main()