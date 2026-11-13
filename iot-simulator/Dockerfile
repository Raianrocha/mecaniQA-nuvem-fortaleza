FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY simulator.py load_test.py ./

EXPOSE 8080 8000
USER 10001:10001

CMD ["python", "simulator.py"]