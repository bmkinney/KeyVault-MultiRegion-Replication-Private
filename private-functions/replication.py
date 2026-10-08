import hashlib
import json
import logging
import os
import re
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from typing import Any, Iterator, Optional
from urllib.parse import urlparse

from azure.core.exceptions import ResourceExistsError, ResourceNotFoundError
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import KeyVaultSecret, SecretClient
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.storage.blob import ContainerClient

OPERATION_TAG = "mrkv-replication-operation"
SOURCE_TAG = "mrkv-replicated-from"
INTERNAL_TAGS = {OPERATION_TAG, SOURCE_TAG}


def _required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _vault_uri(uri: str) -> str:
    parsed = urlparse(uri)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("Expected an HTTPS Key Vault root URI")
    return f"https://{parsed.hostname}"


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def operation_id(source_version_id: str, destination_uri: str) -> str:
    return _digest(f"{source_version_id.lower()}->{_vault_uri(destination_uri)}")


def _user_tags(secret: KeyVaultSecret) -> dict[str, str]:
    return {
        key: value
        for key, value in (secret.properties.tags or {}).items()
        if key not in INTERNAL_TAGS
    }


def fingerprint(secret: KeyVaultSecret) -> str:
    # Digests stay in private Blob state, never in Key Vault tags or queue messages.
    properties = secret.properties
    snapshot = {
        "value": secret.value,
        "enabled": properties.enabled is not False,
        "content_type": properties.content_type,
        "expires_on": properties.expires_on.isoformat() if properties.expires_on else None,
        "not_before": properties.not_before.isoformat() if properties.not_before else None,
        "tags": _user_tags(secret),
    }
    return _digest(json.dumps(snapshot, sort_keys=True, separators=(",", ":")))


class BlobState:
    def __init__(self, container: ContainerClient):
        self.container = container

    def read(self, name: str) -> Optional[dict[str, Any]]:
        try:
            payload = self.container.get_blob_client(name).download_blob().readall()
        except ResourceNotFoundError as error:
            if getattr(error, "error_code", None) == "BlobNotFound":
                return None
            raise
        record = json.loads(payload)
        if not isinstance(record, dict):
            raise ValueError("Invalid replication state record")
        return record

    def create(self, name: str, record: dict[str, Any]) -> dict[str, Any]:
        try:
            self.container.get_blob_client(name).upload_blob(
                json.dumps(record, sort_keys=True), overwrite=False
            )
            return record
        except ResourceExistsError:
            existing = self.read(name)
            if existing is None:
                raise RuntimeError("Replication state disappeared during concurrent creation")
            return existing


class Replicator:
    def __init__(
        self,
        local: SecretClient,
        remote: SecretClient,
        state: BlobState,
        bus: ServiceBusClient,
    ):
        self.local = local
        self.remote = remote
        self.state = state
        self.bus = bus
        self.local_uri = _vault_uri(local.vault_url)
        self.remote_uri = _vault_uri(remote.vault_url)
        if self.local_uri == self.remote_uri:
            raise ValueError("Local and remote vaults must be different")

    def poll(self) -> None:
        queued = 0
        with self.bus.get_queue_sender(queue_name="kv-events") as sender:
            for properties in self.local.list_properties_of_secrets():
                now = datetime.now(timezone.utc)
                if (
                    properties.enabled is False
                    or (properties.expires_on and properties.expires_on <= now)
                    or (properties.not_before and properties.not_before > now)
                ):
                    logging.warning("Cannot poll unreadable secret %s; disabled or outside validity period", properties.name)
                    continue
                try:
                    secret = self.local.get_secret(properties.name)
                except ResourceNotFoundError:
                    logging.warning("Secret %s disappeared during polling", properties.name)
                    continue
                if secret.properties.managed:
                    logging.info("Skipping certificate-managed secret %s", secret.name)
                    continue
                observed = f"observed/{_digest(secret.id.lower())}.json"
                if self.state.read(observed) is not None:
                    continue
                replica_operation = (secret.properties.tags or {}).get(OPERATION_TAG)
                if replica_operation and re.fullmatch(r"[0-9a-f]{64}", replica_operation):
                    record = self.state.read(f"operations/{replica_operation}.json")
                    if record and record.get("fingerprint") == fingerprint(secret):
                        self.state.create(observed, {"reason": "replica", "version": secret.id})
                        continue
                payload = {
                    "schemaVersion": 1,
                    "sourceVaultUri": self.local_uri,
                    "name": secret.name,
                    "version": secret.properties.version,
                }
                sender.send_messages(
                    ServiceBusMessage(
                        json.dumps(payload),
                        content_type="application/json",
                        message_id=operation_id(secret.id, self.remote_uri),
                    )
                )
                self.state.create(observed, {"reason": "queued", "version": secret.id})
                queued += 1
        logging.info("Private poll queued %d secret versions", queued)

    def replicate(self, payload: str) -> None:
        message = json.loads(payload)
        if not isinstance(message, dict) or message.get("schemaVersion") != 1:
            raise ValueError("Unsupported replication message schema")
        name = message.get("name")
        version = message.get("version")
        source_uri = message.get("sourceVaultUri")
        if not isinstance(source_uri, str) or _vault_uri(source_uri) != self.remote_uri:
            raise ValueError("Replication message source is not the configured remote vault")
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,127}", name):
            raise ValueError("Invalid secret name in replication message")
        if not isinstance(version, str) or not re.fullmatch(r"[0-9a-fA-F]{32}", version):
            raise ValueError("Invalid secret version in replication message")
        source_id = f"{self.remote_uri}/secrets/{name}/{version}"
        operation = operation_id(source_id, self.local_uri)
        completed = f"completed/{operation}.json"
        if self.state.read(completed) is not None:
            logging.info("Already processed secret %s version %s", name, version)
            return
        latest = self.remote.get_secret(name)
        if latest.properties.version.lower() != version.lower():
            self.state.create(completed, {"reason": "superseded", "sourceVersion": source_id})
            logging.info("Skipping superseded secret %s version %s", name, version)
            return
        secret = self.remote.get_secret(name, version)
        if secret.properties.managed:
            raise ValueError("Certificate-managed secrets are not supported")
        expected = fingerprint(secret)
        record = self.state.create(
            f"operations/{operation}.json",
            {"sourceVersion": source_id, "fingerprint": expected},
        )
        if record.get("sourceVersion") != source_id or record.get("fingerprint") != expected:
            raise ValueError("Source secret attributes changed during replication; investigate the queued version")
        try:
            existing = self.local.get_secret(name)
        except ResourceNotFoundError:
            existing = None
        if (
            existing is not None
            and (existing.properties.tags or {}).get(OPERATION_TAG) == operation
            and fingerprint(existing) == expected
        ):
            replica = existing
        else:
            tags = _user_tags(secret)
            tags[OPERATION_TAG] = operation
            tags[SOURCE_TAG] = self.remote_uri
            replica = self.local.set_secret(
                name,
                secret.value,
                enabled=secret.properties.enabled is not False,
                content_type=secret.properties.content_type,
                expires_on=secret.properties.expires_on,
                not_before=secret.properties.not_before,
                tags=tags,
            )
        self.state.create(completed, {"sourceVersion": source_id, "replicaVersion": replica.id})
        logging.info("Replicated secret %s version %s", name, version)


@contextmanager
def build_replicator() -> Iterator[Replicator]:
    # Enter clients only in function execution, not during worker indexing.
    with ExitStack() as stack:
        credential = stack.enter_context(DefaultAzureCredential())
        local = stack.enter_context(SecretClient(_vault_uri(_required("LOCAL_KEY_VAULT_URI")), credential))
        remote = stack.enter_context(SecretClient(_vault_uri(_required("REMOTE_KEY_VAULT_URI")), credential))
        container = stack.enter_context(
            ContainerClient(
                account_url=_required("REPLICATION_STATE_STORAGE_URI"),
                container_name="replication-state",
                credential=credential,
            )
        )
        bus = stack.enter_context(
            ServiceBusClient(_required("DESTINATION_SERVICE_BUS_NAMESPACE"), credential)
        )
        yield Replicator(local, remote, BlobState(container), bus)
