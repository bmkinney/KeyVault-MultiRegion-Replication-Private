import json
import logging
import os
from typing import Any, Dict, Iterable, Optional, Tuple

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient


EVENT_TYPE_SECRET_NEW = "Microsoft.KeyVault.SecretNewVersionCreated"
EVENT_TYPE_NEAR_EXPIRY = "Microsoft.KeyVault.SecretNearExpiry"
EVENT_TYPE_EXPIRED = "Microsoft.KeyVault.SecretExpired"


def _get_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _build_clients() -> Tuple[SecretClient, SecretClient]:
    credential = DefaultAzureCredential()
    primary_uri = _get_env("PRIMARY_KEY_VAULT_URI")
    secondary_uri = _get_env("SECONDARY_KEY_VAULT_URI")

    return (
        SecretClient(vault_url=primary_uri, credential=credential),
        SecretClient(vault_url=secondary_uri, credential=credential),
    )


def _extract_secret_info(event: Dict[str, Any]) -> Tuple[Optional[str], Optional[str], Optional[str]]:
    subject = event.get("subject", "")
    data = event.get("data", {}) or {}

    secret_name = data.get("ObjectName") or data.get("objectName")
    version = data.get("Version") or data.get("version")
    vault_name = data.get("VaultName") or data.get("vaultName")

    if not (secret_name and version) and "/secrets/" in subject:
        # Subject format: /.../vaults/{vault}/secrets/{name}/versions/{version}
        parts = subject.strip("/").split("/")
        try:
            secrets_index = parts.index("secrets")
            secret_name = secret_name or parts[secrets_index + 1]
            version = version or parts[secrets_index + 3]
        except (ValueError, IndexError):
            pass

    if not vault_name and "/vaults/" in subject:
        parts = subject.strip("/").split("/")
        try:
            vault_index = parts.index("vaults")
            vault_name = parts[vault_index + 1]
        except (ValueError, IndexError):
            pass

    return vault_name, secret_name, version


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
            primary_client, secondary_client = _build_clients()
            logging.info("Successfully created Key Vault clients")
        except Exception as e:
            logging.error(f"Failed to build Key Vault clients: {e}", exc_info=True)
            raise

        primary_vault_name = os.getenv("PRIMARY_KEY_VAULT_NAME", "").strip().lower()
        secondary_vault_name = os.getenv("SECONDARY_KEY_VAULT_NAME", "").strip().lower()
        logging.debug(f"Vault names: primary={primary_vault_name}, secondary={secondary_vault_name}")

        for event in events:
            try:
                event_type = event.get("eventType") or event.get("event_type") or ""
                vault_name, secret_name, version = _extract_secret_info(event)
                logging.debug(f"Event: type={event_type}, vault={vault_name}, secret={secret_name}, version={version}")

                if not secret_name or not version:
                    logging.warning("Skipping event without secret name/version: %s", event)
                    continue

                if event_type in (EVENT_TYPE_NEAR_EXPIRY, EVENT_TYPE_EXPIRED):
                    logging.info("Received expiry event for %s: %s", secret_name, event_type)
                    continue

                if event_type != EVENT_TYPE_SECRET_NEW:
                    logging.info("Ignoring event type: %s", event_type)
                    continue

                vault_name_lower = (vault_name or "").lower()

                if primary_vault_name and vault_name_lower == primary_vault_name:
                    source_client = primary_client
                    dest_client = secondary_client
                    logging.info("Replicating from primary to secondary")
                elif secondary_vault_name and vault_name_lower == secondary_vault_name:
                    source_client = secondary_client
                    dest_client = primary_client
                    logging.info("Replicating from secondary to primary")
                else:
                    source_client = primary_client
                    dest_client = secondary_client
                    logging.warning("Vault name not recognized, defaulting to primary->secondary")

                logging.info("Fetching secret %s version %s", secret_name, version)
                secret = source_client.get_secret(secret_name, version)
                logging.info("Setting secret %s in destination vault", secret.name)
                dest_client.set_secret(secret.name, secret.value)
                logging.info("Successfully replicated secret %s version %s", secret.name, version)
            except Exception as e:
                logging.error("Error processing event for secret %s: %s", secret_name if 'secret_name' in locals() else 'unknown', str(e), exc_info=True)
                raise
    except Exception as e:
        logging.error("Fatal error in main function: %s", str(e), exc_info=True)
        raise
