# OfferCheck — Database Normalization Analysis (1NF, 2NF, 3NF, BCNF)

This document provides a comprehensive, step-by-step normalization analysis of the **OfferCheck** PostgreSQL relational database. It is written using the actual tables, columns, constraints, and functional dependencies present in the schema, formatted specifically for academic presentation and defense before a DBMS professor.

---

## 1. Relational Definitions, Candidate Keys & Functional Dependencies

Before evaluating the normal forms, we formally define the keys and functional dependencies (FDs) governing our system.

### Core Definitions
- **Superkey:** A set of attributes that uniquely identifies a tuple within a relation.
- **Candidate Key (CK):** A minimal superkey (no proper subset is itself a superkey).
- **Primary Key (PK):** The candidate key selected by the database designer to identify tuples.
- **Prime Attribute:** An attribute that is a member of at least one candidate key.
- **Non-Prime Attribute:** An attribute that is not part of any candidate key.
- **Functional Dependency ($X \to Y$):** Attribute set $Y$ is functionally dependent on attribute set $X$ if each value of $X$ is associated with exactly one value of $Y$.

---

### Table-by-Table Candidate Keys and Functional Dependencies

| Table | Candidate Key(s) | Key Functional Dependencies ($X \to Y$) |
|---|---|---|
| **`users`** | `id`, `email` | `id` $\to$ `{name, email, password_hash, role, college, is_banned, created_at, updated_at}`<br>`email` $\to$ `{id, name, password_hash, role, college, is_banned, created_at, updated_at}` |
| **`refresh_tokens`** | `id`, `token_hash` | `id` $\to$ `{user_id, token_hash, family, expires_at, revoked_at, created_at}`<br>`token_hash` $\to$ `{id, user_id, family, expires_at, revoked_at, created_at}` |
| **`companies`** | `id`, `domain` *(when domain IS NOT NULL)* | `id` $\to$ `{name, domain, industry, registered_state, flagged, created_at}`<br>`domain` $\to$ `{id, name, industry, registered_state, flagged, created_at}` |
| **`recruiters`** | `id` | `id` $\to$ `{name, phone, email, flagged, created_at}` |
| **`recruiter_companies`** | `(recruiter_id, company_id)` | All attributes are prime. Trivial FDs only. |
| **`reports`** | `id` | `id` $\to$ `{submitted_by, reviewed_by, company_id, recruiter_id, company_name_raw, recruiter_name_raw, domain_raw, phone_raw, email_raw, upi_raw, offer_message, payment_request, additional_notes, status, submitted_at, reviewed_at, is_verified, is_inferred}` |
| **`identifiers`** | `id`, `(type, normalized_value)` | `id` $\to$ `{type, value, normalized_value, risk_score, flagged, confidence, notes, first_seen, last_seen}`<br>`(type, normalized_value)` $\to$ `{id, value, risk_score, flagged, confidence, notes, first_seen, last_seen}` |
| **`report_identifiers`** | `(report_id, identifier_id)` | `(report_id, identifier_id)` $\to$ `{confidence, match_type, match_description, added_by, added_at}` |
| **`risk_assessments`** | `id` *(and `report_id` conditionally when `is_current = TRUE`)* | `id` $\to$ `{report_id, score, category, summary, disclaimer, assessed_at, assessed_by, is_current, version}` |
| **`risk_factors`** | `id` | `id` $\to$ `{assessment_id, factor_key, description, weight, evidence_text, confidence, explanation}` |
| **`clusters`** | `id` | `id` $\to$ `{name, description, confidence, status, connection_basis, discovered_at, updated_at}` |
| **`cluster_reports`** | `(cluster_id, report_id)` | All attributes are prime. Trivial FDs only. |
| **`saved_reports`** | `(user_id, report_id)` | `(user_id, report_id)` $\to$ `{saved_at}` |
| **`offer_checks`** | `id` | `id` $\to$ `{user_id, company_name, phone_query, email_query, upi_query, domain_query, risk_score, risk_category, result, ip_hash, checked_at}` |
| **`audit_logs`** | `id` | `id` $\to$ `{actor_id, action, report_id, identifier_id, cluster_id, target_user_id, old_value, new_value, notes, created_at}` |

---

## 2. First Normal Form (1NF)

### 1NF Rule
A relation $R$ is in **First Normal Form (1NF)** if and only if:
1. Every attribute contains only **atomic (indivisible)** values.
2. There are **no repeating groups**, nested arrays, or multivalued attributes.
3. Each record is uniquely identifiable (a primary key is defined).

### How OfferCheck Achieves 1NF

In an unnormalized or document-oriented representation of fraud reports, multiple values are frequently grouped into single fields. Consider the following unnormalized representation:

```json
// UNNORMALIZED REPORT (Violates 1NF)
{
  "report_id": "rep_101",
  "company_name": "Acme Tech Services",
  "identifiers": ["+919876543210", "hr@acme-fake.com", "pay.acme@oksbi"], // Array: Repeating group
  "risk_factors": [
    {"factor": "payment_requested", "weight": 40},
    {"factor": "domain_mismatch", "weight": 25}
  ],                                                                        // Nested objects
  "clusters": ["cluster_scam_ring_01"]                                      // Array: Repeating group
}
```

To achieve 1NF in OfferCheck:
1. **Repeating Identifiers Extracted:** The repeating array `identifiers` was extracted into the `identifiers` entity and the `report_identifiers` junction table. Each `(report_id, identifier_id)` link is a discrete row with scalar values.
2. **Repeating Risk Factors Extracted:** The nested `risk_factors` objects were moved into a dedicated `risk_factors` table, where each factor occupies its own atomic row linked by `assessment_id`.
3. **Scam Clusters Extracted:** The relation between reports and clusters is maintained in a dedicated junction table, `cluster_reports`.

---

### In-Depth Analysis: The JSONB `offer_checks.result` Column & Classical 1NF

A critical topic for academic defense is the column `offer_checks.result`, which is typed as PostgreSQL `JSONB`.

```sql
CREATE TABLE offer_checks (
    id             TEXT PRIMARY KEY,
    user_id        TEXT,
    ...
    result         JSONB,       -- Stores point-in-time calculation snapshot
    checked_at     TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

#### The Classical Relational View (Codd's Model)
Under E.F. Codd's foundational 1970 relational model, every attribute in a relation must draw its value from an **atomic domain**. An atomic domain contains elements that cannot be decomposed by the database system into smaller semantic subcomponents.

A JSONB document, which internally contains nested key-value pairs (such as `risk_score`, `matched_identifiers`, and `explanation_text`), represents composite, non-atomic data. Therefore, **from a strict, classical relational perspective, storing composite JSON structures inside a single attribute represents a deliberate departure from pure 1NF.**

#### Engineering & Architectural Justification for the Trade-off

Why does OfferCheck intentionally use JSONB for this single column?

1. **Temporal Snapshot Fidelity (Point-in-Time Immutability):**
   OfferCheck is a dynamic, continuously updating system. When a student checks an offer on January 1st, the algorithm evaluates the trust graph as it exists on January 1st. If new fraud reports arrive on January 15th, re-running the check would produce an entirely different result.

   To maintain auditability of what the student was told at the exact moment of their query, the system must store an immutable snapshot of the evaluation result.

2. **Avoiding Unnecessary Schema Overhead for Ephemeral Data:**
   If we fully normalized `result`, we would need to construct 3–4 historical child tables (`offer_check_factors`, `offer_check_matches`, `offer_check_graph_nodes`) solely to store temporary lookup results. Because lookups occur at high frequency and are primarily read-once, decomposing them into multiple relational tables would cause excessive write amplification without analytical benefit.

3. **Modern RDBMS Semantics & Data Lifecycle:**
   In PostgreSQL, JSONB is stored in a decomposed binary format with toast compression, treated at the storage engine level as an atomic scalar binary datum. Furthermore, `offer_checks.result` is subject to a 90-day retention policy: a background job nullifies the `result` field after 90 days to minimize storage and preserve student privacy.

#### Summary for Examination
> *"Strictly speaking under classical relational theory, `offer_checks.result` contains non-atomic data and is a pragmatic departure from 1NF. In modern database engineering, it is an intentional architectural trade-off designed to capture an immutable, point-in-time calculation snapshot without incurring the high storage and join penalties of normalizing ephemeral lookup logs."*

---

## 3. Second Normal Form (2NF)

### 2NF Rule
A relation $R$ is in **Second Normal Form (2NF)** if and only if:
1. It is in **1NF**.
2. **No non-prime attribute is partially dependent on any candidate key.**
   *(In other words, every non-prime attribute must depend on the **whole** candidate key, not just a subset of it).*

> [!NOTE]
> By definition, partial functional dependency can **only** occur in tables with **composite candidate keys** (keys composed of two or more attributes). Relations with single-attribute primary keys automatically satisfy 2NF once they are in 1NF.

### 2NF Evaluation of Single-Attribute Primary Key Tables
The following tables have single-attribute candidate keys:
- `users` (PK: `id`)
- `refresh_tokens` (PK: `id`)
- `companies` (PK: `id`)
- `recruiters` (PK: `id`)
- `reports` (PK: `id`)
- `identifiers` (PK: `id`)
- `risk_assessments` (PK: `id`)
- `risk_factors` (PK: `id`)
- `clusters` (PK: `id`)
- `offer_checks` (PK: `id`)
- `audit_logs` (PK: `id`)

Because every candidate key in these tables consists of a single column, no proper subset of a key can exist. Therefore, **partial dependencies are mathematically impossible in these tables, and they are in 2NF.**

---

### 2NF Evaluation of Composite Key Junction Tables

#### 1. Table: `report_identifiers`
- **Candidate Key:** `(report_id, identifier_id)`
- **Attributes:** `report_id`, `identifier_id`, `confidence`, `match_type`, `match_description`, `added_by`, `added_at`
- **Dependency Analysis:**
  - `confidence`: Measures how confident the system/moderator is that *this specific identifier* belongs to *this specific report*. Depends on `(report_id, identifier_id)`.
  - `match_type`: Explains how the identifier was detected in this report (e.g., `upi_match`). Depends on `(report_id, identifier_id)`.
  - `match_description`: Human-readable explanation of why this identifier is linked to this report. Depends on `(report_id, identifier_id)`.
  - `added_by`: The moderator who created this specific link. Depends on `(report_id, identifier_id)`.
  - `added_at`: The timestamp when this link was established. Depends on `(report_id, identifier_id)`.

**Why 2NF would be violated if designed incorrectly:**
If an unnormalized design had placed `identifier_type` or `identifier_value` inside `report_identifiers`:
$$\text{identifier\_id} \to \text{identifier\_type}$$
Because `identifier_id` is only a proper subset of `(report_id, identifier_id)`, `identifier_type` would be partially dependent on the candidate key, violating 2NF.

In our schema, `identifier_type` and `value` reside exclusively in the `identifiers` table. Every non-prime attribute in `report_identifiers` depends on the **entire composite key**. **Thus, `report_identifiers` is in 2NF.**

#### 2. Table: `recruiter_companies`
- **Candidate Key:** `(recruiter_id, company_id)`
- **Attributes:** `recruiter_id`, `company_id`
- **Dependency Analysis:** Both attributes are prime. There are no non-prime attributes in this table. **Thus, 2NF is satisfied.**

#### 3. Table: `cluster_reports`
- **Candidate Key:** `(cluster_id, report_id)`
- **Attributes:** `cluster_id`, `report_id`
- **Dependency Analysis:** Both attributes are prime. There are no non-prime attributes. **Thus, 2NF is satisfied.**

#### 4. Table: `saved_reports`
- **Candidate Key:** `(user_id, report_id)`
- **Attributes:** `user_id`, `report_id`, `saved_at`
- **Dependency Analysis:**
  - `saved_at`: Records the timestamp when a specific user saved a specific report. It depends on both `user_id` and `report_id`. Neither `user_id` alone nor `report_id` alone determines when the bookmark was created. **Thus, 2NF is satisfied.**

---

## 4. Third Normal Form (3NF)

### 3NF Rule
A relation $R$ is in **Third Normal Form (3NF)** if and only if:
1. It is in **2NF**.
2. **No non-prime attribute is transitively dependent on any candidate key.**

Formally, for every non-trivial functional dependency $X \to Y$:
- $X$ is a **superkey**, OR
- $Y$ is a **prime attribute** (member of a candidate key).

In simple terms, **no non-key attribute should depend on another non-key attribute.**

---

### Demonstrating 3NF Compliance in OfferCheck

#### Case 1: Computed Aggregates in `companies` and `recruiters`
In naive database designs, developers often store summary statistics directly on entity tables:
```sql
-- BAD DESIGN: Violates 3NF
CREATE TABLE companies (
    id             TEXT PRIMARY KEY,
    name           VARCHAR(200),
    report_count   INT,          -- Transitive dependency!
    avg_risk_score NUMERIC       -- Transitive dependency!
);
```
**Why this violates 3NF:**
`report_count` and `avg_risk_score` do not depend directly on `company.id`. They depend on the set of tuples in the `reports` table associated with that `company_id`, which in turn depend on `risk_assessments.score`:
$$\text{company\_id} \to \text{reports} \to \text{avg\_risk\_score}$$
This transitive dependency causes **update anomalies**: every time a report is added, updated, or removed, the company row must be locked and updated.

**Our 3NF Solution:**
Neither `companies`, `recruiters`, nor `clusters` store precomputed counts or averages. Instead, metrics are computed dynamically on demand using SQL aggregate queries (`COUNT`, `AVG`):
```sql
SELECT c.id, c.name, COUNT(r.id) AS report_count, AVG(ra.score) AS avg_risk
FROM companies c
LEFT JOIN reports r ON r.company_id = c.id
LEFT JOIN risk_assessments ra ON ra.report_id = r.id AND ra.is_current = TRUE
GROUP BY c.id, c.name;
```

#### Case 2: Entity References vs. Entity Details in `reports`
If the `reports` table stored full company or recruiter metadata:
```sql
-- BAD DESIGN: Violates 3NF
CREATE TABLE reports (
    id               TEXT PRIMARY KEY,
    company_id       TEXT REFERENCES companies(id),
    company_name     VARCHAR(200),
    company_industry VARCHAR(100),   -- Transitive dependency!
    registered_state VARCHAR(80)     -- Transitive dependency!
);
```
Here, we would have:
$$\text{id} \to \text{company\_id} \quad \text{and} \quad \text{company\_id} \to \text{company\_industry}$$
Because `company_id` is not a candidate key for `reports`, `company_industry` is transitively dependent on `reports.id`, violating 3NF.

**Our 3NF Solution:**
The `reports` table stores only the foreign key `company_id`. Canonical details (`industry`, `registered_state`, `domain`) live exclusively in `companies` and are retrieved via `JOIN`.

#### Case 3: Why `reports.*_raw` Columns Do NOT Violate 3NF
The `reports` table includes several fields with the suffix `_raw`:
- `company_name_raw`
- `recruiter_name_raw`
- `domain_raw`
- `phone_raw`
- `email_raw`
- `upi_raw`

A professor might ask: *"Does storing `company_name_raw` in `reports` violate 3NF if `companies` already exists?"*

**The Answer:**
**No, it does not violate 3NF.**
- `company_name_raw` does **not** functionally determine `company_id`, nor does `company_id` functionally determine `company_name_raw`.
- The `*_raw` attributes represent **unverified historical testimony**: the exact text typed by the student at the moment they received the scam message (e.g. typing `"Wipro Technologies India Ltd"`).
- The `company_id` represents an optional link to a verified corporate entity identified after moderation. In fact, a fraudulent offer may claim a company name that does not exist in `companies` at all (`company_id IS NULL`).
- Because there is no functional dependency $\text{company\_id} \leftrightarrow \text{company\_name\_raw}$, there is no transitive dependency. The raw fields are non-transitive scalar facts about the submission event.

#### Case 4: Risk Factor Normalization
In `risk_assessments`, risk factors are not stored as JSON arrays or concatenated strings. Instead, the `risk_factors` table separates each factor:
- `assessment_id` (FK $\to$ `risk_assessments.id`)
- `factor_key`, `description`, `weight`, `confidence`, `explanation`

Every factor attribute depends directly on `risk_factors.id`. There are no transitive relationships between factor attributes.

**Conclusion:** All tables in the schema are in **3NF**.

---

## 5. Boyce-Codd Normal Form (BCNF)

### BCNF Rule
A relation $R$ is in **Boyce-Codd Normal Form (BCNF)** if and only if:
- For every non-trivial functional dependency $X \to Y$, **$X$ is a superkey.**

BCNF is a stricter version of 3NF. In 3NF, a dependency $X \to Y$ is allowed if $Y$ is a prime attribute even if $X$ is not a superkey. BCNF eliminates this exception: **every determinant must be a superkey.**

### Evaluating OfferCheck for BCNF

#### Tables with a Single Candidate Key
In any relational table that is in 3NF and possesses **only one candidate key**, the requirements for 3NF and BCNF are mathematically identical.
- In tables such as `reports`, `risk_factors`, `clusters`, `cluster_reports`, `saved_reports`, and `audit_logs`, the primary key is the sole candidate key.
- Since they are in 3NF, every non-trivial FD has the primary key (a superkey) on the left-hand side.
- **Therefore, all single-key tables in our schema strictly satisfy BCNF.**

---

#### Tables with Multiple Candidate Keys

BCNF violations typically arise in relations with multiple overlapping candidate keys. We must examine every table in OfferCheck that has more than one candidate key:

#### 1. Table: `users`
- **Candidate Key 1 ($CK_1$):** `{id}`
- **Candidate Key 2 ($CK_2$):** `{email}` (enforced by `UNIQUE` constraint and index)
- **Functional Dependencies:**
  1. $\text{id} \to \{\text{name, email, password\_hash, role, college, is\_banned, created\_at, updated\_at}\}$
  2. $\text{email} \to \{\text{id, name, password\_hash, role, college, is\_banned, created\_at, updated\_at}\}$
- **Determinant Check:**
  - In FD 1, the determinant is `id`, which is a candidate key $\implies$ Superkey.
  - In FD 2, the determinant is `email`, which is a candidate key $\implies$ Superkey.
- **Result:** Every determinant is a superkey. **`users` is in BCNF.**

#### 2. Table: `identifiers`
- **Candidate Key 1 ($CK_1$):** `{id}`
- **Candidate Key 2 ($CK_2$):** `{(type, normalized_value)}` (enforced by `UNIQUE(type, normalized_value)`)
- **Functional Dependencies:**
  1. $\text{id} \to \{\text{type, value, normalized\_value, risk\_score, flagged, confidence, notes, first\_seen, last\_seen}\}$
  2. $(\text{type, normalized\_value}) \to \{\text{id, value, risk\_score, flagged, confidence, notes, first\_seen, last\_seen}\}$
- **Determinant Check:**
  - `id` is a candidate key $\implies$ Superkey.
  - `(type, normalized_value)` is a candidate key $\implies$ Superkey.
  - Value original (`value`) does not determine `id` because different raw values (e.g. `9876543210` and `+91 98765 43210`) normalize to the same `normalized_value`.
- **Result:** Every determinant is a superkey. **`identifiers` is in BCNF.**

#### 3. Table: `refresh_tokens`
- **Candidate Key 1 ($CK_1$):** `{id}`
- **Candidate Key 2 ($CK_2$):** `{token_hash}` (enforced by `UNIQUE(token_hash)`)
- **Functional Dependencies:**
  1. $\text{id} \to \{\text{user\_id, token\_hash, family, expires\_at, revoked\_at, created\_at}\}$
  2. $\text{token\_hash} \to \{\text{id, user\_id, family, expires\_at, revoked\_at, created\_at}\}$
- **Determinant Check:**
  - Both `id` and `token_hash` are candidate keys $\implies$ Superkeys.
- **Result:** Every determinant is a superkey. **`refresh_tokens` is in BCNF.**

#### 4. Table: `companies`
- **Candidate Key 1 ($CK_1$):** `{id}`
- **Candidate Key 2 ($CK_2$):** `{domain}` *(for tuples where `domain IS NOT NULL`, enforced by unique constraint)*
- **Functional Dependencies:**
  1. $\text{id} \to \{\text{name, domain, industry, registered\_state, flagged, created\_at}\}$
  2. $\text{domain} \to \{\text{id, name, industry, registered\_state, flagged, created\_at}\}$
- **Determinant Check:**
  - Whenever `domain` is known, it uniquely identifies the company. Both determinants are superkeys.
- **Result:** Every determinant is a superkey. **`companies` is in BCNF.**

---

## 6. Normalization Summary Table

| Table Name | 1NF | 2NF | 3NF | BCNF | Key Rationale / Notes |
|---|:---:|:---:|:---:|:---:|---|
| `users` | ✅ | ✅ | ✅ | ✅ | Two candidate keys (`id`, `email`); all determinants are superkeys. |
| `refresh_tokens` | ✅ | ✅ | ✅ | ✅ | Two candidate keys (`id`, `token_hash`); session rotation chain via `family`. |
| `companies` | ✅ | ✅ | ✅ | ✅ | Derived metrics (`report_count`, `avg_risk`) omitted to prevent 3NF violations. |
| `recruiters` | ✅ | ✅ | ✅ | ✅ | Single PK; no partial or transitive dependencies. |
| `recruiter_companies` | ✅ | ✅ | ✅ | ✅ | Composite PK `(recruiter_id, company_id)`; all attributes are prime. |
| `reports` | ✅ | ✅ | ✅ | ✅ | Raw fields stored as historical evidence; normalized links via FKs. |
| `identifiers` | ✅ | ✅ | ✅ | ✅ | Two candidate keys (`id`, `(type, normalized_value)`); all determinants are superkeys. |
| `report_identifiers` | ✅ | ✅ | ✅ | ✅ | Composite PK; match metadata depends on entire `(report_id, identifier_id)` pair. |
| `risk_assessments` | ✅ | ✅ | ✅ | ✅ | Versioned history; partial unique index enforces at most one active assessment. |
| `risk_factors` | ✅ | ✅ | ✅ | ✅ | Normalized individual factors; avoids unnormalized JSON array inside assessments. |
| `clusters` | ✅ | ✅ | ✅ | ✅ | Cluster risk score computed on demand from member reports; 3NF preserved. |
| `cluster_reports` | ✅ | ✅ | ✅ | ✅ | Composite PK `(cluster_id, report_id)`; all attributes are prime. |
| `saved_reports` | ✅ | ✅ | ✅ | ✅ | Composite PK `(user_id, report_id)`; `saved_at` depends on full composite key. |
| `offer_checks` | ⚠️* | ✅ | ✅ | ✅ | *`result` JSONB is an intentional 1NF trade-off for immutable point-in-time calculation snapshots. |
| `audit_logs` | ✅ | ✅ | ✅ | ✅ | Immutable append-only log; all dependencies determined by primary key `id`. |

---

## 7. Review Questions & Defense Answers for Examination

**Q1: Why did you not store `risk_score` directly on the `reports` table?**
> *Answer:* A student's incident report is an immutable record of what occurred. However, our understanding of that report's risk evolves over time as more data is gathered (e.g., when a shared UPI handle is later discovered to belong to an organized scam cluster). Storing `risk_score` in `reports` would create an update anomaly and denormalization. By isolating risk evaluations in `risk_assessments`, we maintain an auditable, versioned history where each recalculation increments a version number, while a partial unique index guarantees that exactly one active assessment exists per report.

**Q2: Does having `phone_raw`, `email_raw`, and `upi_raw` on `reports` violate 3NF since you also have an `identifiers` table?**
> *Answer:* No. Functional dependency requires that a determinant uniquely and consistently maps to a dependent value. The `*_raw` attributes on `reports` represent unverified student input (e.g. typing an invalid phone format like `"98765 43210 (HR WhatsApp only)"`). The `identifiers` table stores canonical, verified, E.164-normalized entities (e.g. `"+919876543210"`). Because raw user text does not functionally determine a normalized identifier or vice-versa, there is no transitive dependency.

**Q3: Why is `offer_checks.result` stored as JSONB instead of normalized tables?**
> *Answer:* Normalization is designed to prevent update, insertion, and deletion anomalies on active relational entities. The result of an offer check is an ephemeral, point-in-time calculation snapshot representing what the trust graph looked like at the millisecond of the query. Normalizing it into 3–4 child tables would create massive database write overhead for data that is never updated and is automatically pruned after 90 days. We consciously treat JSONB as a pragmatic engineering trade-off departing from classical 1NF.
