from pathlib import Path

from dotenv import load_dotenv
import os

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

SECRET_KEY = os.getenv("DJANGO_SECRET_KEY", "dev-only-secret-change-me")
DEBUG = True
ALLOWED_HOSTS = ["localhost", "127.0.0.1"]

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "signing",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "portal.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "portal.wsgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
    }
}

AUTH_PASSWORD_VALIDATORS = []

LANGUAGE_CODE = "en-us"
TIME_ZONE = "UTC"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"

# The signing ceremony runs in an iframe on our own pages; DocuSign redirects
# the frame back to /callback, which must be frameable by our own origin.
X_FRAME_OPTIONS = "SAMEORIGIN"

LOGIN_URL = "login"
LOGIN_REDIRECT_URL = "dashboard"
LOGOUT_REDIRECT_URL = "login"

# --- Integration settings -------------------------------------------------
SF_ORG_ALIAS = os.getenv("SF_ORG_ALIAS", "plaid")
PORTAL_BASE_URL = os.getenv("PORTAL_BASE_URL", "http://localhost:8000")

DOCUSIGN = {
    "INTEGRATION_KEY": os.getenv("DS_INTEGRATION_KEY", ""),
    "USER_ID": os.getenv("DS_USER_ID", ""),
    "ACCOUNT_ID": os.getenv("DS_ACCOUNT_ID", ""),
    "PRIVATE_KEY_PATH": str(BASE_DIR / os.getenv("DS_PRIVATE_KEY_PATH", "private.key")),
    "AUTH_SERVER": os.getenv("DS_AUTH_SERVER", "account-d.docusign.com"),
    "BASE_PATH": os.getenv("DS_BASE_PATH", "https://demo.docusign.net/restapi"),
}
