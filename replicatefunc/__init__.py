import base64
import json
import logging
import os
from typing import Any, Dict, Iterable, Optional, Tuple

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.certificates import CertificateClient
from azure.keyvault.secrets import SecretClient


EVENT_TYPE_SECRET_NEW = "Microsoft.KeyVault.SecretNewVersionCreated"
EVENT_TYPE_NEAR_EXPIRY = "Microsoft.KeyVault.SecretNearExpiry"
EVENT_TYPE_EXPIRED = "Microsoft.KeyVault.SecretExpired"
EVENT_TYPE_CERT_NEW = "Microsoft.KeyVault.CertificateNewVersionCreated"
EVENT_TYPE_CERT_NEAR_EXPIRY = "Microsoft.KeyVault.CertificateNearExpiry"
EVENT_TYPE_CERT_EXPIRED = "Microsoft.KeyVault.CertificateExpired"

EXPIRY_EVENT_TYPES = (
    EVENT_TYPE_NEAR_EXPIRY,
    EVENT_TYPE_EXPIRED,
    EVENT_TYPE_CERT_NEAR_EXPIRY,
    EVENT_TYPE_CERT_EXPIRED,
)

# Marks versions written by this Function so the other region does not replicate them back.
REPLICATED_TAG = "mrkv-replicated-from"
PKCS12_CONTENT_TYPE = "application/x-pkcs12"

VaultClients = Tuple[SecretClient, CertificateClient]


def _get_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _build_clients() -> Tuple[VaultClients, VaultClients]:
    credential = DefaultAzureCredential()
    primary_uri = _get_env("PRIMARY_KEY_VAULT_URI")
    secondary_uri = _get_env("SECONDARY_KEY_VAULT_URI")

    return (
        (
            SecretClient(vault_url=primary_uri, credential=credential),
            CertificateClient(vault_url=primary_uri, credential=credential),
        ),
        (
            SecretClient(vault_url=secondary_uri, credential=credential),
            CertificateClient(vault_url=secondary_uri, credential=credential),
        ),
    )


def _extract_object_info(event: Dict[str, Any]) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    subject = event.get("subject", "")
    data = event.get("data", {}) or {}

    object_name = data.get("ObjectName") or data.get("objectName")
    version = data.get("Version") or data.get("version")
    vault_name = data.get("VaultName") or data.get("vaultName")

    if not (object_name and version):
        # Subject format: /.../vaults/{vault}/{secrets|certificates}/{name}/versions/{version}
        parts = subject.strip("/").split("/")
        for segment in ("secrets", "certificates"):
            if segment not in parts:
                continue
            try:
                segment_index = parts.index(segment)
                object_name = object_name or parts[segment_index + 1]
                version = version or parts[segment_index + 3]
            except IndexError:
                pass
            break

    if not vault_name and "/vaults/" in subject:
        parts = subject.strip("/").split("/")
        try:
            vault_index = parts.index("vaults")
            vault_name = parts[vault_index + 1]
        except (ValueError, IndexError):
            pass

    return vault_name, object_name, version


def _select_direction(
    vault_name: Optional[str],
    primary_clients: VaultClients,
    secondary_clients: VaultClients,
    primary_vault_name: str,
    secondary_vault_name: str,
) -> Tuple[VaultClients, VaultClients, str]:
    vault_name_lower = (vault_name or "").lower()

    if primary_vault_name and vault_name_lower == primary_vault_name:
        logging.info("Replicating from primary to secondary")
        return primary_clients, secondary_clients, primary_vault_name
    if secondary_vault_name and vault_name_lower == secondary_vault_name:
        logging.info("Replicating from secondary to primary")
        return secondary_clients, primary_clients, secondary_vault_name

    logging.warning("Vault name not recognized, defaulting to primary->secondary")
    return primary_clients, secondary_clients, primary_vault_name or "primary"


def _replicate_secret(
    source: SecretClient, dest: SecretClient, name: str, version: str, source_vault: str
) -> None:
    logging.info("Fetching secret %s version %s", name, version)
    secret = source.get_secret(name, version)

    if secret.properties.managed:
        logging.info("Skipping secret %s: backs a certificate, replicated via certificate event", name)
        return

    tags = dict(secret.properties.tags or {})
    if REPLICATED_TAG in tags:
        logging.info("Skipping secret %s version %s: replica from %s", name, version, tags[REPLICATED_TAG])
        return

    tags[REPLICATED_TAG] = source_vault
    dest.set_secret(name, secret.value, tags=tags)
    logging.info("Successfully replicated secret %s version %s", name, version)


def _replicate_certificate(
    source: VaultClients, dest: VaultClients, name: str, version: str, source_vault: str
) -> None:
    source_secrets, source_certs = source
    _, dest_certs = dest

    logging.info("Fetching certificate %s version %s", name, version)
    certificate = source_certs.get_certificate_version(name, version)

    tags = dict(certificate.properties.tags or {})
    if REPLICATED_TAG in tags:
        logging.info("Skipping certificate %s version %s: replica from %s", name, version, tags[REPLICATED_TAG])
        return

    policy = source_certs.get_certificate_policy(name)
    if policy.exportable is False:
        logging.warning("Skipping certificate %s: private key is not exportable", name)
        return

    # The certificate's private key material is only available through its backing secret.
    backing_secret = source_secrets.get_secret(name, version)
    if backing_secret.properties.content_type == PKCS12_CONTENT_TYPE:
        certificate_bytes = base64.b64decode(backing_secret.value)
    else:
        certificate_bytes = backing_secret.value.encode("utf-8")

    tags[REPLICATED_TAG] = source_vault
    dest_certs.import_certificate(
        name,
        certificate_bytes,
        enabled=certificate.properties.enabled,
        tags=tags,
        policy=policy,
    )
    logging.info("Successfully replicated certificate %s version %s", name, version)


def _parse_events(payload: str) -> Iterable[Dict[str, Any]]:
    try:
        data = json.loads(payload)
    except json.JSONDecodeError:
        return []

    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict):
        return [data]

    return []


def main(msg: func.ServiceBusMessage) -> None:
    logging.debug("=== Service Bus trigger fired ===")
    try:
        payload = msg.get_body().decode("utf-8")
        logging.info(f"Processing Service Bus message: {len(payload)} bytes")
        events = list(_parse_events(payload))
        logging.info(f"Parsed {len(events)} events from message")

        if not events:
            logging.warning("No events found in Service Bus message.")
            return

        try:
            primary_clients, secondary_clients = _build_clients()
            logging.info("Successfully created Key Vault clients")
        except Exception as e:
            logging.error(f"Failed to build Key Vault clients: {e}", exc_info=True)
            raise

        primary_vault_name = os.getenv("PRIMARY_KEY_VAULT_NAME", "").strip().lower()
        secondary_vault_name = os.getenv("SECONDARY_KEY_VAULT_NAME", "").strip().lower()
        logging.debug(f"Vault names: primary={primary_vault_name}, secondary={secondary_vault_name}")

        for event in events:
            object_name = None
            try:
                event_type = event.get("eventType") or event.get("event_type") or ""
                vault_name, object_name, version = _extract_object_info(event)
                logging.debug(f"Event: type={event_type}, vault={vault_name}, object={object_name}, version={version}")

                if not object_name or not version:
                    logging.warning("Skipping event without object name/version: %s", event)
                    continue

                if event_type in EXPIRY_EVENT_TYPES:
                    logging.info("Received expiry event for %s: %s", object_name, event_type)
                    continue

                if event_type not in (EVENT_TYPE_SECRET_NEW, EVENT_TYPE_CERT_NEW):
                    logging.info("Ignoring event type: %s", event_type)
                    continue

                source, dest, source_vault = _select_direction(
                    vault_name, primary_clients, secondary_clients, primary_vault_name, secondary_vault_name
                )

                if event_type == EVENT_TYPE_CERT_NEW:
                    _replicate_certificate(source, dest, object_name, version, source_vault)
                else:
                    _replicate_secret(source[0], dest[0], object_name, version, source_vault)
            except Exception as e:
                logging.error("Error processing event for %s: %s", object_name or "unknown", str(e), exc_info=True)
                raise
    except Exception as e:
        logging.error("Fatal error in main function: %s", str(e), exc_info=True)
        raise
