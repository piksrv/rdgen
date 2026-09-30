import os

# Public traffic is terminated by the host Nginx reverse proxy.  Keep the
# Gunicorn backend private so an accidental firewall change cannot expose it.
bind = "127.0.0.1:8000"
workers = 5  # The number of worker processes for concurrency (adjust based on system resources)
threads = 6
activate_base = True  # Activate your virtual environment if applicable

# Path to your Django project's main WSGI application file (usually manage.py)
wsgi_app = "rdgen.wsgi.application"