from django.conf import settings
from django.db import models


class InvestorProfile(models.Model):
    """Maps a portal login to its Salesforce Contact."""

    user = models.OneToOneField(
        settings.AUTH_USER_MODEL, on_delete=models.CASCADE, related_name="investor_profile"
    )
    contact_id = models.CharField(max_length=18, unique=True)
    sf_email = models.EmailField()

    def __str__(self):
        return f"{self.user.username} -> {self.contact_id}"
