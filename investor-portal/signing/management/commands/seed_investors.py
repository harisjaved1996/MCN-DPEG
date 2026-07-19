from django.contrib.auth import get_user_model
from django.core.management.base import BaseCommand

from signing.models import InvestorProfile

# Associated Contacts of Investing Entity "haris Personal LLC" (org: plaid)
INVESTORS = [
    {
        "username": "haris1996",
        "password": "Invest@123",
        "first_name": "haris 1996",
        "last_name": "javed",
        "email": "mharis.javed1996@gmail.com",
        "contact_id": "003Hn00002qb551IAA",  # primary, signs last
    },
    {
        "username": "haris637",
        "password": "Invest@123",
        "first_name": "haris 637",
        "last_name": "javed",
        "email": "mohammadharisjaved637@gmail.com",
        "contact_id": "003Hn00002qb7JNIAY",  # required signer, signs first
    },
]


class Command(BaseCommand):
    help = "Creates portal logins for the haris Personal LLC investors (POC)"

    def handle(self, *args, **options):
        User = get_user_model()
        for row in INVESTORS:
            user, created = User.objects.get_or_create(
                username=row["username"],
                defaults={
                    "first_name": row["first_name"],
                    "last_name": row["last_name"],
                    "email": row["email"],
                },
            )
            user.set_password(row["password"])
            user.save()
            InvestorProfile.objects.update_or_create(
                user=user,
                defaults={"contact_id": row["contact_id"], "sf_email": row["email"]},
            )
            verb = "Created" if created else "Updated"
            self.stdout.write(self.style.SUCCESS(
                f"{verb} {row['username']} / {row['password']} -> contact {row['contact_id']}"
            ))
