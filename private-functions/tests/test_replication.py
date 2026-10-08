import copy
import json
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock

from azure.core.exceptions import ResourceNotFoundError

from replication import BlobState, OPERATION_TAG, Replicator, fingerprint


class MemoryState:
    def __init__(self):
        self.records = {}

    def read(self, name):
        return self.records.get(name)

    def create(self, name, record):
        return self.records.setdefault(name, copy.deepcopy(record))


class Vault:
    def __init__(self, uri):
        self.vault_url = uri
        self.current = {}
        self.history = {}
        self.writes = 0

    def set_secret(self, name, value, **kwargs):
        self.writes += 1
        version = f"{self.writes:032x}"
        properties = SimpleNamespace(
            name=name,
            version=version,
            enabled=kwargs.get("enabled", True),
            content_type=kwargs.get("content_type"),
            expires_on=kwargs.get("expires_on"),
            not_before=kwargs.get("not_before"),
            tags=kwargs.get("tags", {}),
            managed=kwargs.get("managed", False),
        )
        secret = SimpleNamespace(
            name=name,
            id=f"{self.vault_url}/secrets/{name}/{version}",
            value=value,
            properties=properties,
        )
        self.current[name] = secret
        self.history[(name, version)] = secret
        return secret

    def get_secret(self, name, version=None):
        try:
            return self.history[(name, version)] if version else self.current[name]
        except KeyError:
            raise ResourceNotFoundError("Secret not found") from None

    def list_properties_of_secrets(self):
        return [secret.properties for secret in self.current.values()]


class ReplicationTests(unittest.TestCase):
    def setUp(self):
        self.primary = Vault("https://primary.vault.azure.net")
        self.secondary = Vault("https://secondary.vault.azure.net")
        self.primary_state = MemoryState()
        self.secondary_state = MemoryState()
        self.to_secondary = MagicMock()
        self.to_primary = MagicMock()
        self.primary_app = Replicator(self.primary, self.secondary, self.primary_state, self.to_secondary)
        self.secondary_app = Replicator(self.secondary, self.primary, self.secondary_state, self.to_primary)

    def sent(self, bus):
        return bus.get_queue_sender.return_value.__enter__.return_value.send_messages

    def payload(self, bus):
        return str(self.sent(bus).call_args.args[0])

    def message(self, source):
        return json.dumps({
            "schemaVersion": 1,
            "sourceVaultUri": self.primary.vault_url,
            "name": source.name,
            "version": source.properties.version,
        })

    def test_poll_sends_only_version_reference_and_checkpoints(self):
        source = self.primary.set_secret("example", "do-not-send-this-value")
        self.primary_app.poll()
        body = self.payload(self.to_secondary)
        self.assertNotIn(source.value, body)
        self.assertEqual(json.loads(body)["version"], source.properties.version)
        self.assertEqual(len(self.sent(self.to_secondary).call_args.args[0].message_id), 64)
        self.primary_app.poll()
        self.assertEqual(self.sent(self.to_secondary).call_count, 1)

    def test_replica_does_not_loop_back(self):
        self.primary.set_secret("example", "value")
        self.primary_app.poll()
        self.secondary_app.replicate(self.payload(self.to_secondary))
        self.secondary_app.poll()
        self.sent(self.to_primary).assert_not_called()
        self.assertEqual(self.secondary.get_secret("example").value, "value")

    def test_local_update_with_inherited_tags_replicates(self):
        source = self.primary.set_secret("example", "original")
        self.secondary_app.replicate(self.message(source))
        replica = self.secondary.get_secret("example")
        self.secondary.set_secret("example", "locally-updated", tags=replica.properties.tags)
        self.secondary_app.poll()
        self.primary_app.replicate(self.payload(self.to_primary))
        self.assertEqual(self.primary.get_secret("example").value, "locally-updated")
        self.primary_app.poll()
        self.sent(self.to_secondary).assert_not_called()

    def test_replication_preserves_attributes_and_user_tags(self):
        source = self.primary.set_secret(
            "example", "value", content_type="text/plain",
            expires_on=datetime.now(timezone.utc) + timedelta(days=30),
            tags={"owner": "team"},
        )
        self.secondary_app.replicate(self.message(source))
        replica = self.secondary.get_secret("example")
        self.assertEqual(fingerprint(replica), fingerprint(source))
        self.assertEqual(replica.properties.content_type, "text/plain")
        self.assertEqual(replica.properties.tags["owner"], "team")

    def test_duplicate_is_completed_without_source_read(self):
        source = self.primary.set_secret("example", "value")
        body = self.message(source)
        self.secondary_app.replicate(body)
        self.primary.get_secret = MagicMock(side_effect=AssertionError("No read expected"))
        self.secondary_app.replicate(body)
        self.assertEqual(self.secondary.writes, 1)

    def test_retry_after_write_before_checkpoint_does_not_duplicate(self):
        source = self.primary.set_secret("example", "value")
        create = self.secondary_state.create
        failed = False

        def fail_completion_once(name, record):
            nonlocal failed
            if name.startswith("completed/") and not failed:
                failed = True
                raise RuntimeError("Simulated checkpoint outage")
            return create(name, record)

        self.secondary_state.create = fail_completion_once
        with self.assertRaises(RuntimeError):
            self.secondary_app.replicate(self.message(source))
        self.secondary_app.poll()
        self.sent(self.to_primary).assert_not_called()
        self.secondary_app.replicate(self.message(source))
        self.assertEqual(self.secondary.writes, 1)

    def test_superseded_version_does_not_overwrite_destination(self):
        old = self.primary.set_secret("example", "old")
        self.primary.set_secret("example", "new")
        self.secondary_app.replicate(self.message(old))
        self.assertEqual(self.secondary.writes, 0)

    def test_send_failure_is_not_checkpointed(self):
        self.primary.set_secret("example", "value")
        self.sent(self.to_secondary).side_effect = RuntimeError("Send failed")
        with self.assertRaises(RuntimeError):
            self.primary_app.poll()
        self.assertEqual(self.primary_state.records, {})
        self.sent(self.to_secondary).side_effect = None
        self.primary_app.poll()
        self.assertEqual(self.sent(self.to_secondary).call_count, 2)

    def test_unreadable_and_managed_secrets_are_not_queued(self):
        now = datetime.now(timezone.utc)
        self.primary.set_secret("disabled", "value", enabled=False)
        self.primary.set_secret("expired", "value", expires_on=now - timedelta(days=1))
        self.primary.set_secret("future", "value", not_before=now + timedelta(days=1))
        self.primary.set_secret("certificate", "value", managed=True)
        self.primary_app.poll()
        self.sent(self.to_secondary).assert_not_called()

    def test_unknown_replica_marker_does_not_suppress_local_write(self):
        self.primary.set_secret("example", "value", tags={OPERATION_TAG: "f" * 64})
        self.primary_app.poll()
        self.sent(self.to_secondary).assert_called_once()

    def test_invalid_messages_raise_without_writes(self):
        source = self.primary.set_secret("example", "value")
        valid = json.loads(self.message(source))
        for change in (
            {"sourceVaultUri": "https://untrusted.vault.azure.net"},
            {"sourceVaultUri": "https://primary.vault.azure.net/other"},
            {"sourceVaultUri": "http://primary.vault.azure.net"},
            {"name": "../secret"},
            {"version": None},
            {"version": "latest"},
            {"schemaVersion": 2},
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.secondary_app.replicate(json.dumps({**valid, **change}))
        for payload in ("not-json", "[]", "null"):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.secondary_app.replicate(payload)
        self.assertEqual(self.secondary.writes, 0)

    def test_matching_vault_configuration_is_rejected(self):
        with self.assertRaises(ValueError):
            Replicator(self.primary, self.primary, self.primary_state, self.to_secondary)

    def test_blob_missing_is_absent_but_missing_container_raises(self):
        container = MagicMock()
        download = container.get_blob_client.return_value.download_blob
        error = ResourceNotFoundError("Not found")
        error.error_code = "BlobNotFound"
        download.side_effect = error
        self.assertIsNone(BlobState(container).read("example"))
        error.error_code = "ContainerNotFound"
        with self.assertRaises(ResourceNotFoundError):
            BlobState(container).read("example")

    def test_invalid_blob_state_is_not_silently_replaced(self):
        container = MagicMock()
        container.get_blob_client.return_value.download_blob.return_value.readall.return_value = b"[]"
        with self.assertRaises(ValueError):
            BlobState(container).read("example")

    def test_state_outage_before_write_prevents_replication(self):
        source = self.primary.set_secret("example", "value")
        self.secondary_state.create = MagicMock(side_effect=RuntimeError("State unavailable"))
        with self.assertRaises(RuntimeError):
            self.secondary_app.replicate(self.message(source))
        self.assertEqual(self.secondary.writes, 0)

    def test_source_attribute_changes_on_retry_require_investigation(self):
        source = self.primary.set_secret("example", "value")
        self.secondary.set_secret = MagicMock(side_effect=RuntimeError("Destination unavailable"))
        with self.assertRaises(RuntimeError):
            self.secondary_app.replicate(self.message(source))
        source.properties.tags = {"changed": "during-delivery"}
        with self.assertRaisesRegex(ValueError, "attributes changed"):
            self.secondary_app.replicate(self.message(source))


if __name__ == "__main__":
    unittest.main()
