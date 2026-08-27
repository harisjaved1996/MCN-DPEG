from django.contrib.auth import views as auth_views
from django.urls import path

from . import views

urlpatterns = [
    path("", views.dashboard, name="dashboard"),
    path(
        "login/",
        auth_views.LoginView.as_view(template_name="signing/login.html"),
        name="login",
    ),
    path("logout/", auth_views.LogoutView.as_view(), name="logout"),
    path("sign/<str:copy_id>/", views.sign, name="sign"),
    path("sign/<str:copy_id>/status", views.sign_status, name="sign_status"),
    path("document/<str:copy_id>/", views.document, name="document"),
    path("document/<str:copy_id>/file", views.document_file, name="document_file"),
    path("document/<str:copy_id>/data", views.document_data, name="document_data"),
    path(
        "investment-document/<str:content_version_id>/",
        views.investment_document,
        name="investment_document",
    ),
    path(
        "investment-document/<str:content_version_id>/file",
        views.investment_document_file,
        name="investment_document_file",
    ),
    path(
        "investment-document/<str:content_version_id>/data",
        views.investment_document_data,
        name="investment_document_data",
    ),
    path("callback", views.callback, name="callback"),
]
