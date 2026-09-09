FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["gunicorn", \
     "--workers", "1", \
     "--threads", "8", \
     "--timeout", "300", \
     "--bind", "0.0.0.0:5051", \
     "api.app:create_app()"]
