#!/usr/bin/env python3

import base64
import json
import logging
import os
import subprocess
import sys
import http.client as http_client
from pathlib import Path
from typing import Dict, List, Optional

import msal
import webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# ── DEBUG HTTP & LIBRARY LOGGING ────────────────────────
http_client.HTTPConnection.debuglevel = 0
logging.basicConfig(level=logging.DEBUG, format='%(asctime)s %(name)s %(levelname)s %(message)s')
logging.getLogger("msal").setLevel(logging.INFO)
logging.getLogger("urllib3").setLevel(logging.INFO)
logging.getLogger("requests").setLevel(logging.INFO)
logger = logging.getLogger("get-token")

SCRIPT_DIR = Path(__file__).resolve().parent


def load_env_file(env_path: Path = SCRIPT_DIR / ".env") -> Dict[str, str]:
    if not env_path.is_file():
        return {}

    env_data: Dict[str, str] = {}
    try:
        with env_path.open(encoding="utf-8") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):]
                if "=" not in line:
                    continue
                key, value = line.split("=", 1)
                key = key.strip()
                value = value.strip()
                if value.startswith(("'", '"')) and value.endswith(("'", '"')) and len(value) >= 2:
                    value = value[1:-1]
                else:
                    if "#" in value:
                        value = value.split("#", 1)[0].strip()
                env_data[key] = value
                os.environ.setdefault(key, value)
    except OSError as exc:
        logger.warning("Failed to read .env file %s: %s", env_path, exc)
    return env_data


load_env_file()

# ── CONFIG ────────────────────────────────────────────────
TENANT_ID = os.getenv("APP_TENANT_ID")
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}" if TENANT_ID else None

# ADME audience
API_APP_ID = os.getenv("API_APP_ID")
RESOURCE_APP_ID_URI = os.getenv("RESOURCE_APP_ID_URI")
if not RESOURCE_APP_ID_URI:
    RESOURCE_APP_ID_URI = f"api://{API_APP_ID}" if API_APP_ID else "api://bd0c9d90-89ad-4bb3-97bc-d787b9f69cdc"
SCOPES = [f"{RESOURCE_APP_ID_URI}/.default"]

# Client app registration (the caller)
CLIENT_ID = (os.getenv("APP_CLIENT_ID") or os.getenv("APP_ID") or os.getenv("CLIENT_ID") or "").strip()
CLIENT_SECRET = os.getenv("APP_CLIENT_SECRET", "")  # if set => confidential client

# Flow switch (client_credentials | auth_code | interactive). Defaults to auth_code if CLIENT_SECRET present, else interactive.
FLOW = os.getenv("AUTH_FLOW")  # optional override


def run_az_command(args: List[str], description: str) -> str:
    cmd = ["az", *args]
    try:
        completed = subprocess.run(cmd, check=True, capture_output=True, text=True)
        return completed.stdout.strip()
    except FileNotFoundError:
        logger.warning("Azure CLI not found while %s; skipping.", description)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or exc.stdout or "").strip()
        if stderr:
            logger.warning("Azure CLI error (%s): %s", description, stderr)
        else:
            logger.warning("Azure CLI error (%s)", description)
    return ""


def resolve_client_app_id(initial_app_id: Optional[str] = None) -> str:
    candidate = (initial_app_id or "").strip()
    if candidate and candidate.lower() != "null":
        return candidate

    app_name = os.getenv("APP_NAME", "").strip()
    if not app_name:
        return ""

    logger.info("Resolving app registration ID by name: %s", app_name)
    output = run_az_command(
        [
            "ad",
            "app",
            "list",
            "--display-name",
            app_name,
            "--query",
            "[0].appId",
            "-o",
            "tsv",
        ],
        f"resolving client appId for {app_name}",
    )
    app_id = output.splitlines()[0].strip() if output else ""
    if app_id:
        logger.info("Resolved client '%s' to appId %s", app_name, app_id)
    return app_id


def lookup_service_principal(app_id: Optional[str], label: str) -> str:
    value = (app_id or "").strip()
    if not value or value.lower() == "null":
        logger.warning("Missing App ID for %s service principal lookup.", label)
        return ""

    output = run_az_command(
        [
            "ad",
            "sp",
            "show",
            "--id",
            value,
            "--query",
            "id",
            "-o",
            "tsv",
        ],
        f"looking up {label} service principal",
    )
    sp_id = output.splitlines()[0].strip() if output else ""
    if not sp_id:
        logger.warning("Service principal for %s (appId=%s) not found.", label, value)
    else:
        logger.info("%s service principal ID: %s", label, sp_id)
    return sp_id


def _b64url_decode(s: str) -> bytes:
    s += "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s)

def decode_jwt(token, label):
    try:
        hdr, pl, _ = token.split(".")
        print(f"=== {label} Header ===")
        print(json.dumps(json.loads(_b64url_decode(hdr)), indent=2))
        print(f"=== {label} Payload ===")
        print(json.dumps(json.loads(_b64url_decode(pl)), indent=2))
    except Exception as e:
        print(f"Failed to decode {label}: {e}")

def exit_with_error(msg, detail=None):
    print(f"❌ {msg}", file=sys.stderr)
    if detail:
        print(detail, file=sys.stderr)
    sys.exit(1)

def run_client_credentials(app: msal.ConfidentialClientApplication):
    print("Using client credentials flow (application permissions).")
    result = app.acquire_token_for_client(scopes=SCOPES)
    if "access_token" not in result:
        exit_with_error("Token acquisition (client credentials) failed:", result)
    return result["access_token"]

def run_auth_code(app: msal.ConfidentialClientApplication):
    REDIRECT_PORT = int(os.getenv("REDIRECT_PORT", "53100"))
    REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}"

    # Removed reserved scopes (openid, profile, offline_access) because we are using /.default
    auth_url = app.get_authorization_request_url(
        scopes=SCOPES,
        redirect_uri=REDIRECT_URI,
        response_type="code",
    )
    print("Open this URL in your browser to authenticate:")
    print(auth_url)
    try:
        webbrowser.open(auth_url)
    except Exception:
        pass

    class AuthHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            return
        def do_GET(self):
            parsed = urlparse(self.path)
            qs = parse_qs(parsed.query)
            code = qs.get("code", [None])[0]
            err = qs.get("error", [None])[0]
            err_desc = qs.get("error_description", [None])[0]
            print(f"Redirect received. code={bool(code)} error={err} desc={err_desc}")
            self.send_response(200)
            self.end_headers()
            if code:
                self.wfile.write(b"Authentication complete. You may close this window.")
            else:
                self.wfile.write(b"Authentication failed. Check terminal for details.")
            self.server.auth_code = code
            self.server.auth_error = {"error": err, "error_description": err_desc} if err else None

    httpd = HTTPServer(("localhost", REDIRECT_PORT), AuthHandler)
    httpd.handle_request()

    if getattr(httpd, "auth_error", None):
        exit_with_error("Authorization failed at /authorize.", httpd.auth_error)

    auth_code = getattr(httpd, "auth_code", None)
    if not auth_code:
        exit_with_error("No authorization code received from redirect.")

    # Same change here: only SCOPES (/.default)
    result = app.acquire_token_by_authorization_code(
        auth_code,
        scopes=SCOPES,
        redirect_uri=REDIRECT_URI,
    )
    if "access_token" not in result:
        exit_with_error("Token exchange with authorization code failed.", result)
    return result["access_token"]

def run_interactive_public():
    print("Using public client interactive flow (delegated permissions).")
    cache = msal.SerializableTokenCache()
    app = msal.PublicClientApplication(client_id=CLIENT_ID, authority=AUTHORITY, token_cache=cache)
    accounts = app.get_accounts()
    result = app.acquire_token_silent(SCOPES, account=accounts[0]) if accounts else None
    if not result or "access_token" not in result:
        result = app.acquire_token_interactive(scopes=SCOPES, prompt="select_account")
    if "access_token" not in result:
        exit_with_error("Interactive token acquisition failed.", result)
    return result["access_token"]

def main():
    global TENANT_ID, AUTHORITY, RESOURCE_APP_ID_URI, SCOPES, CLIENT_ID, CLIENT_SECRET, FLOW, API_APP_ID

    TENANT_ID = os.getenv("APP_TENANT_ID", "").strip()
    if not TENANT_ID:
        exit_with_error("APP_TENANT_ID is not set. Provide it via environment or .env file.")
    AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"

    FLOW = os.getenv("AUTH_FLOW")
    CLIENT_SECRET = os.getenv("APP_CLIENT_SECRET", "")

    api_app_id = os.getenv("API_APP_ID", "").strip()
    resource_uri = os.getenv("RESOURCE_APP_ID_URI", "").strip()
    if not resource_uri:
        resource_uri = f"api://{api_app_id}" if api_app_id else RESOURCE_APP_ID_URI
    RESOURCE_APP_ID_URI = resource_uri
    if not api_app_id and RESOURCE_APP_ID_URI.startswith("api://"):
        api_app_id = RESOURCE_APP_ID_URI.split("api://", 1)[1]
    API_APP_ID = api_app_id
    SCOPES = [f"{RESOURCE_APP_ID_URI}/.default"]

    initial_client_id = (
        os.getenv("APP_CLIENT_ID")
        or os.getenv("APP_ID")
        or os.getenv("CLIENT_ID")
        or CLIENT_ID
    )
    client_id = resolve_client_app_id(initial_client_id)
    if not client_id:
        exit_with_error("Unable to resolve client app registration ID. Set APP_CLIENT_ID or APP_NAME in .env.")
    CLIENT_ID = client_id
    os.environ["CLIENT_ID"] = client_id
    os.environ["APP_CLIENT_ID"] = client_id

    client_sp_id = lookup_service_principal(client_id, "Client")
    if client_sp_id:
        os.environ["CLIENT_SP_ID"] = client_sp_id
        print("Client service principal ID:", client_sp_id)
    else:
        print("Client service principal ID: <not found>")

    api_sp_id = lookup_service_principal(API_APP_ID, "API") if API_APP_ID else ""
    if not api_sp_id and API_APP_ID and RESOURCE_APP_ID_URI.startswith("api://"):
        inferred_api = RESOURCE_APP_ID_URI.split("api://", 1)[1]
        if inferred_api != API_APP_ID:
            api_sp_id = lookup_service_principal(inferred_api, "API")
            if api_sp_id:
                API_APP_ID = inferred_api
    if api_sp_id:
        os.environ["API_SP_ID"] = api_sp_id
        print("API service principal ID:", api_sp_id)
    elif API_APP_ID:
        print(f"API service principal ID for {API_APP_ID}: <not found>")
    else:
        print("API service principal lookup skipped (missing API_APP_ID).")

    is_confidential = bool(CLIENT_SECRET)
    print("Client type:", "confidential" if is_confidential else "public")
    print("Authority:", AUTHORITY)
    print("Client ID:", CLIENT_ID)
    print("Resource (scope):", SCOPES[0])

    same_app = (RESOURCE_APP_ID_URI.endswith(CLIENT_ID) or CLIENT_ID in RESOURCE_APP_ID_URI)
    if same_app and (FLOW in (None, "", "auth_code")):
        print("Warning: requesting a delegated token for the same app (client == resource). This often fails (AADSTS90009).")

    if FLOW == "client_credentials" and not is_confidential:
        exit_with_error("client_credentials flow requires APP_CLIENT_SECRET to be set.")

    if is_confidential:
        app = msal.ConfidentialClientApplication(client_id=CLIENT_ID, client_credential=CLIENT_SECRET, authority=AUTHORITY)
        if FLOW == "client_credentials" or same_app:
            token = run_client_credentials(app)
        elif FLOW in (None, "", "auth_code"):
            token = run_auth_code(app)
        else:
            exit_with_error(f"Unknown AUTH_FLOW '{FLOW}'. Use 'client_credentials' or 'auth_code'.")
    else:
        if FLOW and FLOW != "interactive":
            print("Ignoring AUTH_FLOW override for public client; using interactive.")
        token = run_interactive_public()

    print("✅ Access Token:", token)
    decode_jwt(token, "Access Token")

if __name__ == "__main__":
    main()