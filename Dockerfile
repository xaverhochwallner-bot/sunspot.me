FROM python:3.11-slim

WORKDIR /app

COPY sunspot_server/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY sunspot_server/ .

CMD ["python", "main.py"]
