# OfferCheck — Complete Database Schema & Data Dictionary

This document provides a comprehensive technical reference for all **15 relational tables** in the **OfferCheck** PostgreSQL database. Every column, data type, primary key, foreign key, index, and constraint is fully documented, accompanied by simple explanations of key relationships suitable for college project defense.

---

## 1. Enumerated Types (ENUMs)

PostgreSQL ENUM types provide strict domain-level integrity, preventing invalid state strings from ever entering the database.

| Enum Name | Allowed Values | Usage / Description |
|---|---|---|
| **`UserRole`** | `student`, `admin` | Distinguishes regular student users from platform administrators. |
| **`ReportStatus`** | `pending`, `verified`, `rejected`, `investigating` | Lifecycle moderation status of a fraud report. |
| **`IdentifierType`** | `phone`, `email`, `upi`, `domain`, `bank_account` | Categories of fraud contact points. |
| **`ConfidenceLevel`** | `low`, `medium`, `high` | Degree of evidentiary certainty for matches, factors, and clusters. |
| **`RiskCategory`** | `low`, `medium`, `high`, `critical` | Standardized risk tiers derived from numerical risk scores (0–100). |
| **`ClusterStatus`** | `active`, `investigating`, `resolved`, `dismissed` | Investigation workflow status for grouped scam clusters. |
| **`AuditAction`** | `STATUS_CHANGED`, `IDENTIFIER_FLAGGED`, `IDENTIFIER_REVEALED`, `CLUSTER_CREATED`, `CLUSTER_UPDATED`, `REPORT_FLAGGED`, `REPORT_SUBMITTED`, `REPORT_DELETED`, `USER_BANNED` | Immutable action types recorded in administrative audit trails. |

---

## 2. Table Specifications (All 15 Tables)

---

### Table 1: `users`
**Purpose:** Stores registered students who submit/save reports and administrators who moderate fraud cases.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique user identifier (UUID string). |
| `name` | `VARCHAR(120)` | NO | | | Full name of the user. |
| `email` | `VARCHAR(254)` | NO | **UK** | | User's email address (RFC 5321 length). Unique constraint enforced. |
| `password_hash` | `VARCHAR(72)` | NO | | | Bcrypt hash output (up to 72 characters). Raw passwords are never stored. |
| `role` | `UserRole` | NO | | `'student'` | Access role (`student` or `admin`). |
| `college` | `VARCHAR(200)` | YES | | `NULL` | Affiliated college/university name (primarily for student users). |
| `is_banned` | `BOOLEAN` | NO | | `false` | Flag indicating whether the account has been suspended for abuse. |
| `created_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Account registration timestamp. |
| `updated_at` | `TIMESTAMP(3)` | NO | | | Timestamp of last profile update. |

- **Primary Key:** `users_pkey` on `(id)`
- **Unique Constraints:** `users_email_key` on `(email)`
- **Foreign Keys Outgoing:** None
- **Incoming Relations:**
  - `refresh_tokens.user_id` $\to$ `users.id` (`ON DELETE CASCADE`)
  - `reports.submitted_by` $\to$ `users.id` (`ON DELETE RESTRICT`)
  - `reports.reviewed_by` $\to$ `users.id` (`ON DELETE SET NULL`)
  - `saved_reports.user_id` $\to$ `users.id` (`ON DELETE CASCADE`)
  - `offer_checks.user_id` $\to$ `users.id` (`ON DELETE SET NULL`)
  - `audit_logs.actor_id` $\to$ `users.id` (`ON DELETE RESTRICT`)
  - `audit_logs.target_user_id` $\to$ `users.id` (`ON DELETE SET NULL`)
  - `report_identifiers.added_by` $\to$ `users.id` (`ON DELETE SET NULL`)

---

### Table 2: `refresh_tokens`
**Purpose:** Provides stateful JWT session management and rotation without requiring an external in-memory cache like Redis.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique refresh token record ID. |
| `user_id` | `TEXT` | NO | **FK** | | Foreign key referencing the parent user. |
| `token_hash` | `CHAR(64)` | NO | **UK** | | SHA-256 hex digest of the raw cryptographically random refresh token. |
| `family` | `UUID` | NO | | | Rotation family UUID. Used to detect token reuse attacks. |
| `expires_at` | `TIMESTAMP(3)` | NO | | | Expiration timestamp of the refresh token. |
| `revoked_at` | `TIMESTAMP(3)` | YES | | `NULL` | Timestamp when revoked (set during logout or reuse compromise). |
| `created_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Token creation timestamp. |

- **Primary Key:** `refresh_tokens_pkey` on `(id)`
- **Unique Constraints:** `refresh_tokens_token_hash_key` on `(token_hash)`
- **Foreign Keys:**
  - `user_id` $\to$ `users.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
- **Important Indexes:**
  - `idx_refresh_tokens_active` on `(token_hash) WHERE revoked_at IS NULL` (partial index for fast login hot-path lookups).
- **Plain-Language Explanation:** When a user logs in, they receive an access token (15 mins) and a refresh token. The raw refresh token is hashed before storing. If a compromised old token is reused, all tokens sharing that `family` UUID are revoked immediately.

---

### Table 3: `companies`
**Purpose:** Stores corporate entities that fraudulent offers claim to originate from.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique company identifier. |
| `name` | `VARCHAR(200)` | NO | | | Legal or recognized business name. |
| `domain` | `VARCHAR(253)` | YES | **UK** | `NULL` | Canonical official website domain. Unique constraint when present. |
| `industry` | `VARCHAR(100)` | YES | | `NULL` | Industry sector (e.g., Information Technology, EdTech). |
| `registered_state` | `VARCHAR(80)` | YES | | `NULL` | Registered state or jurisdiction. |
| `flagged` | `BOOLEAN` | NO | | `false` | Administrative flag indicating widespread impersonation. |
| `created_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Record creation timestamp. |

- **Primary Key:** `companies_pkey` on `(id)`
- **Unique Constraints:** `companies_domain_key` on `(domain)`
- **Foreign Keys Outgoing:** None
- **Incoming Relations:**
  - `recruiter_companies.company_id` $\to$ `companies.id` (`ON DELETE CASCADE`)
  - `reports.company_id` $\to$ `companies.id` (`ON DELETE SET NULL`)

---

### Table 4: `recruiters`
**Purpose:** Stores individuals claiming to be recruitment officers, talent acquisition leads, or HR managers.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique recruiter entity identifier. |
| `name` | `VARCHAR(120)` | NO | | | Name claimed by the recruiter. |
| `phone` | `VARCHAR(20)` | YES | | `NULL` | Claimed contact phone number. |
| `email` | `VARCHAR(254)` | YES | | `NULL` | Claimed contact email address. |
| `flagged` | `BOOLEAN` | NO | | `false` | Whether this recruiter profile has been verified as fraudulent. |
| `created_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Record creation timestamp. |

- **Primary Key:** `recruiters_pkey` on `(id)`
- **Foreign Keys Outgoing:** None
- **Incoming Relations:**
  - `recruiter_companies.recruiter_id` $\to$ `recruiters.id` (`ON DELETE CASCADE`)
  - `reports.recruiter_id` $\to$ `recruiters.id` (`ON DELETE SET NULL`)

---

### Table 5: `recruiter_companies`
**Purpose:** Many-to-many junction table linking recruiters to companies.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `recruiter_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing `recruiters(id)`. |
| `company_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing `companies(id)`. |

- **Composite Primary Key:** `recruiter_companies_pkey` on `(recruiter_id, company_id)`
- **Foreign Keys:**
  - `recruiter_id` $\to$ `recruiters.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
  - `company_id` $\to$ `companies.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
- **Plain-Language Explanation:** A recruiter may claim to represent different companies across different scams, or a company may be impersonated by multiple fraudulent recruiters. This junction enables an $M:N$ mapping.

---

### Table 6: `reports`
**Purpose:** The central entity storing fraud incidents submitted by students.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique incident report identifier. |
| `submitted_by` | `TEXT` | NO | **FK** | | Foreign key referencing the reporting user (`users.id`). |
| `reviewed_by` | `TEXT` | YES | **FK** | `NULL` | Foreign key referencing the moderator who reviewed the report. |
| `company_id` | `TEXT` | YES | **FK** | `NULL` | Link to resolved company entity (if matched). |
| `recruiter_id` | `TEXT` | YES | **FK** | `NULL` | Link to resolved recruiter entity (if matched). |
| `company_name_raw` | `VARCHAR(200)` | NO | | | Company name exactly as typed by the student. |
| `recruiter_name_raw` | `VARCHAR(120)` | YES | | `NULL` | Recruiter name as reported by the student. |
| `domain_raw` | `VARCHAR(253)` | YES | | `NULL` | Website/email domain extracted from the offer letter. |
| `phone_raw` | `VARCHAR(20)` | YES | | `NULL` | Contact phone number as originally reported. |
| `email_raw` | `VARCHAR(254)` | YES | | `NULL` | Contact email address as originally reported. |
| `upi_raw` | `VARCHAR(80)` | YES | | `NULL` | UPI ID requested for payment (e.g., `scam@okaxis`). |
| `offer_message` | `TEXT` | NO | | | Full text/excerpt of the suspicious offer letter or WhatsApp message. |
| `payment_request` | `VARCHAR(300)` | YES | | `NULL` | Details of money demanded (e.g., `"₹2,500 for training kit"`). |
| `additional_notes` | `TEXT` | YES | | `NULL` | Contextual narrative provided by the reporting student. |
| `status` | `ReportStatus` | NO | | `'pending'` | Current moderation workflow status. |
| `submitted_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Report submission timestamp. |
| `reviewed_at` | `TIMESTAMP(3)` | YES | | `NULL` | Timestamp when reviewed by an administrator. |
| `is_verified` | `BOOLEAN` | NO | | `false` | True if verified as confirmed fraud by an admin. |
| `is_inferred` | `BOOLEAN` | NO | | `false` | True if auto-flagged via shared trust graph identifiers. |

- **Primary Key:** `reports_pkey` on `(id)`
- **Foreign Keys:**
  - `submitted_by` $\to$ `users.id` (`ON DELETE RESTRICT`) — prevents destroying evidentiary chain of custody.
  - `reviewed_by` $\to$ `users.id` (`ON DELETE SET NULL`)
  - `company_id` $\to$ `companies.id` (`ON DELETE SET NULL`)
  - `recruiter_id` $\to$ `recruiters.id` (`ON DELETE SET NULL`)
- **Important Check Constraints:**
  - `chk_reviewed`: `CHECK (reviewed_at IS NULL OR reviewed_by IS NOT NULL)` ensures a review timestamp cannot exist without identifying the reviewing administrator.

---

### Table 7: `identifiers`
**Purpose:** Deduplicated repository of all contact handles (phone numbers, emails, UPI IDs, domains, bank accounts) observed across fraud reports.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique identifier entity ID. |
| `type` | `IdentifierType` | NO | | | Type of contact point (`phone`, `email`, `upi`, `domain`, `bank_account`). |
| `value` | `VARCHAR(300)` | NO | | | Original value as submitted for display. |
| `normalized_value` | `VARCHAR(300)` | NO | **UK** | | Canonical formatted value (E.164 phone, lowercase email/UPI/domain). |
| `risk_score` | `SMALLINT` | NO | | `0` | Computed risk score (0 to 100). |
| `flagged` | `BOOLEAN` | NO | | `false` | Whether this identifier is confirmed malicious. |
| `confidence` | `ConfidenceLevel` | NO | | `'low'` | Confidence in the identifier's risk classification. |
| `notes` | `TEXT` | YES | | `NULL` | Administrative moderation notes. |
| `first_seen` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Timestamp of first occurrence in any report. |
| `last_seen` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Timestamp of most recent occurrence. |

- **Primary Key:** `identifiers_pkey` on `(id)`
- **Unique Constraints:** `identifiers_type_normalized_value_key` on `(type, normalized_value)`
- **Foreign Keys Outgoing:** None
- **Incoming Relations:**
  - `report_identifiers.identifier_id` $\to$ `identifiers.id` (`ON DELETE RESTRICT`)
  - `audit_logs.identifier_id` $\to$ `identifiers.id` (`ON DELETE SET NULL`)
- **Plain-Language Explanation:** This is the core deduplication table. If ten students report different fake jobs that all ask for payment to the same UPI handle `pay.recruiter@oksbi`, that UPI handle is stored **once** here, creating the foundation for graph connectivity.

---

### Table 8: `report_identifiers`
**Purpose:** Many-to-many junction table connecting reports to identifiers with link-specific metadata.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `report_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing `reports(id)`. |
| `identifier_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing `identifiers(id)`. |
| `confidence` | `ConfidenceLevel` | NO | | `'medium'` | Confidence level that this identifier is linked to this specific incident. |
| `match_type` | `VARCHAR(50)` | YES | | `NULL` | Match mechanism (e.g., `'upi_match'`, `'phone_match'`, `'domain_match'`). |
| `match_description`| `TEXT` | YES | | `NULL` | Plain-language explanation displayed in the Trust Graph UI. |
| `added_by` | `TEXT` | YES | **FK** | `NULL` | User/moderator ID who established this link (`NULL` if automated). |
| `added_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Link creation timestamp. |

- **Composite Primary Key:** `report_identifiers_pkey` on `(report_id, identifier_id)`
- **Foreign Keys:**
  - `report_id` $\to$ `reports.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
  - `identifier_id` $\to$ `identifiers.id` (`ON DELETE RESTRICT`, `ON UPDATE CASCADE`)
  - `added_by` $\to$ `users.id` (`ON DELETE SET NULL`, `ON UPDATE CASCADE`)
- **Plain-Language Explanation:** Merging match metadata into this junction table eliminates the need for an external `evidence` table, saving one SQL `JOIN` on every trust graph lookup. If a report is deleted, the association is removed (`CASCADE`), but the `identifier` remains preserved (`RESTRICT`).

---

### Table 9: `risk_assessments`
**Purpose:** Stores versioned, deterministic fraud evaluations for incident reports.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique assessment record ID. |
| `report_id` | `TEXT` | NO | **FK** | | Foreign key referencing the assessed report (`reports.id`). |
| `score` | `SMALLINT` | NO | | | Overall calculated risk score (0 to 100). |
| `category` | `RiskCategory` | NO | | | Risk category (`low`, `medium`, `high`, `critical`). |
| `summary` | `TEXT` | YES | | `NULL` | High-level natural language summary of findings. |
| `disclaimer` | `TEXT` | YES | | `NULL` | Legal disclaimer accompanying the assessment. |
| `assessed_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Timestamp when assessment was computed. |
| `assessed_by` | `TEXT` | NO | | `'system'` | Assessing agent (`'system'` or admin user ID). |
| `is_current` | `BOOLEAN` | NO | | `true` | Indicates the currently active assessment for the report. |
| `version` | `SMALLINT` | NO | | `1` | Version counter (increments upon recalculation). |

- **Primary Key:** `risk_assessments_pkey` on `(id)`
- **Foreign Keys:**
  - `report_id` $\to$ `reports.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
- **Important Indexes:**
  - `idx_risk_assessments_current` on `(report_id) WHERE is_current = TRUE` (partial unique index guaranteeing at most one active assessment per report).
- **Plain-Language Explanation:** When a report is submitted, version 1 is created. If new scam connections are later discovered, an updated assessment is inserted as version 2 (`is_current = true`), while version 1 is marked `is_current = false`. This maintains an auditable evaluation history.

---

### Table 10: `risk_factors`
**Purpose:** Breaks down risk scores into discrete, explainable contributing signals.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique risk factor record ID. |
| `assessment_id` | `TEXT` | NO | **FK** | | Foreign key referencing `risk_assessments(id)`. |
| `factor_key` | `VARCHAR(80)` | NO | | | Algorithmic signal key (e.g., `'upfront_payment_requested'`). |
| `description` | `VARCHAR(300)` | NO | | | Short title/description of the risk factor. |
| `weight` | `SMALLINT` | NO | | | Points contributed to the overall risk score (0 to 100). |
| `evidence_text` | `TEXT` | YES | | `NULL` | Quotation or data snippet triggering the factor. |
| `confidence` | `ConfidenceLevel` | NO | | `'medium'` | Confidence level of the rule match. |
| `explanation` | `TEXT` | NO | | | Clear, student-facing explanation of why this factor indicates fraud. |

- **Primary Key:** `risk_factors_pkey` on `(id)`
- **Foreign Keys:**
  - `assessment_id` $\to$ `risk_assessments.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)

---

### Table 11: `clusters`
**Purpose:** Groups interconnected fraud reports sharing infrastructure into recognized scam syndicates.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique cluster identifier. |
| `name` | `VARCHAR(200)` | NO | | | Descriptive name (e.g., `"Fake IT Placement Cell Ring - Bengaluru"`). |
| `description` | `TEXT` | YES | | `NULL` | Detailed summary of the syndicate's modus operandi. |
| `confidence` | `ConfidenceLevel` | NO | | `'medium'` | Confidence score for the cluster linkage. |
| `status` | `ClusterStatus` | NO | | `'active'` | Lifecycle status (`active`, `investigating`, `resolved`, `dismissed`). |
| `connection_basis`| `TEXT` | YES | | `NULL` | Plain-language basis of grouping (e.g., `"Shared UPI and domain"`). |
| `discovered_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Cluster discovery timestamp. |
| `updated_at` | `TIMESTAMP(3)` | NO | | | Last activity timestamp. |

- **Primary Key:** `clusters_pkey` on `(id)`
- **Foreign Keys Outgoing:** None
- **Incoming Relations:**
  - `cluster_reports.cluster_id` $\to$ `clusters.id` (`ON DELETE CASCADE`)
  - `audit_logs.cluster_id` $\to$ `clusters.id` (`ON DELETE SET NULL`)

---

### Table 12: `cluster_reports`
**Purpose:** Many-to-many junction table associating incident reports with scam clusters.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `cluster_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing `clusters(id)`. |
| `report_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing `reports(id)`. |

- **Composite Primary Key:** `cluster_reports_pkey` on `(cluster_id, report_id)`
- **Foreign Keys:**
  - `cluster_id` $\to$ `clusters.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
  - `report_id` $\to$ `reports.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)

---

### Table 13: `saved_reports`
**Purpose:** Stores students' bookmarked reports for quick reference and tracking.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `user_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing the student (`users.id`). |
| `report_id` | `TEXT` | NO | **PK, FK** | | Foreign key referencing the bookmarked report (`reports.id`). |
| `saved_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Timestamp when bookmark was created. |

- **Composite Primary Key:** `saved_reports_pkey` on `(user_id, report_id)`
- **Foreign Keys:**
  - `user_id` $\to$ `users.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)
  - `report_id` $\to$ `reports.id` (`ON DELETE CASCADE`, `ON UPDATE CASCADE`)

---

### Table 14: `offer_checks`
**Purpose:** Records lookup queries performed by students checking suspicious offers.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique check record ID. |
| `user_id` | `TEXT` | YES | **FK** | `NULL` | Foreign key referencing `users.id` (`NULL` if checked anonymously). |
| `company_name` | `VARCHAR(200)` | YES | | `NULL` | Searched company name query. |
| `phone_query` | `VARCHAR(20)` | YES | | `NULL` | Searched phone number query. |
| `email_query` | `VARCHAR(254)` | YES | | `NULL` | Searched email address query. |
| `upi_query` | `VARCHAR(80)` | YES | | `NULL` | Searched UPI handle query. |
| `domain_query` | `VARCHAR(253)` | YES | | `NULL` | Searched domain query. |
| `risk_score` | `SMALLINT` | YES | | `NULL` | Evaluated risk score at check time (0 to 100). |
| `risk_category` | `RiskCategory` | YES | | `NULL` | Evaluated risk category at check time. |
| `result` | `JSONB` | YES | | `NULL` | Point-in-time calculation snapshot. Pruned after 90 days. |
| `ip_hash` | `CHAR(64)` | YES | | `NULL` | HMAC-SHA256 hash of client IP for privacy-preserving rate limiting. |
| `checked_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Query timestamp. |

- **Primary Key:** `offer_checks_pkey` on `(id)`
- **Foreign Keys:**
  - `user_id` $\to$ `users.id` (`ON DELETE SET NULL`, `ON UPDATE CASCADE`)
- **Important Indexes:**
  - `idx_offer_checks_ip_hash` on `(ip_hash, checked_at DESC) WHERE ip_hash IS NOT NULL` (enforces rate-limiting of 20 checks/hour per IP without storing plain text IP addresses).

---

### Table 15: `audit_logs`
**Purpose:** Immutable, append-only log recording every administrative action for legal compliance and accountability.

| Column | Data Type | Nullable | Key | Default | Description & Constraints |
|---|---|:---:|:---:|---|---|
| `id` | `TEXT` | NO | **PK** | `gen_random_uuid()` | Unique audit log entry ID. |
| `actor_id` | `TEXT` | NO | **FK** | | Foreign key referencing the administrator performing the action. |
| `action` | `AuditAction` | NO | | | Type of action performed. |
| `report_id` | `TEXT` | YES | **FK** | `NULL` | Target report ID (if applicable). |
| `identifier_id` | `TEXT` | YES | **FK** | `NULL` | Target identifier ID (if applicable). |
| `cluster_id` | `TEXT` | YES | **FK** | `NULL` | Target cluster ID (if applicable). |
| `target_user_id` | `TEXT` | YES | **FK** | `NULL` | Target user ID (e.g., when banning a user). |
| `old_value` | `VARCHAR(100)` | YES | | `NULL` | Previous state/status before change. |
| `new_value` | `VARCHAR(100)` | YES | | `NULL` | New state/status after change. |
| `notes` | `TEXT` | YES | | `NULL` | Justification notes recorded by the administrator. |
| `created_at` | `TIMESTAMP(3)` | NO | | `CURRENT_TIMESTAMP` | Timestamp when the action was recorded. |

- **Primary Key:** `audit_logs_pkey` on `(id)`
- **Foreign Keys:**
  - `actor_id` $\to$ `users.id` (`ON DELETE RESTRICT`) — an administrator account cannot be deleted if they have performed actions in the audit ledger.
  - `report_id` $\to$ `reports.id` (`ON DELETE SET NULL`)
  - `identifier_id` $\to$ `identifiers.id` (`ON DELETE SET NULL`)
  - `cluster_id` $\to$ `clusters.id` (`ON DELETE SET NULL`)
  - `target_user_id` $\to$ `users.id` (`ON DELETE SET NULL`)
- **Important Check Constraints:**
  - `audit_logs_has_target`: `CHECK (report_id IS NOT NULL OR identifier_id IS NOT NULL OR cluster_id IS NOT NULL OR target_user_id IS NOT NULL)` ensures an audit log entry cannot be created without at least one valid entity target.

---

## 3. Relationship Matrix & Cardinality Summary

| Parent Table | Child Table | Relationship Type | Junction / Foreign Key | Foreign Key Deletion Policy | Business Rule / Explanation |
|---|---|:---:|---|:---:|---|
| `users` | `reports` | $1 : N$ | `reports.submitted_by` | `RESTRICT` | Student submission history cannot be deleted while reports exist. |
| `users` | `reports` | $1 : N$ | `reports.reviewed_by` | `SET NULL` | If an admin account is removed, report retains `reviewed_by = NULL`. |
| `users` | `refresh_tokens` | $1 : N$ | `refresh_tokens.user_id` | `CASCADE` | Deleting a user revokes all their active sessions. |
| `users` | `saved_reports` | $M : N$ | `saved_reports` junction | `CASCADE` | Removing a user deletes their bookmarks. |
| `users` | `offer_checks` | $1 : N$ | `offer_checks.user_id` | `SET NULL` | Deleting an account preserves lookup history anonymously. |
| `users` | `audit_logs` | $1 : N$ | `audit_logs.actor_id` | `RESTRICT` | Admin accounts cannot be deleted if audit records exist. |
| `users` | `audit_logs` | $1 : N$ | `audit_logs.target_user_id` | `SET NULL` | Deleting a banned user retains the banning log entry. |
| `users` | `report_identifiers` | $1 : N$ | `report_identifiers.added_by` | `SET NULL` | Identifies the moderator who linked an identifier; preserved if admin is removed. |
| `companies` | `recruiter_companies` | $M : N$ | `recruiter_companies` | `CASCADE` | Recruiter-company linkages are automatically cleaned up. |
| `recruiters` | `recruiter_companies` | $M : N$ | `recruiter_companies` | `CASCADE` | Recruiter-company linkages are automatically cleaned up. |
| `companies` | `reports` | $1 : N$ | `reports.company_id` | `SET NULL` | Removing a company entity does not delete student incident reports. |
| `recruiters` | `reports` | $1 : N$ | `reports.recruiter_id` | `SET NULL` | Removing a recruiter entity does not delete student incident reports. |
| `reports` | `report_identifiers` | $M : N$ | `report_identifiers` | `CASCADE` | Deleting a report unlinks its identifier connections. |
| `identifiers` | `report_identifiers` | $M : N$ | `report_identifiers` | `RESTRICT` | An identifier cannot be dropped if reports still reference it. |
| `reports` | `risk_assessments` | $1 : N$ | `risk_assessments.report_id` | `CASCADE` | Deleting a report removes its calculated risk evaluations. |
| `risk_assessments` | `risk_factors` | $1 : N$ | `risk_factors.assessment_id` | `CASCADE` | Deleting a risk assessment removes its factor breakdowns. |
| `clusters` | `cluster_reports` | $M : N$ | `cluster_reports` | `CASCADE` | Removing a cluster disbands its report associations. |
| `reports` | `cluster_reports` | $M : N$ | `cluster_reports` | `CASCADE` | Removing a report detaches it from the scam cluster. |
| `reports` | `saved_reports` | $M : N$ | `saved_reports` | `CASCADE` | Removing a report removes it from users' bookmarks. |
| `reports` | `audit_logs` | $1 : N$ | `audit_logs.report_id` | `SET NULL` | Preserves audit action history if an associated report is deleted. |
| `identifiers` | `audit_logs` | $1 : N$ | `audit_logs.identifier_id` | `SET NULL` | Preserves identifier moderation history if an identifier is removed. |
| `clusters` | `audit_logs` | $1 : N$ | `audit_logs.cluster_id` | `SET NULL` | Preserves cluster lifecycle logs if a cluster is removed. |
