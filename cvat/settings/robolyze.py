# Copyright (C) Robolyze
#
# SPDX-License-Identifier: MIT
"""Production settings + a real email backend.

CVAT deliberately leaves EMAIL_BACKEND = None (cvat/settings/base.py), so organization invitations
and password resets fail with "Email backend is not configured." Upstream's email_settings.py is not
usable here: it hardcodes the console backend and forces mandatory verification.

Everything below is read from the environment (see components/email/docker-compose.email.yml and
the host .env), so no credentials live in this file. Activate with:
    DJANGO_SETTINGS_MODULE=cvat.settings.robolyze
"""

import os

from cvat.settings.production import *  # pylint: disable=wildcard-import
from attr.converters import to_bool

# --- SMTP -------------------------------------------------------------------
EMAIL_BACKEND = os.getenv("EMAIL_BACKEND", "django.core.mail.backends.smtp.EmailBackend")
EMAIL_HOST = os.getenv("EMAIL_HOST", "smtp.gmail.com")
EMAIL_PORT = int(os.getenv("EMAIL_PORT", 587))
EMAIL_USE_TLS = to_bool(os.getenv("EMAIL_USE_TLS", True))
EMAIL_USE_SSL = to_bool(os.getenv("EMAIL_USE_SSL", False))
EMAIL_HOST_USER = os.getenv("EMAIL_HOST_USER", "")
EMAIL_HOST_PASSWORD = os.getenv("EMAIL_HOST_PASSWORD", "")
# Keep a hung SMTP server from hanging a web request (invitations are sent synchronously).
EMAIL_TIMEOUT = int(os.getenv("EMAIL_TIMEOUT", 20))

DEFAULT_FROM_EMAIL = os.getenv("DEFAULT_FROM_EMAIL") or EMAIL_HOST_USER
SERVER_EMAIL = os.getenv("SERVER_EMAIL") or DEFAULT_FROM_EMAIL

# --- allauth ----------------------------------------------------------------
# "optional" sends a verification mail but never blocks login, so existing users with unverified
# addresses keep working. Set ACCOUNT_EMAIL_VERIFICATION=mandatory only after they are verified.
ACCOUNT_EMAIL_VERIFICATION = os.getenv("ACCOUNT_EMAIL_VERIFICATION", "optional")
# base.py only configures ACCOUNT_LOGIN_METHODS; make sign-up collect an address as well, otherwise
# verification and password reset have nothing to send to.
ACCOUNT_SIGNUP_FIELDS = ["email*", "username*", "password1*", "password2*"]
