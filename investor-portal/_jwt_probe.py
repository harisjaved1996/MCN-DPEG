import os

import django

os.environ.setdefault("DJANGO_SETTINGS_MODULE", "portal.settings")
django.setup()

from django.conf import settings
from signing.services import docusign_client

try:
    client = docusign_client._api_client()
    print("JWT AUTH: OK")
    # Verify the account id from userinfo (screenshot was slightly cut off).
    user_info = client.get_user_info(docusign_client._token_cache["token"])
    for account in user_info.accounts:
        print("account:", account.account_id, "|", account.account_name,
              "| default:", account.is_default, "| base:", account.base_uri)
        if account.account_id.lower() != settings.DOCUSIGN["ACCOUNT_ID"].lower() and account.is_default == "true":
            print(">>> .env DS_ACCOUNT_ID mismatch — should be:", account.account_id)
except Exception as exc:
    print("FAILED:", exc)
