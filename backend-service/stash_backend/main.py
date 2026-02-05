from __future__ import annotations

import logging

from .api import create_app
from .config import load_settings
from .service_container import build_services

settings = load_settings()
logging.basicConfig(
    level=getattr(logging, settings.log_level, logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
services = build_services(settings)
app = create_app(services)
