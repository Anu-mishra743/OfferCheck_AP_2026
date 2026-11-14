# OfferCheck — Entity-Relationship (ER) Diagram

This document presents the complete Entity-Relationship (ER) model for the **OfferCheck** platform. It visually and textually models all **15 relational database tables**, their internal attributes, primary keys, foreign keys, and cardinalities.

---

## 1. Complete Mermaid ER Diagram

```mermaid
erDiagram
    users {
        text id PK
        varchar name
        varchar email UK
        varchar password_hash
        UserRole role
        varchar college
        boolean is_banned
        timestamp created_at
        timestamp updated_at
    }

    refresh_tokens {
        text id PK
        text user_id FK
        char token_hash UK
        uuid family
        timestamp expires_at
        timestamp revoked_at
        timestamp created_at
    }

    companies {
        text id PK
        varchar name
        varchar domain UK
        varchar industry
        varchar registered_state
        boolean flagged
        timestamp created_at
    }

    recruiters {
        text id PK
        varchar name
        varchar phone
        varchar email
        boolean flagged
        timestamp created_at
    }

    recruiter_companies {
        text recruiter_id PK,FK
        text company_id PK,FK
    }

    reports {
        text id PK
        text submitted_by FK
        text reviewed_by FK
        text company_id FK
        text recruiter_id FK
        varchar company_name_raw
        varchar recruiter_name_raw
        varchar domain_raw
        varchar phone_raw
        varchar email_raw
        varchar upi_raw
        text offer_message
        varchar payment_request
        text additional_notes
        ReportStatus status
        timestamp submitted_at
        timestamp reviewed_at
        boolean is_verified
        boolean is_inferred
    }

    identifiers {
        text id PK
        IdentifierType type
        varchar value
        varchar normalized_value UK
        smallint risk_score
        boolean flagged
        ConfidenceLevel confidence
        text notes
        timestamp first_seen
        timestamp last_seen
    }

    report_identifiers {
        text report_id PK,FK
        text identifier_id PK,FK
        ConfidenceLevel confidence
        varchar match_type
        text match_description
        text added_by FK
        timestamp added_at
    }

    risk_assessments {
        text id PK
        text report_id FK
        smallint score
        RiskCategory category
        text summary
        text disclaimer
        timestamp assessed_at
        text assessed_by
        boolean is_current
        smallint version
    }

    risk_factors {
        text id PK
        text assessment_id FK
        varchar factor_key
        varchar description
        smallint weight
        text evidence_text
        ConfidenceLevel confidence
        text explanation
    }

    clusters {
        text id PK
        varchar name
        text description
        ConfidenceLevel confidence
        ClusterStatus status
        text connection_basis
        timestamp discovered_at
        timestamp updated_at
    }

    cluster_reports {
        text cluster_id PK,FK
        text report_id PK,FK
    }

    saved_reports {
        text user_id PK,FK
        text report_id PK,FK
        timestamp saved_at
    }

    offer_checks {
        text id PK
        text user_id FK
        varchar company_name
        varchar phone_query
        varchar email_query
        varchar upi_query
        varchar domain_query
        smallint risk_score
        RiskCategory risk_category
        jsonb result
        char ip_hash
        timestamp checked_at
    }

    audit_logs {
        text id PK
        text actor_id FK
        AuditAction action
        text report_id FK
        text identifier_id FK
        text cluster_id FK
        text target_user_id FK
        varchar old_value
        varchar new_value
        text notes
        timestamp created_at
    }

    %% Relationships
    users ||--o{ reports : "submits (submitted_by)"
    users |o--o{ reports : "moderates (reviewed_by)"
    users ||--o{ refresh_tokens : "owns"
    users ||--o{ saved_reports : "bookmarks"
    users |o--o{ offer_checks : "runs"
    users ||--o{ audit_logs : "acts_as (actor_id)"
    users |o--o{ audit_logs : "targeted_in (target_user_id)"
    users |o--o{ report_identifiers : "links (added_by)"

    companies ||--o{ recruiter_companies : "employs"
    recruiters ||--o{ recruiter_companies : "works_for"

    companies |o--o{ reports : "claimed_in"
    recruiters |o--o{ reports : "claimed_in"

    reports ||--o{ report_identifiers : "contains"
    identifiers ||--o{ report_identifiers : "linked_in"

    reports ||--o{ risk_assessments : "evaluated_by"
    risk_assessments ||--o{ risk_factors : "composed_of"

    clusters ||--o{ cluster_reports : "aggregates"
    reports ||--o{ cluster_reports : "grouped_in"

    reports ||--o{ saved_reports : "bookmarked_by"

    reports |o--o{ audit_logs : "audited_in"
    identifiers |o--o{ audit_logs : "audited_in"
    clusters |o--o{ audit_logs : "audited_in"
```

---

## 2. Structural Breakdown of Entities (All 15 Tables)

### Group A: Authentication & User Accounts (2 Tables)
1. **`users`**: Central account table for students and administrators.
   - Primary Key: `id`
   - Key Attributes: `email` (unique), `password_hash` (bcrypt), `role` (`student` or `admin`), `is_banned`.
2. **`refresh_tokens`**: Stateful session management table with cryptographic family chaining.
   - Primary Key: `id`
   - Foreign Key: `user_id` $\to$ `users(id)` (`ON DELETE CASCADE`)
   - Key Attributes: `token_hash` (unique SHA-256), `family` (rotation UUID), `expires_at`, `revoked_at`.

---

### Group B: Corporate Entities & Recruiters (3 Tables)
3. **`companies`**: Legitimate or fabricated business entities referenced in scam offers.
   - Primary Key: `id`
   - Key Attributes: `name`, `domain` (unique when present), `industry`, `flagged`.
4. **`recruiters`**: Individual recruiter personas communicating with students.
   - Primary Key: `id`
   - Key Attributes: `name`, `phone`, `email`, `flagged`.
5. **`recruiter_companies`**: Many-to-many junction modeling recruiters who claim affiliations with multiple organizations.
   - Composite Primary Key: `(recruiter_id, company_id)`
   - Foreign Keys: `recruiter_id` $\to$ `recruiters(id)` (`CASCADE`), `company_id` $\to$ `companies(id)` (`CASCADE`).

---

### Group C: Reporting & Trust Graph Deduplication (3 Tables)
6. **`reports`**: The primary incident entity recording fraudulent job offers reported by students.
   - Primary Key: `id`
   - Foreign Keys: `submitted_by` $\to$ `users(id)` (`RESTRICT`), `reviewed_by` $\to$ `users(id)` (`SET NULL`), `company_id` $\to$ `companies(id)` (`SET NULL`), `recruiter_id` $\to$ `recruiters(id)` (`SET NULL`).
   - Key Attributes: `company_name_raw`, `offer_message`, `payment_request`, `status`, `is_verified`, `is_inferred`.
7. **`identifiers`**: The master deduplication table for all contact handles across all fraud incidents.
   - Primary Key: `id`
   - Candidate Key: `(type, normalized_value)`
   - Key Attributes: `type` (phone/email/upi/domain/bank_account), `value` (raw display), `normalized_value` (canonical format), `risk_score`, `flagged`.
8. **`report_identifiers`**: Many-to-many junction linking reports to identifiers with link-specific evidence.
   - Composite Primary Key: `(report_id, identifier_id)`
   - Foreign Keys: `report_id` $\to$ `reports(id)` (`CASCADE`), `identifier_id` $\to$ `identifiers(id)` (`RESTRICT`), `added_by` $\to$ `users(id)` (`SET NULL`).
   - Key Attributes: `confidence`, `match_type`, `match_description`.

---

### Group D: Risk Intelligence & Scam Syndicates (4 Tables)
9. **`risk_assessments`**: Versioned risk evaluation calculations for individual reports.
   - Primary Key: `id`
   - Foreign Key: `report_id` $\to$ `reports(id)` (`CASCADE`).
   - Key Attributes: `score` (0–100), `category` (low/med/high/crit), `is_current` (partial unique index enforces $\le 1$ active assessment per report), `version`.
10. **`risk_factors`**: Granular contributing factors comprising an assessment.
    - Primary Key: `id`
    - Foreign Key: `assessment_id` $\to$ `risk_assessments(id)` (`CASCADE`).
    - Key Attributes: `factor_key`, `weight`, `explanation`.
11. **`clusters`**: Named scam syndicates grouping related reports sharing fraud infrastructure.
    - Primary Key: `id`
    - Key Attributes: `name`, `status`, `connection_basis`.
12. **`cluster_reports`**: Many-to-many junction connecting reports to scam clusters.
    - Composite Primary Key: `(cluster_id, report_id)`
    - Foreign Keys: `cluster_id` $\to$ `clusters(id)` (`CASCADE`), `report_id` $\to$ `reports(id)` (`CASCADE`).

---

### Group E: User Activity & Compliance Ledger (3 Tables)
13. **`saved_reports`**: Student bookmark junction table.
    - Composite Primary Key: `(user_id, report_id)`
    - Foreign Keys: `user_id` $\to$ `users(id)` (`CASCADE`), `report_id` $\to$ `reports(id)` (`CASCADE`).
14. **`offer_checks`**: Ephemeral lookup log for students verifying suspicious handles before applying.
    - Primary Key: `id`
    - Foreign Key: `user_id` $\to$ `users(id)` (`SET NULL` — allows anonymous checks).
    - Key Attributes: `phone_query`, `email_query`, `upi_query`, `domain_query`, `result` (JSONB point-in-time calculation snapshot), `ip_hash` (HMAC-SHA256 for rate limiting).
15. **`audit_logs`**: Immutable, append-only administrative ledger.
    - Primary Key: `id`
    - Foreign Keys: `actor_id` $\to$ `users(id)` (`RESTRICT`), `report_id` (`SET NULL`), `identifier_id` (`SET NULL`), `cluster_id` (`SET NULL`), `target_user_id` (`SET NULL`).
    - Constraints: CHECK constraint ensuring at least one entity target is present.

---

## 3. Cardinality & Relationship Legend

| Notation | Cardinality Meaning | Practical OfferCheck Example |
|---|---|---|
| `||--o{` | Exactly One to Zero or More | A `User` can submit zero, one, or many `Reports`. |
| `|o--o{` | Zero or One to Zero or More | A `Report` can optionally link to zero or one `Company`, while a `Company` may be linked in many `Reports`. |
| `||--||` | Exactly One to Exactly One | A `User` has exactly one profile record. |
| `M : N` | Many-to-Many | Implemented via junction tables (`report_identifiers`, `recruiter_companies`, `cluster_reports`, `saved_reports`). |
