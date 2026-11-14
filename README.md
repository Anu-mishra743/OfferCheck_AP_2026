# OfferCheck — College Application Project (AP 2026)

## 1. Project Overview & Purpose

**OfferCheck** is a specialized recruitment fraud detection and verification platform built to protect college students and early-career jobseekers from predatory employment scams.

In recent years, fraudulent job and internship offers targeting university students have escalated dramatically across India. Scammers impersonate legitimate corporations, conduct fabricated online recruitment processes, issue fraudulent offer letters, and deceive candidates into paying "training fees", "security deposits", "laptop charges", or "background verification fees" via UPI or bank transfers.

OfferCheck solves this problem by providing:
1. **Instant Verification Engine (Offer Check):** Students can quickly check suspicious phone numbers, email addresses, UPI IDs, company names, or offer letter domains against a centralized, community-verified fraud repository before paying any money or sharing sensitive personal data.
2. **Community Reporting & Trust Graph:** When students encounter suspicious offers, they submit incident reports. OfferCheck extracts and deduplicates contact points into shared **identifiers** (phone numbers, UPI IDs, emails, domains, bank accounts). When multiple reports across different fake company names share the exact same UPI handle or phone number, OfferCheck's Trust Graph connects the dots.
3. **Scam Clustering:** Related reports that share fraudulent infrastructure are aggregated into **scam clusters**, exposing organized fraud rings rather than viewing incidents in isolation.
4. **Versioned Risk Scoring:** A deterministic risk engine evaluates each report against weighted risk factors (e.g., requested upfront payment, unverified free email domain, shared fraud UPI) and generates explainable risk assessments.
5. **Admin Moderation & Auditability:** Student submissions undergo verification by administrators, backed by an administrative audit log preserving moderation records across system changes.

---

## 2. Database Design Summary

The OfferCheck relational database is architected on **PostgreSQL** with an emphasis on strict data integrity, third normal form (3NF) relational hygiene, and fast query performance for fraud graph traversals.

The database consists of **15 relational tables** organized into five core functional domains:

### Core Functional Domains

1. **User & Session Management**
   - `users`: Stores registered students and system administrators, distinguishing roles, college affiliations, and account status.
   - `refresh_tokens`: Implements secure server-side JWT session management using SHA-256 token hashing, token family rotation, and reuse-detection to protect user sessions.

2. **Entity Modeling**
   - `companies`: Stores entities that fraudsters claim to represent, tracking corporate names, registered states, and official web domains.
   - `recruiters`: Stores individual recruiter personas and their contact handles.
   - `recruiter_companies`: A many-to-many junction modeling recruiters who claim affiliations with multiple organizations.

3. **Fraud Reports & Identifier Graph (Trust Graph)**
   - `reports`: The central entity storing student-submitted incident reports, including the raw text of the offer message, requested payment amounts, and review states.
   - `identifiers`: The core deduplication table storing unique contact points (phone, email, UPI, domain, bank account) with both original and canonical normalized values (e.g., E.164 phone format).
   - `report_identifiers`: A rich many-to-many junction linking reports to identifiers with link-specific confidence levels and plain-language match explanations.

4. **Risk Intelligence & Scam Clusters**
   - `risk_assessments`: Stores versioned risk evaluation scores and categories (`low`, `medium`, `high`, `critical`) for reports. Enforces at most one active assessment per report using a PostgreSQL partial unique index (`WHERE is_current = TRUE`).
   - `risk_factors`: Normalized breakdown of contributing risk signals, factor weights, and plain-language explanations.
   - `clusters`: Represents syndicates or connected fraud campaigns linking multiple reports.
   - `cluster_reports`: A many-to-many junction grouping reports into scam clusters.

5. **User Activity & Compliance**
   - `saved_reports`: Student bookmarks for tracking flagged fraud reports.
   - `offer_checks`: Records every lookup query run by students, storing HMAC-SHA256 hashed IP addresses for rate limiting and point-in-time JSONB result snapshots.
   - `audit_logs`: Records administrative moderation actions (STATUS_CHANGED, USER_BANNED, etc.) and preserves audit entries when associated records are removed through the configured SET NULL relationships.

---

## 3. AP Deliverables & Documentation Index

All DBMS deliverables for College Project Phase 1 (CP1) are organized inside the `dbms/` directory:

- [**dbms/01_normalization.md**](dbms/01_normalization.md): Formal normalization walkthrough covering 1NF, 2NF, 3NF, BCNF justification, candidate keys, functional dependencies, and an in-depth discussion on the `offer_checks.result` JSONB column.
- [**dbms/02_schema.md**](dbms/02_schema.md): Comprehensive data dictionary documenting all 15 tables, column types, primary keys, foreign keys, constraints, and relationship descriptions.
- [**dbms/erd.md**](dbms/erd.md): Complete Mermaid Entity-Relationship (ER) diagram representing all 15 tables, column schemas, and cardinality links.
