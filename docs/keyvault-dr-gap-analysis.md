# Key Vault DR Gap Analysis & Remediation Guidance

**Addendum to:** PPL Multi-Region DR Implementation Guide (2026-09-10)
**Scope:** Key Vault secrets / certificates / keys replication for East US (active) → Central US (passive)
**Audience:** PPL architecture/platform team

## 1. Purpose

The base DR guide correctly rejects Microsoft-managed Key Vault paired-region failover as the DR mechanism for East US/Central US (a non-paired region combination) and recommends a *"regional Key Vault per region plus a deliberate sync process"* for secrets, certificates, and keys.

That recommendation is directionally correct but treats secrets, certificates, and keys as functionally equivalent to replicate. **They are not.** This addendum identifies where that assumption breaks down, what it means operationally for PPL, and the concrete remediation path for each object type.

## 2. Gap Summary

| Object type | Can be read back via Key Vault API? | "Sync to Central US" feasible? | Current repo coverage |
|---|---|---|---|
| **Secrets** | Yes — `GetSecret` returns the value | Yes — straightforward | Implemented (Event Grid → Service Bus → Function, async replication) |
| **Certificates** | Conditionally — only if the certificate policy sets `exportable: true` | Partially — requires extra handling (see 3.2) | Not implemented |
| **Keys** | **No** — private key material is never returned by any Key Vault API, by design (FIPS 140-2 boundary) | **No** — not achievable via replication at all | Not implemented; not implementable as "sync" |

**Bottom line for PPL:** the DR guide's phrase "sync secrets/certs/keys deliberately" needs to become three separate, explicitly scoped decisions — not one workstream — because keys require a fundamentally different strategy (pre-provisioning, not replication), and certificates require process changes beyond copying a blob.

## 3. Detailed Findings

### 3.1 Secrets — low risk, already solved

- `SecretClient.get_secret()` / `set_secret()` round-trip the plaintext value; this is what makes event-driven replication possible.
- The existing Terraform + Function App pattern in this repo (Event Grid `SecretNewVersionCreated` → Service Bus queue → Python Function using managed identity) satisfies the DR guide's requirement for secrets with no further architectural change needed.
- Residual risks to close out, not architectural gaps:
  - Replication is asynchronous/eventual — define an acceptable RPO (e.g., "under 5 minutes" based on Event Grid delivery + Function execution latency) and monitor for it.
  - No dead-letter/retry visibility is currently wired into alerting — add Service Bus dead-letter queue monitoring so a missed replication is detected before failover, not during it.

### 3.2 Certificates — medium risk, needs a dedicated workstream

A Key Vault certificate is three linked objects sharing one name: the certificate (policy + public cert), a backing **key**, and a backing **secret** (the exportable PFX/PEM, only present if the policy allows export).

Replication is only possible for the portion backed by an exportable secret:

- **Policy parity**: issuer, subject/SANs, key type/size, validity period, lifetime/auto-renewal actions must be recreated in the Central US vault — these are not part of the "value" and won't travel with a simple copy.
- **Issuer dependency**: if PPL certificates are issued through an integrated CA (DigiCert/GlobalSign) rather than imported, the Central US vault needs the same issuer provider/credentials configured, or renewal in Central US will fail even if the current cert was successfully copied.
- **Double-event hazard**: creating/renewing a certificate fires *both* `CertificateNewVersionCreated` and `SecretNewVersionCreated` (for its hidden backing secret). A naive extension of the current secret-replication Function would attempt to replicate the certificate's backing secret as if it were an ordinary application secret — this must be explicitly filtered out.
- **Non-exportable certificates**: if any certificate policy sets `exportable: false` (common for stricter compliance postures), there is no way to copy it — Central US must independently request/issue its own certificate for that name ahead of failover, not inherit East US's.

**Action for PPL**: inventory current certificate policies (`az keyvault certificate show-policy`) to identify which are exportable today. This determines whether certificate replication is even possible without a policy change, before any engineering work starts.

### 3.3 Keys — high risk, requires a different strategy (not "sync")

This is the most important correction to the base guide. Azure Key Vault's Keys API (standard or HSM-protected) **never exposes private key material** — there is no API call, SDK method, or portal action that returns it, by design. This is the control that makes Key Vault's HSM/FIPS boundary meaningful, and it is not a permission or SKU limitation that can be worked around.

Consequences:

- **Native backup/restore does not help here.** `az keyvault key backup` produces a blob restorable only within the **same Azure geography**. East US and Central US are both in the "United States" geography, so same-geography restore is technically possible for keys *in principle* — but this is a manual, operator-triggered action, not a continuous replication/sync process, and it still doesn't apply to cross-geography scenarios PPL may face later (e.g., if a future region pair spans US/EU).
- **If any Central US resource depends on a Key Vault key as a Customer-Managed Key (CMK)** — e.g., encryption-at-rest for PostgreSQL, Storage, or managed disks — that key **must be independently created and pre-assigned to the Central US resource at deployment time**, not synced during failover. There is no reactive remediation available once a regional outage has occurred; CMK provisioning in Central US has to already exist and be validated before the event.
- **If PPL requires the literal same cryptographic key material in both regions** (e.g., a shared signing/validation key consumed by services in both regions), the only supported path is **Bring Your Own Key (BYOK)**: generate the key material outside Key Vault (offline HSM or key ceremony), then import identical bytes into both vaults independently at provisioning time. This is a one-time import process per key, run outside the Event Grid/Function replication pipeline, with its own rotation runbook (rotate in both vaults together, on a schedule — never "replicate" a rotation after the fact).

**Action for PPL**: resolve the open CMK-dependency item from the base guide *before* finalizing the DR runbook. This single decision determines whether Central US resources can even be brought online during a declared DR event, and it cannot be fixed reactively.

## 4. Remediation Plan

| Phase | Scope | Owner action | Status |
|---|---|---|---|
| 1 | Secrets | Add Service Bus dead-letter monitoring/alerting to existing replication Function; define and validate RPO target | Operational hardening only |
| 2 | Certificates | Inventory certificate policies for `exportable` status; extend Terraform (Event Grid event types, RBAC) and Function (`azure-keyvault-certificates` SDK) to replicate exportable certs, including policy/issuer recreation and backing-secret event filtering | New engineering work |
| 3 | Keys — CMK dependencies | Inventory every Azure resource using Key Vault keys as CMK; pre-provision equivalent keys in Central US vault at deployment time; document joint key-rotation runbook | Blocking decision — resolve first |
| 4 | Keys — shared signing/crypto keys (if any) | Identify any key that must be byte-identical across regions; implement BYOK import process outside the replication pipeline | Engineering + process, only if applicable |
| 5 | Validation | Run a full DR test: fail application traffic to Central US and confirm secrets, certs, and CMK-dependent resources function without any manual Key Vault intervention | Gate before production sign-off |

## 5. Guidance for the PPL Conversation

Use these talking points to reset scope with PPL before committing to a delivery date:

1. **"Sync secrets/certs/keys" is not one task.** Secrets are solved today. Certificates need a defined workstream. Keys cannot be "synced" at all — CMK dependencies need pre-provisioning, and any shared cryptographic key needs a BYOK import process.
2. **The CMK inventory is a blocking prerequisite**, not a parallel work item — it determines whether Central US can decrypt/operate at all during failover, and it can't be resolved during an actual DR event.
3. **Certificate replication requires PPL to confirm exportability** of its current certificate policies; if certificates are non-exportable by design (common in regulated healthcare/financial environments), the remediation is independent issuance in Central US, not replication, and that changes the runbook and RTO expectations.
4. **This repo's current architecture is the correct foundation** for secrets and, with the Phase 2 extension, certificates — but it should not be marketed to PPL as covering "all Key Vault contents" until the key/CMK gap is explicitly closed or accepted as an out-of-scope manual process.
5. **Validate with a real DR test**, not a paper review — several of these gaps (non-exportable certs, un-provisioned CMK keys) only surface when Central US is actually exercised without East US available.

## 6. References

- Key Vault reliability: https://learn.microsoft.com/en-us/azure/reliability/reliability-key-vault
- Key Vault backup/restore (geography-scoped): https://learn.microsoft.com/en-us/azure/key-vault/general/backup
- Certificate exportability and policy: https://learn.microsoft.com/en-us/azure/key-vault/certificates/about-certificates
- Bring Your Own Key for Key Vault: https://learn.microsoft.com/en-us/azure/key-vault/keys/byok-specification
- Azure encryption at rest and key management: https://learn.microsoft.com/en-us/azure/security/fundamentals/encryption-atrest
