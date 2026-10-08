FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY simulator.py .

EXPOSE 8000
USER 10001:10001

CMD ["python", "simulator.py"]