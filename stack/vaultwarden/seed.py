#!/usr/bin/env python3
"""Données de démonstration de la brique vaultwarden (toutes factices, rejouable).

Lancé par stack/vaultwarden/hook.sh dans le conteneur jetable lab-vaultwarden-outils, relié à
lab-net. Crée, s'ils manquent :
  - les comptes de démonstration (invités par la page d'administration, puis inscrits) ;
  - l'organisation « Labo GRC », ses collections et ses membres (rôles et statuts variés) ;
  - la connexion en deux étapes (TOTP) de la propriétaire, pas celle de l'administrateur ;
  - des éléments partagés dont le mot de passe a été changé à des dates variées.

Ni l'interface « bw » ni Vaultwarden ne savent inscrire un compte ou créer une organisation : ce
script fait donc ce que fait le coffre web, chiffrement côté client compris, d'après la
documentation officielle de Bitwarden :
  - livre blanc de sécurité (dérivation de la clé maître, clé symétrique, paire RSA, EncString) :
    https://bitwarden.com/help/bitwarden-security-white-paper/
  - chiffrement et KDF : https://bitwarden.com/help/what-encryption-is-used/ et
    https://bitwarden.com/help/kdf-algorithms/
  - routes du serveur : https://github.com/dani-garcia/vaultwarden/tree/main/src/api
Mots de passe : le mot de passe maître commun vient de .env (LAB_VAULTWARDEN_DEMO_PASSWORD) ; ceux
des éléments sont tirés au hasard à chaque création et ne sont écrits nulle part en clair.
"""

import base64
import datetime
import hashlib
import hmac
import http.cookiejar
import json
import os
import secrets
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, padding
from cryptography.hazmat.primitives.asymmetric import padding as rsa_padding
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
    load_der_private_key,
    load_der_public_key,
)

URL = os.environ.get("VW_URL", "https://vaultwarden:80").rstrip("/")
ADMIN_TOKEN = os.environ.get("VW_ADMIN_TOKEN", "")
PASSWORD = os.environ["VW_PASSWORD"]
SECRETS = os.environ.get("VW_SECRETS", "/secrets")
# Certificats TLS du serveur (l'interface « bw » exige HTTPS) : autorité locale et certificat de
# « vaultwarden » et « localhost », créés par `seed.py certs` dans secrets/vaultwarden.
TLS_DIR = os.environ.get("VW_TLS", "/tls")
KDF_ITERATIONS = 600000
ORG_NAME = "Labo GRC"
DOMAIN = "labo-grc.example"

# Membres : adresse, nom, rôle (OrganizationUserType de Bitwarden : 0 propriétaire, 1 administrateur,
# 2 utilisateur), collections, connexion en deux étapes, révoqué. Leur état côté GLPI (parti,
# inconnu) est donné par stack/vaultwarden/grc/essai.php.
OWNER = "claire.martin@" + DOMAIN
MEMBERS = [
    (OWNER, "Claire Martin", 0, ["Infrastructure", "Applications"], True, False),
    ("bruno.lefevre@" + DOMAIN, "Bruno Lefèvre", 1, ["Infrastructure", "Réseau"], False, False),
    ("david.moreau@" + DOMAIN, "David Moreau", 2, ["Réseau"], False, False),
    ("emma.petit@" + DOMAIN, "Emma Petit", 2, ["Infrastructure", "Applications"], False, False),
    ("prestataire@infogerance.example", "Prestataire Infogérance", 2, ["Réseau"], False, False),
    ("ancien.stagiaire@" + DOMAIN, "Ancien Stagiaire", 2, ["Applications"], False, True),
]
COLLECTIONS = ["Infrastructure", "Réseau", "Applications"]

# Éléments : nom, collection, identifiant, adresse, âge du dernier changement du mot de passe en
# jours (None : jamais changé depuis la création, Bitwarden laisse alors passwordRevisionDate vide).
ITEMS = [
    ("Routeur cœur de réseau", "Réseau", "admin", "https://rtr-coeur." + DOMAIN, 3 * 365),
    ("Pare-feu périmétrique", "Réseau", "admin", "https://fw01." + DOMAIN, 60),
    ("Base de données RH", "Infrastructure", "sa", "srv-db01." + DOMAIN + ":1433", 425),
    ("iLO srv-app01", "Infrastructure", "Administrator", "https://ilo-srv-app01." + DOMAIN, 30),
    ("Console d'hébergement", "Applications", "ops@" + DOMAIN, "https://console.hebergeur.example", None),
    ("Compte de service sauvegarde", "Applications", "svc-backup", "srv-backup01." + DOMAIN, 150),
]


def info(msg):
    print("lab [vaultwarden] : " + msg, file=sys.stderr, flush=True)


# ------------------------------------------------------------------------------------ HTTP


COOKIES = http.cookiejar.CookieJar()
CA_FILE = os.path.join(TLS_DIR, "ca.pem")
TLS = ssl.create_default_context(cafile=CA_FILE) if os.path.exists(CA_FILE) else None
OPENER = urllib.request.build_opener(
    urllib.request.HTTPCookieProcessor(COOKIES), urllib.request.HTTPSHandler(context=TLS)
)


def request(method, path, body=None, token=None, form=False, ok=(200,)):
    headers = {"Accept": "application/json", "Bitwarden-Client-Name": "web", "Bitwarden-Client-Version": "2026.10.0"}
    data = None
    if body is not None:
        if form:
            data = urllib.parse.urlencode(body).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
    try:
        with OPENER.open(req, timeout=60) as resp:
            raw = resp.read()
            code = resp.status
    except urllib.error.HTTPError as err:
        raw = err.read()
        code = err.code
    if code not in ok:
        raise SystemExit("lab [vaultwarden] : %s %s : HTTP %d %s" % (method, path, code, raw[:300].decode("utf-8", "replace")))
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode("utf-8", "replace")


# ------------------------------------------------------------------------------ chiffrement


def b64(data):
    return base64.b64encode(data).decode()


def unb64(text):
    return base64.b64decode(text)


def hkdf_expand(prk, info_label, length=32):
    out, block, counter = b"", b"", 1
    while len(out) < length:
        block = hmac.new(prk, block + info_label + bytes([counter]), hashlib.sha256).digest()
        out += block
        counter += 1
    return out[:length]


def master_key(email):
    return hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), email.strip().lower().encode(), KDF_ITERATIONS, 32)


def master_hash(mkey):
    return b64(hashlib.pbkdf2_hmac("sha256", mkey, PASSWORD.encode(), 1, 32))


def stretch(mkey):
    return hkdf_expand(mkey, b"enc") + hkdf_expand(mkey, b"mac")


def enc(data, key):
    """EncString de type 2 : AES-256-CBC, HMAC-SHA256 (clé de 64 octets : chiffrement | MAC)."""
    if isinstance(data, str):
        data = data.encode()
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    plain = padder.update(data) + padder.finalize()
    encryptor = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).encryptor()
    ct = encryptor.update(plain) + encryptor.finalize()
    mac = hmac.new(key[32:], iv + ct, hashlib.sha256).digest()
    return "2.%s|%s|%s" % (b64(iv), b64(ct), b64(mac))


def dec(encstring, key):
    kind, rest = encstring.split(".", 1)
    if kind != "2":
        raise SystemExit("lab [vaultwarden] : EncString de type %s inattendue" % kind)
    iv, ct, mac = (unb64(p) for p in rest.split("|"))
    if not hmac.compare_digest(mac, hmac.new(key[32:], iv + ct, hashlib.sha256).digest()):
        raise SystemExit("lab [vaultwarden] : MAC invalide (mot de passe maître changé ?)")
    decryptor = Cipher(algorithms.AES(key[:32]), modes.CBC(iv)).decryptor()
    plain = decryptor.update(ct) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(plain) + unpadder.finalize()


OAEP = rsa_padding.OAEP(mgf=rsa_padding.MGF1(hashes.SHA1()), algorithm=hashes.SHA1(), label=None)


def rsa_enc(data, public_der):
    """EncString de type 4 : RSA-2048-OAEP-SHA1."""
    return "4." + b64(load_der_public_key(public_der).encrypt(data, OAEP))


def rsa_dec(encstring, private_der):
    kind, rest = encstring.split(".", 1)
    if kind != "4":
        raise SystemExit("lab [vaultwarden] : clé RSA de type %s inattendue" % kind)
    return load_der_private_key(private_der, password=None).decrypt(unb64(rest), OAEP)


def keypair(sym_key):
    priv = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pub = priv.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)
    der = priv.private_bytes(Encoding.DER, PrivateFormat.PKCS8, NoEncryption())
    return {"publicKey": b64(pub), "encryptedPrivateKey": enc(der, sym_key)}


def totp(secret_b32, at=None):
    key = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8))
    counter = int((at or time.time()) // 30)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    return "%06d" % ((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1000000)


def totp_path(email):
    return os.path.join(SECRETS, "totp-" + email.split("@")[0])


# ------------------------------------------------------------------------------- comptes


def admin_users():
    request("POST", "/admin", {"token": ADMIN_TOKEN}, form=True, ok=(200, 303))
    return {u["email"].lower(): u for u in request("GET", "/admin/users")}


def ensure_account(email, name, known):
    """Invitation par l'administration (inscription libre fermée), puis inscription en deux temps
    (jeton de vérification rendu directement, sans courriel, puis fin de l'inscription)."""
    user = known.get(email)
    if user and user.get("_status") == 0:
        return False
    if not user:
        request("POST", "/admin/invite", {"email": email})
    verify = request("POST", "/identity/accounts/register/send-verification-email", {"email": email, "name": name})
    mkey = master_key(email)
    sym = os.urandom(64)
    body = {
        "email": email,
        "emailVerificationToken": verify,
        "masterPasswordHash": master_hash(mkey),
        "masterPasswordHint": None,
        "key": enc(sym, stretch(mkey)),
        "kdf": 0,
        "kdfIterations": KDF_ITERATIONS,
        "keys": keypair(sym),
    }
    request("POST", "/identity/accounts/register/finish", body)
    info("compte créé : " + email)
    return True


def login(email):
    mkey = master_key(email)
    form = {
        "grant_type": "password",
        "username": email,
        "password": master_hash(mkey),
        "scope": "api offline_access",
        "client_id": "web",
        "deviceType": "10",
        "deviceIdentifier": str(uuid.uuid5(uuid.NAMESPACE_DNS, "lab-seed." + email)),
        "deviceName": "lab-seed",
    }
    path = totp_path(email)
    if not os.path.exists(path):
        tok = request("POST", "/identity/connect/token", form, form=True)
    else:
        secret = open(path).read().strip()
        # Un code déjà servi (même pas de 30 s qu'une connexion précédente) est refusé : on attend
        # alors le pas suivant.
        for _attempt in range(3):
            form.update({"twoFactorToken": totp(secret), "twoFactorProvider": "0", "twoFactorRemember": "0"})
            tok = request("POST", "/identity/connect/token", form, form=True, ok=(200, 400))
            if "access_token" in tok:
                break
            time.sleep(31 - time.time() % 30)
        else:
            raise SystemExit("lab [vaultwarden] : connexion refusée pour %s : %s" % (email, tok.get("message", tok)))
    sym = dec(tok["Key"], stretch(mkey))
    priv = dec(tok["PrivateKey"], sym)
    claims = tok["access_token"].split(".")[1]
    user_id = json.loads(base64.urlsafe_b64decode(claims + "=" * (-len(claims) % 4)))["sub"]
    return {"token": tok["access_token"], "sym": sym, "priv": priv, "mhash": master_hash(mkey), "id": user_id}


def ensure_totp(email, session):
    path = totp_path(email)
    if os.path.exists(path):
        return
    # Clé tirée par le serveur, avec un jeton qui prouve la vérification du mot de passe maître.
    gen = request("POST", "/api/two-factor/get-authenticator", {"masterPasswordHash": session["mhash"]}, session["token"])
    secret = gen["authenticator"]["key"]
    # Code du pas suivant si l'on est en fin de période (le serveur accepte un pas d'écart).
    code = totp(secret, time.time() + (5 if time.time() % 30 > 25 else 0))
    request("POST", "/api/two-factor/authenticator",
            {"key": secret, "token": code, "userVerificationToken": gen["userVerificationToken"]}, session["token"])
    with open(path + ".tmp", "w") as fh:
        fh.write(secret + "\n")
    os.replace(path + ".tmp", path)
    info("connexion en deux étapes (TOTP) activée pour " + email)


# ------------------------------------------------------------------------- organisation


def org_of(session):
    sync = request("GET", "/api/sync?excludeDomains=true", token=session["token"])
    for org in sync["profile"]["organizations"]:
        if org["name"] == ORG_NAME:
            return org["id"], rsa_dec(org["key"], session["priv"])
    return None, None


def ensure_org(session):
    org_id, org_key = org_of(session)
    if org_id:
        return org_id, org_key
    org_key = os.urandom(64)
    pub = unb64(keypair_public(session))
    body = {
        "name": ORG_NAME,
        "billingEmail": OWNER,
        "collectionName": enc("Infrastructure", org_key),
        "key": rsa_enc(org_key, pub),
        "keys": keypair(org_key),
        "planType": 0,
    }
    request("POST", "/api/organizations", body, session["token"])
    info("organisation créée : " + ORG_NAME)
    return org_of(session)


def keypair_public(session):
    priv = load_der_private_key(session["priv"], password=None)
    return b64(priv.public_key().public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo))


def org_members(session, org_id):
    data = request("GET", "/api/organizations/%s/users?includeCollections=true" % org_id, token=session["token"])
    return {m["email"].lower(): m for m in data["data"]}


def ensure_members(session, org_id, org_key):
    members = org_members(session, org_id)
    for email, _name, role, _cols, _tfa, _revoked in MEMBERS:
        if email == OWNER or email in members:
            continue
        request("POST", "/api/organizations/%s/users/invite" % org_id, {
            "emails": [email], "type": role, "collections": [], "groups": [], "accessAll": False,
            "permissions": {}, "accessSecretsManager": False,
        }, session["token"])
        info("membre invité : " + email)
    members = org_members(session, org_id)
    for email, _name, _role, _cols, _tfa, revoked in MEMBERS:
        member = members[email]
        if member["status"] == 1:
            pub = request("GET", "/api/users/%s/public-key" % member["userId"], token=session["token"])["publicKey"]
            request("POST", "/api/organizations/%s/users/%s/confirm" % (org_id, member["id"]),
                    {"key": rsa_enc(org_key, unb64(pub))}, session["token"])
            info("membre confirmé : " + email)
        if revoked and member["status"] != -1:
            request("PUT", "/api/organizations/%s/users/%s/revoke" % (org_id, member["id"]), {}, session["token"])
            info("membre révoqué : " + email)
    return org_members(session, org_id)


def collections_of(session, org_id, org_key):
    data = request("GET", "/api/organizations/%s/collections" % org_id, token=session["token"])
    return {dec(c["name"], org_key).decode(): c["id"] for c in data["data"]}


def ensure_collections(session, org_id, org_key, members):
    existing = collections_of(session, org_id, org_key)
    for name in COLLECTIONS:
        users = [{"id": members[email]["id"], "readOnly": False, "hidePasswords": False, "manage": role <= 1}
                 for email, _n, role, cols, _t, _r in MEMBERS if name in cols]
        body = {"name": enc(name, org_key), "externalId": None, "groups": [], "users": users}
        if name in existing:
            request("PUT", "/api/organizations/%s/collections/%s" % (org_id, existing[name]), body, session["token"])
        else:
            request("POST", "/api/organizations/%s/collections" % org_id, body, session["token"])
            info("collection créée : " + name)
    return collections_of(session, org_id, org_key)


def ensure_items(session, org_id, org_key, collections):
    data = request("GET", "/api/ciphers/organization-details?organizationId=%s" % org_id, token=session["token"])
    names = {dec(c["name"], org_key).decode() for c in data["data"]}
    now = datetime.datetime.now(datetime.timezone.utc)
    for name, collection, username, uri, age in ITEMS:
        if name in names:
            continue
        revision = None if age is None else (now - datetime.timedelta(days=age)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        cipher = {
            "type": 1,
            "organizationId": org_id,
            # Exigé depuis le coffre web 2025.6.0 : utilisateur pour qui l'élément est chiffré.
            "encryptedFor": session["id"],
            "name": enc(name, org_key),
            "notes": None,
            "favorite": False,
            "reprompt": 0,
            "fields": [],
            "passwordHistory": [],
            "login": {
                "username": enc(username, org_key),
                # Mot de passe factice tiré au hasard, jamais écrit en clair.
                "password": enc(secrets.token_urlsafe(18), org_key),
                "uris": [{"uri": enc(uri, org_key), "match": None}],
                "totp": None,
                "passwordRevisionDate": revision,
            },
        }
        request("POST", "/api/ciphers/create", {"cipher": cipher, "collectionIds": [collections[collection]]}, session["token"])
        info("élément créé : " + name)


def wait_alive(timeout=600):
    """Nom « vaultwarden » joignable sur lab-net (après un redéploiement, il manque un moment)."""
    end = time.time() + timeout
    while True:
        try:
            with OPENER.open(URL + "/alive", timeout=10):
                return
        except (urllib.error.URLError, OSError) as err:
            if isinstance(getattr(err, "reason", err), ssl.SSLCertVerificationError):
                raise SystemExit("lab [vaultwarden] : certificat refusé : %s" % getattr(err, "reason", err))
            if time.time() > end:
                raise SystemExit("lab [vaultwarden] : %s/alive injoignable depuis lab-net" % URL)
            time.sleep(5)


def certs():
    """Autorité locale (10 ans) et certificat du serveur (5 ans), s'ils manquent : clés EC P-256."""
    if all(os.path.exists(os.path.join(TLS_DIR, f)) for f in ("ca.pem", "cert.pem", "key.pem")):
        return
    now = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=1)
    ca_key = ec.generate_private_key(ec.SECP256R1())
    ca_name = x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "Autorite locale glpi-test-lab (Vaultwarden)")])
    ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
          .public_key(ca_key.public_key()).serial_number(x509.random_serial_number())
          .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=3650))
          .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
          .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
          .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
          .sign(ca_key, hashes.SHA256()))
    key = ec.generate_private_key(ec.SECP256R1())
    cert = (x509.CertificateBuilder()
            .subject_name(x509.Name([x509.NameAttribute(x509.oid.NameOID.COMMON_NAME, "vaultwarden")]))
            .issuer_name(ca_name).public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=1825))
            .add_extension(x509.SubjectAlternativeName([x509.DNSName("vaultwarden"), x509.DNSName("localhost")]), critical=False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
            .add_extension(x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
            # Exigés par la vérification stricte de Python 3.13 et plus.
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()), critical=False)
            .sign(ca_key, hashes.SHA256()))
    os.makedirs(TLS_DIR, exist_ok=True)
    for name, data in (("ca.pem", ca.public_bytes(Encoding.PEM)), ("cert.pem", cert.public_bytes(Encoding.PEM)),
                       ("key.pem", key.private_bytes(Encoding.PEM, PrivateFormat.PKCS8, NoEncryption()))):
        with open(os.path.join(TLS_DIR, name + ".tmp"), "wb") as fh:
            fh.write(data)
        os.replace(os.path.join(TLS_DIR, name + ".tmp"), os.path.join(TLS_DIR, name))
    info("certificats TLS générés : secrets/vaultwarden (autorité locale ca.pem)")


def main():
    if sys.argv[1:] == ["certs"]:
        certs()
        return
    wait_alive()
    known = admin_users()
    for email, name, *_rest in MEMBERS:
        ensure_account(email, name, known)
    owner = login(OWNER)
    org_id, org_key = ensure_org(owner)
    members = ensure_members(owner, org_id, org_key)
    collections = ensure_collections(owner, org_id, org_key, members)
    ensure_items(owner, org_id, org_key, collections)
    for email, _name, _role, _cols, tfa, _revoked in MEMBERS:
        if tfa:
            ensure_totp(email, login(email))
    info("organisation « %s » : %d membres, %d collections, %d éléments" % (ORG_NAME, len(members), len(collections), len(ITEMS)))


if __name__ == "__main__":
    main()
