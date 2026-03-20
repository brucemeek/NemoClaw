FROM python:3.11-alpine

WORKDIR /app
COPY docker/dashboard-shortcut.py /app/dashboard-shortcut.py

CMD ["python3", "/app/dashboard-shortcut.py"]