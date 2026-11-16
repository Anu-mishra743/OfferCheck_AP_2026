-- =============================================================================
-- OfferCheck — AP CP3: Database Queries & Operation Mapping
-- File: dbms/04_queries.sql
-- Database: PostgreSQL 15+ (Compatible with dbms/03_schema.sql)
--
-- DESCRIPTION:
-- Complete academic inventory of every runtime database operation (Q-01 through Q-83)
-- executed by the OfferCheck backend application.
--
-- METHODOLOGY & SQL CONVENTIONS:
-- 1. All queries model the genuine runtime behavior of Prisma Client and raw SQL.
-- 2. Representative SQL equivalents are presented in standard, performant PostgreSQL.
-- 3. Exact column names, PostgreSQL types, and enums match dbms/03_schema.sql.
-- 4. In accordance with the schema, primary and foreign keys for entities (reports,
--    identifiers, users, etc.) are of type TEXT. Token family identifiers are UUID.
-- 5. Exact interactive transaction boundaries (BEGIN...COMMIT) mirror runtime
--    prisma.$transaction blocks.
-- 6. Dynamic operations (batch inserts, variable identifier arrays, multi-clause
--    search filters) are explicitly documented with parameter placeholders ($1, $2, ...).
-- =============================================================================


-- =============================================================================
-- SECTION 1: AUTHENTICATION, ACCESS CONTROL & REFRESH TOKEN LIFECYCLE
-- Operations: Q-01 through Q-17 | Transactions: TX-01, TX-02
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-01 [READ]: Access Token Identity & Account Suspension Verification
-- Source: backend/src/middleware/auth.js:57 (prisma.user.findUnique)
-- Application Use Case: Verifies JWT signature claims against PostgreSQL, ensures
-- user exists, retrieves current database role, and blocks banned accounts.
-- Parameters:
--   $1: payload.sub (text, user UUID)
-- -----------------------------------------------------------------------------
SELECT id, email, name, role, is_banned
FROM users
WHERE id = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-02 [READ]: Pre-Registration Duplicate Email Check
-- Source: backend/src/services/auth.service.js:50 (prisma.user.findUnique)
-- Application Use Case: Checks whether an email is already registered before running
-- CPU-intensive bcrypt password hashing (cost factor 12).
-- Parameters:
--   $1: normalizedEmail (text, trimmed lowercase email)
-- -----------------------------------------------------------------------------
SELECT id
FROM users
WHERE email = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- TX-01 [TRANSACTION]: Atomic Student Registration & Initial Token Issuance
-- Source: backend/src/services/auth.service.js:71-93 (prisma.$transaction)
-- Operations: Q-03, Q-04
-- Application Use Case: Atomically registers a new user and issues their initial
-- opaque refresh token family to guarantee no orphaned user accounts without sessions.
-- -----------------------------------------------------------------------------
BEGIN;

  -- Q-03 [WRITE]: Insert New Student User
  -- Source: backend/src/services/auth.service.js:72 (tx.user.create)
  -- Parameters:
  --   $1: id (text, generated UUID)
  --   $2: name (varchar(120), trimmed)
  --   $3: email (varchar(254), normalized)
  --   $4: password_hash (varchar(72), bcrypt hash cost 12)
  --   $5: college (varchar(200), optional)
  INSERT INTO users (
    id, name, email, password_hash, role, college, is_banned, created_at, updated_at
  ) VALUES (
    $1, $2, $3, $4, 'student'::"UserRole", $5, false, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  )
  RETURNING id, name, email, role, college, created_at;

  -- Q-04 [WRITE]: Issue Initial Refresh Token
  -- Source: backend/src/services/auth.service.js:83 (tx.refreshToken.create)
  -- Workflow Mapping: user_id references id generated in Q-03 ($1).
  -- Parameters:
  --   $1: id (text, generated token UUID)
  --   $2: user_id (text FK -> users.id, from Q-03 user.id)
  --   $3: token_hash (char(64), SHA-256 hex digest of raw token)
  --   $4: family (uuid, random rotation family identifier)
  --   $5: expires_at (timestamp(3), CURRENT_TIMESTAMP + 7 days)
  INSERT INTO refresh_tokens (
    id, user_id, token_hash, family, expires_at, created_at
  ) VALUES (
    $1, $2, $3, $4, $5, CURRENT_TIMESTAMP
  );

COMMIT;


-- -----------------------------------------------------------------------------
-- Q-05 [READ]: User Login Credential Lookup
-- Source: backend/src/services/auth.service.js:122 (prisma.user.findUnique)
-- Application Use Case: Retrieves user record by normalized email for bcrypt
-- password verification and account ban inspection.
-- Parameters:
--   $1: normalizedEmail (text)
-- -----------------------------------------------------------------------------
SELECT id, name, email, password_hash, role, college, is_banned, created_at, updated_at
FROM users
WHERE email = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-06 [WRITE]: Login Refresh Token Issuance
-- Source: backend/src/services/auth.service.js:149 (prisma.refreshToken.create)
-- Application Use Case: Persists new refresh token upon successful password authentication.
-- Parameters:
--   $1: id (text, token UUID)
--   $2: user_id (text FK -> users.id)
--   $3: token_hash (char(64), SHA-256 hash)
--   $4: family (uuid, new session family)
--   $5: expires_at (timestamp(3), +7 days)
-- -----------------------------------------------------------------------------
INSERT INTO refresh_tokens (
  id, user_id, token_hash, family, expires_at, created_at
) VALUES (
  $1, $2, $3, $4, $5, CURRENT_TIMESTAMP
);


-- -----------------------------------------------------------------------------
-- Q-07 [READ]: Authenticated Current User Profile Retrieval
-- Source: backend/src/services/auth.service.js:177 (prisma.user.findUnique)
-- Application Use Case: Implements GET /api/auth/me to return verified user profile.
-- Parameters:
--   $1: userId (text, authenticated user ID)
-- -----------------------------------------------------------------------------
SELECT id, name, email, role, college, is_banned, created_at, updated_at
FROM users
WHERE id = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-08 [READ]: Refresh Token Lookup with User Join
-- Source: backend/src/services/auth.service.js:207 (prisma.refreshToken.findUnique)
-- Application Use Case: Looks up presented refresh token by SHA-256 hash and joins
-- user to evaluate token status, expiry, and user suspension.
-- Parameters:
--   $1: tokenHash (char(64), SHA-256 hash)
-- -----------------------------------------------------------------------------
SELECT
  r.id, r.user_id, r.token_hash, r.family, r.expires_at, r.revoked_at, r.created_at,
  u.id AS u_id, u.name AS u_name, u.email AS u_email, u.role AS u_role, u.is_banned AS u_is_banned
FROM refresh_tokens r
JOIN users u ON r.user_id = u.id
WHERE r.token_hash = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-09 [WRITE]: Emergency Family Revocation on Token Reuse Detection
-- Source: backend/src/services/auth.service.js:220 (prisma.refreshToken.updateMany)
-- Application Use Case: If an already-revoked refresh token is presented, a theft/replay
-- is detected; immediately revokes the entire token family.
-- Parameters:
--   $1: family (uuid, compromised session family)
-- -----------------------------------------------------------------------------
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE family = $1
  AND revoked_at IS NULL;


-- -----------------------------------------------------------------------------
-- Q-10 [WRITE]: Expired Token Revocation
-- Source: backend/src/services/auth.service.js:234 (prisma.refreshToken.update)
-- Application Use Case: Marks expired refresh token as revoked.
-- Parameters:
--   $1: id (text, token ID)
-- -----------------------------------------------------------------------------
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE id = $1;


-- -----------------------------------------------------------------------------
-- Q-11 [WRITE]: Revoke Active Tokens for Suspended User
-- Source: backend/src/services/auth.service.js:243 (prisma.refreshToken.updateMany)
-- Application Use Case: Pre-rotation check; revokes all active tokens if user is banned.
-- Parameters:
--   $1: userId (text, user ID)
-- -----------------------------------------------------------------------------
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE user_id = $1
  AND revoked_at IS NULL;


-- -----------------------------------------------------------------------------
-- TX-02 [TRANSACTION]: Atomic Refresh Token Rotation with Row-Level Lock
-- Source: backend/src/services/auth.service.js:258-308 (prisma.$transaction)
-- Operations: Q-12, Q-13, Q-14
-- Application Use Case: Executes single-flight token rotation; uses FOR UPDATE
-- lock on user to serialize concurrent rotations and prevent dual-rotation races.
-- -----------------------------------------------------------------------------
BEGIN;

  -- Q-12 [READ]: Row-Level Lock on User Record
  -- Source: backend/src/services/auth.service.js:260 (tx.$queryRaw)
  -- Parameters:
  --   $1: token.userId (text)
  SELECT id, email, role, is_banned AS "isBanned"
  FROM users
  WHERE id = $1
  FOR UPDATE;

  -- Q-13 [WRITE]: Conditional Revocation of Current Token
  -- Source: backend/src/services/auth.service.js:271 (tx.refreshToken.updateMany)
  -- Workflow Mapping: id is token.id (ID of the token being rotated).
  -- Parameters:
  --   $1: id (text, token.id)
  UPDATE refresh_tokens
  SET revoked_at = CURRENT_TIMESTAMP
  WHERE id = $1
    AND revoked_at IS NULL;

  -- Q-14 [WRITE]: Issue Rotated Token in Chain
  -- Source: backend/src/services/auth.service.js:292 (tx.refreshToken.create)
  -- Workflow Mapping: user_id references currentUser.id from Q-12 ($1); family preserves token.family.
  -- Parameters:
  --   $1: id (text, generated UUID newId)
  --   $2: user_id (text FK -> users.id, from Q-12 token.userId)
  --   $3: token_hash (char(64), SHA-256 of new opaque token)
  --   $4: family (uuid, preserves existing family chain)
  --   $5: expires_at (timestamp(3), +7 days)
  INSERT INTO refresh_tokens (
    id, user_id, token_hash, family, expires_at, created_at
  ) VALUES (
    $1, $2, $3, $4, $5, CURRENT_TIMESTAMP
  );

COMMIT;


-- -----------------------------------------------------------------------------
-- Q-15 [WRITE]: Standalone Invalidation on Transaction Exception (OUTSIDE TX-02)
-- Source: backend/src/services/auth.service.js:312 (prisma.refreshToken.updateMany)
-- Application Use Case: Executes in catch block strictly after TX-02 fails/aborts
-- with a 403 suspension error to invalidate all active user sessions.
-- Parameters:
--   $1: token.userId (text)
-- -----------------------------------------------------------------------------
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE user_id = $1
  AND revoked_at IS NULL;


-- -----------------------------------------------------------------------------
-- Q-16 [READ]: Logout Token Lookup
-- Source: backend/src/services/auth.service.js:341 (prisma.refreshToken.findUnique)
-- Application Use Case: Resolves session family UUID for submitted refresh token.
-- Parameters:
--   $1: tokenHash (char(64))
-- -----------------------------------------------------------------------------
SELECT id, user_id, token_hash, family, expires_at, revoked_at, created_at
FROM refresh_tokens
WHERE token_hash = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-17 [WRITE]: Logout Session Family Termination
-- Source: backend/src/services/auth.service.js:347 (prisma.refreshToken.updateMany)
-- Application Use Case: Terminates all active sessions belonging to the token family.
-- Parameters:
--   $1: family (uuid)
-- -----------------------------------------------------------------------------
UPDATE refresh_tokens
SET revoked_at = CURRENT_TIMESTAMP
WHERE family = $1
  AND revoked_at IS NULL;



-- =============================================================================
-- SECTION 2: INCIDENT REPORT INGESTION, DEDUPLICATION & SCORING
-- Operations: Q-18 through Q-25 | Transactions: TX-03
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-18 [READ]: Pre-Scoring Historical Intelligence Read (OUTSIDE TX-03)
-- Source: backend/src/services/report.service.js:54 (prisma.identifier.findMany)
-- Application Use Case: Evaluates historical verified reports linked to extracted
-- candidate identifiers. Executed outside TX-03 to avoid holding row locks during
-- CPU-intensive risk calculation.
-- Parameters:
--   $1: type1 ("IdentifierType") | $2: normalized1 (text)
--   $3: type2 ("IdentifierType") | $4: normalized2 (text)
-- -----------------------------------------------------------------------------
SELECT
  i.type,
  i.normalized_value,
  r.id AS report_id,
  r.status AS report_status
FROM identifiers i
LEFT JOIN report_identifiers ri ON i.id = ri.identifier_id
LEFT JOIN reports r ON ri.report_id = r.id AND r.status = 'verified'::"ReportStatus"
WHERE (i.type = $1::"IdentifierType" AND i.normalized_value = $2)
   OR (i.type = $3::"IdentifierType" AND i.normalized_value = $4);


-- -----------------------------------------------------------------------------
-- TX-03 [TRANSACTION]: Atomic Incident Report Ingestion
-- Source: backend/src/services/report.service.js:100-214 (prisma.$transaction)
-- Operations: Q-19, Q-20, Q-21, Q-22, Q-23, Q-24, Q-25
-- Application Use Case: Ingests an incident report atomically across 6 tables,
-- ensuring identifier upserts, report insertion, junction linking, versioned
-- scoring, factor breakdown, and audit logging succeed as a single unit.
-- -----------------------------------------------------------------------------
BEGIN;

  -- Q-19 [WRITE]: Native PostgreSQL Identifier Upsert
  -- Source: backend/src/services/report.service.js:104 (tx.identifier.upsert)
  -- Parameters:
  --   $1: id (text, generated UUID)
  --   $2: type ("IdentifierType", 'phone'|'email'|'upi'|'domain'|'bank_account')
  --   $3: value (varchar(300), raw value)
  --   $4: normalized_value (varchar(300), normalized canonical format)
  INSERT INTO identifiers (
    id, type, value, normalized_value, confidence, first_seen, last_seen
  ) VALUES (
    $1, $2::"IdentifierType", $3, $4, 'medium'::"ConfidenceLevel", CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  )
  ON CONFLICT (type, normalized_value)
  DO UPDATE SET last_seen = EXCLUDED.last_seen
  RETURNING id, type, normalized_value;

  -- Q-20 [WRITE]: Create Incident Report Header
  -- Source: backend/src/services/report.service.js:128 (tx.report.create)
  -- Workflow Mapping: submitted_by references authenticated user ID ($2).
  -- Parameters:
  --   $1: id (text, generated report UUID)
  --   $2: submitted_by (text FK -> users.id, userId)
  --   $3: company_name_raw (varchar(200), validatedData.companyNameRaw)
  --   $4: recruiter_name_raw (varchar(120), nullable)
  --   $5: domain_raw (varchar(253), nullable)
  --   $6: phone_raw (varchar(20), nullable)
  --   $7: email_raw (varchar(254), nullable)
  --   $8: upi_raw (varchar(80), nullable)
  --   $9: offer_message (text)
  --   $10: payment_request (varchar(300), nullable)
  --   $11: additional_notes (text, nullable)
  INSERT INTO reports (
    id, submitted_by, company_name_raw, recruiter_name_raw, domain_raw,
    phone_raw, email_raw, upi_raw, offer_message, payment_request,
    additional_notes, status, is_verified, is_inferred, submitted_at
  ) VALUES (
    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
    'pending'::"ReportStatus", false, false, CURRENT_TIMESTAMP
  )
  RETURNING *;
  -- Q-21 [WRITE]: Create Report-Identifier Junction Link
  -- Source: backend/src/services/report.service.js:148 (tx.reportIdentifier.create)
  -- Workflow Mapping: report_id from Q-20 ($1); identifier_id from Q-19 ($2); added_by is userId ($4).
  -- Parameters:
  --   $1: report_id (text FK -> reports.id)
  --   $2: identifier_id (text FK -> identifiers.id)
  --   $3: match_description (text)
  --   $4: added_by (text FK -> users.id)
  INSERT INTO report_identifiers (
    report_id, identifier_id, confidence, match_type, match_description, added_by, added_at
  ) VALUES (
    $1, $2, 'medium'::"ConfidenceLevel", 'direct_submission', $3, $4, CURRENT_TIMESTAMP
  );
  -- Q-22 [WRITE]: Create Versioned Risk Assessment Record
  -- Source: backend/src/services/report.service.js:161 (tx.riskAssessment.create)
  -- Workflow Mapping: report_id from Q-20 ($2); score/category from scoring engine.
  -- Parameters:
  --   $1: id (text, generated assessment UUID)
  --   $2: report_id (text FK -> reports.id)
  --   $3: score (smallint, computed score 0-100)
  --   $4: category ("RiskCategory", 'low'|'medium'|'high'|'critical')
  --   $5: summary (text)
  --   $6: disclaimer (text)
  INSERT INTO risk_assessments (
    id, report_id, score, category, summary, disclaimer,
    assessed_by, is_current, version, assessed_at
  ) VALUES (
    $1, $2, $3, $4::"RiskCategory", $5, $6, 'system', true, 1, CURRENT_TIMESTAMP
  )
  RETURNING *;
  -- Q-23 [WRITE]: Dynamic Multi-Row Risk Factors Batch Insertion
  -- Source: backend/src/services/report.service.js:177 (tx.riskFactor.createMany)
  -- Application Use Case: Batch inserts variable number of risk factors computed by engine.
  -- Workflow Mapping: assessment_id references risk_assessment.id from Q-22 ($2).
  -- Parameters: Dynamic factor row parameters ($1..$7 per factor tuple)
  --   $1: id (text, factor UUID)
  --   $2: assessment_id (text FK -> risk_assessments.id)
  --   $3: factor_key (varchar(80))
  --   $4: description (varchar(300))
  --   $5: weight (smallint)
  --   $6: confidence ("ConfidenceLevel")
  --   $7: explanation (text)
  INSERT INTO risk_factors (
    id, assessment_id, factor_key, description, weight,
    evidence_text, confidence, explanation
  ) VALUES
    ($1, $2, $3, $4, $5, NULL, $6::"ConfidenceLevel", $7)
    -- Additional factor rows are dynamically appended based on input assessment array length
  ;

  -- Q-24 [WRITE]: Record Report Submission Audit Log Entry
  -- Source: backend/src/services/report.service.js:191 (tx.auditLog.create)
  -- Workflow Mapping: actor_id is userId ($2); report_id from Q-20 ($3).
  -- Parameters:
  --   $1: id (text, generated log UUID)
  --   $2: actor_id (text FK -> users.id)
  --   $3: report_id (text FK -> reports.id)
  --   $4: notes (text)
  INSERT INTO audit_logs (
    id, actor_id, action, report_id, new_value, notes, created_at
  ) VALUES (
    $1, $2, 'REPORT_SUBMITTED'::"AuditAction", $3, 'pending', $4, CURRENT_TIMESTAMP
  );
  -- Q-25 [READ]: Retrieve Ingested Report Graph (INSIDE TX-03)
  -- Source: backend/src/services/report.service.js:202 (tx.report.findUnique)
  -- Application Use Case: Fetches complete created report graph with nested relations
  -- directly before transaction commit for role-based masking and response dispatch.
  -- Preserves all related identifiers and risk factors (no LIMIT 1 truncation).
  -- Workflow Mapping: id is report.id from Q-20 ($1).
  -- Parameters:
  --   $1: id (text, report.id)
  SELECT
    r.*,
    ri.identifier_id,
    i.id AS i_id, i.type AS i_type, i.value AS i_value, i.confidence AS i_confidence,
    ra.id AS ra_id, ra.score AS ra_score, ra.category AS ra_category,
    rf.id AS rf_id, rf.factor_key, rf.description AS rf_desc, rf.weight AS rf_weight, rf.explanation AS rf_expl
  FROM reports r
  LEFT JOIN report_identifiers ri ON r.id = ri.report_id
  LEFT JOIN identifiers i ON ri.identifier_id = i.id
  LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
  LEFT JOIN risk_factors rf ON ra.id = rf.assessment_id
  WHERE r.id = $1;

COMMIT;



-- =============================================================================
-- SECTION 3: PUBLIC INTELLIGENCE BROWSING & CROSS-REPORT CORRELATION
-- Operations: Q-26 through Q-39
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-26 [READ]: Count Public Verified Reports
-- Source: backend/src/services/report.service.js:289 (prisma.report.count)
-- Application Use Case: Returns total count for public discovery pagination.
-- Parameters:
--   $1: searchTerm (optional, text)
--   $2: companyId (optional, text)
--   $3: recruiterId (optional, text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM reports r
WHERE r.status = 'verified'::"ReportStatus"
  AND ($1::text IS NULL OR r.company_name_raw ILIKE '%' || $1 || '%' OR r.domain_raw ILIKE '%' || $1 || '%')
  AND ($2::text IS NULL OR r.company_id = $2)
  AND ($3::text IS NULL OR r.recruiter_id = $3);


-- -----------------------------------------------------------------------------
-- Q-27 [READ]: Browse Public Verified Reports with Relations
-- Source: backend/src/services/report.service.js:290 (prisma.report.findMany)
-- Application Use Case: Paginated public report search joining company, recruiter,
-- active risk assessment, and linked contact indicators.
-- Parameters:
--   $1: searchTerm (text) | $2: companyId (text) | $3: recruiterId (text)
--   $4: limit (int) | $5: offset (int)
-- -----------------------------------------------------------------------------
SELECT
  r.id, r.submitted_by, r.company_id, r.recruiter_id, r.company_name_raw,
  r.recruiter_name_raw, r.domain_raw, r.phone_raw, r.email_raw, r.upi_raw,
  r.offer_message, r.payment_request, r.status, r.submitted_at, r.reviewed_at,
  r.is_verified, r.is_inferred,
  c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
  rec.id AS recruiter_id, rec.name AS recruiter_name, rec.phone AS recruiter_phone, rec.email AS recruiter_email,
  ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary AS risk_summary, ra.assessed_at,
  ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value, i.confidence AS identifier_confidence
FROM reports r
LEFT JOIN companies c ON r.company_id = c.id
LEFT JOIN recruiters rec ON r.recruiter_id = rec.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN report_identifiers ri ON r.id = ri.report_id
LEFT JOIN identifiers i ON ri.identifier_id = i.id
WHERE r.status = 'verified'::"ReportStatus"
  AND ($1::text IS NULL OR r.company_name_raw ILIKE '%' || $1 || '%' OR r.domain_raw ILIKE '%' || $1 || '%')
  AND ($2::text IS NULL OR r.company_id = $2)
  AND ($3::text IS NULL OR r.recruiter_id = $3)
ORDER BY r.submitted_at DESC, r.id ASC
LIMIT $4 OFFSET $5;


-- -----------------------------------------------------------------------------
-- Q-28 [READ]: Get Single Report by ID with Complete Relational Hierarchy
-- Source: backend/src/services/report.service.js:341 (prisma.report.findUnique)
-- Application Use Case: Retrieves single report joining submitter, reviewer,
-- company, recruiter, current assessment, factors, and identifiers.
-- Parameters:
--   $1: reportId (text)
-- -----------------------------------------------------------------------------
SELECT
  r.*,
  c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
  rec.id AS recruiter_id, rec.name AS recruiter_name,
  sub.id AS submitter_id, sub.name AS submitter_name, sub.role AS submitter_role,
  rev.id AS reviewer_id, rev.name AS reviewer_name, rev.role AS reviewer_role,
  ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value, i.confidence AS identifier_confidence,
  ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary AS risk_summary,
  rf.id AS factor_id, rf.factor_key, rf.description AS factor_desc, rf.weight AS factor_weight, rf.explanation AS factor_expl
FROM reports r
LEFT JOIN companies c ON r.company_id = c.id
LEFT JOIN recruiters rec ON r.recruiter_id = rec.id
LEFT JOIN users sub ON r.submitted_by = sub.id
LEFT JOIN users rev ON r.reviewed_by = rev.id
LEFT JOIN report_identifiers ri ON r.id = ri.report_id
LEFT JOIN identifiers i ON ri.identifier_id = i.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN risk_factors rf ON ra.id = rf.assessment_id
WHERE r.id = $1;


-- -----------------------------------------------------------------------------
-- Q-29 [READ]: Check Bookmark Status for Single Report View
-- Source: backend/src/services/report.service.js:384 (prisma.savedReport.findUnique)
-- Application Use Case: Checks if currently viewing user has bookmarked the report.
-- Parameters:
--   $1: userId (text) | $2: reportId (text)
-- -----------------------------------------------------------------------------
SELECT user_id, report_id, saved_at
FROM saved_reports
WHERE user_id = $1 AND report_id = $2
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-30 [READ]: Count User's Submitted Reports
-- Source: backend/src/services/report.service.js:444 (prisma.report.count)
-- Application Use Case: Returns total count of candidate's own reports across statuses.
-- Parameters:
--   $1: userId (text) | $2: status (optional, text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM reports
WHERE submitted_by = $1
  AND ($2::text IS NULL OR status = $2::"ReportStatus");


-- -----------------------------------------------------------------------------
-- Q-31 [READ]: Retrieve User's Submitted Reports with Relations
-- Source: backend/src/services/report.service.js:445 (prisma.report.findMany)
-- Application Use Case: Paginated retrieval of authenticated user's own reports.
-- Parameters:
--   $1: userId (text) | $2: status (text) | $3: limit (int) | $4: offset (int)
-- -----------------------------------------------------------------------------
SELECT
  r.*,
  c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
  rec.id AS recruiter_id, rec.name AS recruiter_name,
  ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary, ra.assessed_at,
  ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value
FROM reports r
LEFT JOIN companies c ON r.company_id = c.id
LEFT JOIN recruiters rec ON r.recruiter_id = rec.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN report_identifiers ri ON r.id = ri.report_id
LEFT JOIN identifiers i ON ri.identifier_id = i.id
WHERE r.submitted_by = $1
  AND ($2::text IS NULL OR r.status = $2::"ReportStatus")
ORDER BY r.submitted_at DESC, r.id ASC
LIMIT $3 OFFSET $4;


-- -----------------------------------------------------------------------------
-- Q-32 [READ]: Ownership & Verification Guard for Bookmark Action
-- Source: backend/src/services/report.service.js:495 (prisma.report.findUnique)
-- Application Use Case: Validates target report visibility before bookmarking.
-- Parameters:
--   $1: reportId (text)
-- -----------------------------------------------------------------------------
SELECT id, status, submitted_by
FROM reports
WHERE id = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-33 [WRITE]: Idempotent Bookmark Creation
-- Source: backend/src/services/report.service.js:513 (prisma.savedReport.upsert)
-- Application Use Case: Saves report to user's bookmarks (idempotent NO-OP on conflict).
-- Parameters:
--   $1: userId (text FK -> users.id) | $2: reportId (text FK -> reports.id)
-- -----------------------------------------------------------------------------
INSERT INTO saved_reports (user_id, report_id, saved_at)
VALUES ($1, $2, CURRENT_TIMESTAMP)
ON CONFLICT (user_id, report_id)
DO NOTHING;


-- -----------------------------------------------------------------------------
-- Q-34 [WRITE]: Idempotent Bookmark Removal
-- Source: backend/src/services/report.service.js:539 (prisma.savedReport.deleteMany)
-- Application Use Case: Deletes saved report bookmark.
-- Parameters:
--   $1: userId (text) | $2: reportId (text)
-- -----------------------------------------------------------------------------
DELETE FROM saved_reports
WHERE user_id = $1 AND report_id = $2;


-- -----------------------------------------------------------------------------
-- Q-35 [READ]: Count User's Saved Reports (Leak-Protected)
-- Source: backend/src/services/report.service.js:581 (prisma.savedReport.count)
-- Application Use Case: Counts saved reports ensuring unverified reports belonging
-- to other users are strictly excluded.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM saved_reports sr
JOIN reports r ON sr.report_id = r.id
WHERE sr.user_id = $1
  AND (r.status = 'verified'::"ReportStatus" OR r.submitted_by = $1);


-- -----------------------------------------------------------------------------
-- Q-36 [READ]: Paginated User Saved Reports with Relations
-- Source: backend/src/services/report.service.js:582 (prisma.savedReport.findMany)
-- Application Use Case: Retrieves saved reports with report and risk hierarchy.
-- Parameters:
--   $1: userId (text) | $2: limit (int) | $3: offset (int)
-- -----------------------------------------------------------------------------
SELECT
  sr.saved_at, sr.user_id, sr.report_id,
  r.id, r.company_name_raw, r.status, r.submitted_at, r.is_verified,
  c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
  rec.id AS recruiter_id, rec.name AS recruiter_name,
  ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary, ra.assessed_at,
  ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value
FROM saved_reports sr
JOIN reports r ON sr.report_id = r.id
LEFT JOIN companies c ON r.company_id = c.id
LEFT JOIN recruiters rec ON r.recruiter_id = rec.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN report_identifiers ri ON r.id = ri.report_id
LEFT JOIN identifiers i ON ri.identifier_id = i.id
WHERE sr.user_id = $1
  AND (r.status = 'verified'::"ReportStatus" OR r.submitted_by = $1)
ORDER BY sr.saved_at DESC, sr.report_id ASC
LIMIT $2 OFFSET $3;


-- -----------------------------------------------------------------------------
-- Q-37 [READ]: Authorize Source Report for Related Reports Search
-- Source: backend/src/services/report.service.js:646 (prisma.report.findUnique)
-- Application Use Case: Ensures caller is authorized to view source report before
-- querying related incidents.
-- Parameters:
--   $1: reportId (text)
-- -----------------------------------------------------------------------------
SELECT id, status, submitted_by
FROM reports
WHERE id = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-38 [READ]: Retrieve Linked Identifier IDs for Source Report
-- Source: backend/src/services/report.service.js:667 (prisma.reportIdentifier.findMany)
-- Application Use Case: Fetches array of identifier IDs linked to source report.
-- Parameters:
--   $1: reportId (text)
-- -----------------------------------------------------------------------------
SELECT identifier_id
FROM report_identifiers
WHERE report_id = $1;


-- -----------------------------------------------------------------------------
-- Q-39 [READ]: Query Related Verified Reports Sharing Identifiers
-- Source: backend/src/services/report.service.js:681 (prisma.report.findMany)
-- Application Use Case: Finds up to 10 verified reports sharing any of the source
-- report's indicators. Uses ANY($2::text[]) array matching.
-- Parameters:
--   $1: reportId (text, source report to exclude)
--   $2: identifierIds (text[], array of identifier UUID strings)
-- -----------------------------------------------------------------------------
SELECT
  r.id, r.company_name_raw, r.status, r.submitted_at,
  c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
  ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary,
  ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value, i.confidence AS identifier_confidence
FROM reports r
LEFT JOIN companies c ON r.company_id = c.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN report_identifiers ri ON r.id = ri.report_id AND ri.identifier_id = ANY($2::text[])
LEFT JOIN identifiers i ON ri.identifier_id = i.id
WHERE r.id <> $1
  AND r.status = 'verified'::"ReportStatus"
  AND EXISTS (
    SELECT 1 FROM report_identifiers sub_ri
    WHERE sub_ri.report_id = r.id AND sub_ri.identifier_id = ANY($2::text[])
  )
ORDER BY r.submitted_at DESC, r.id ASC
LIMIT 10;



-- =============================================================================
-- SECTION 4: ADMINISTRATIVE MODERATION & IMMUTABLE AUDIT TRAILS
-- Operations: Q-40 through Q-45 | Transactions: TX-04
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-40 [READ]: Admin Moderation Queue Count
-- Source: backend/src/services/report.service.js:827 (prisma.report.count)
-- Application Use Case: Counts reports in moderation queue (default: status = 'pending').
-- Parameters:
--   $1: statusFilter (optional, text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM reports
WHERE ($1::text IS NULL OR status = $1::"ReportStatus");


-- -----------------------------------------------------------------------------
-- Q-41 [READ]: Admin Paginated Moderation List
-- Source: backend/src/services/report.service.js:828 (prisma.report.findMany)
-- Application Use Case: Moderation queue directory joining submitter and reviewer.
-- Parameters:
--   $1: statusFilter (text) | $2: limit (int) | $3: offset (int)
-- -----------------------------------------------------------------------------
SELECT
  r.*,
  c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
  rec.id AS recruiter_id, rec.name AS recruiter_name,
  sub.id AS submitter_id, sub.name AS submitter_name, sub.college AS submitter_college, sub.role AS submitter_role,
  rev.id AS reviewer_id, rev.name AS reviewer_name, rev.role AS reviewer_role,
  ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary, ra.assessed_at,
  ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value, i.confidence AS identifier_confidence
FROM reports r
LEFT JOIN companies c ON r.company_id = c.id
LEFT JOIN recruiters rec ON r.recruiter_id = rec.id
LEFT JOIN users sub ON r.submitted_by = sub.id
LEFT JOIN users rev ON r.reviewed_by = rev.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN report_identifiers ri ON r.id = ri.report_id
LEFT JOIN identifiers i ON ri.identifier_id = i.id
WHERE ($1::text IS NULL OR r.status = $1::"ReportStatus")
ORDER BY r.submitted_at DESC, r.id ASC
LIMIT $2 OFFSET $3;


-- -----------------------------------------------------------------------------
-- TX-04 [TRANSACTION]: Atomic Moderation Status Transition and Audit Logging
-- Source: backend/src/services/report.service.js:892-995 (prisma.$transaction)
-- Operations: Q-42, Q-43, Q-44, Q-45
-- Application Use Case: Executes concurrency-safe report status transition, updates
-- review timestamps and reviewer attribution, writes immutable audit log, and
-- returns updated report hierarchy (all 4 steps inside TX-04).
-- -----------------------------------------------------------------------------
BEGIN;

  -- Q-42 [READ]: Fetch Current Report Status inside Transaction
  -- Source: backend/src/services/report.service.js:894 (tx.report.findUnique)
  -- Parameters:
  --   $1: reportId (text)
  SELECT id, status, company_name_raw, reviewed_by, reviewed_at
  FROM reports
  WHERE id = $1
  LIMIT 1;

  -- Q-43 [WRITE]: Conditional Concurrency-Guarded Status Update
  -- Source: backend/src/services/report.service.js:936 (tx.report.updateMany)
  -- Parameters:
  --   $1: reportId (text)
  --   $2: targetStatus ("ReportStatus", 'verified'|'rejected'|'investigating')
  --   $3: adminId (text FK -> users.id)
  --   $4: expectedCurrentStatus ("ReportStatus")
  UPDATE reports
  SET status = $2::"ReportStatus",
      is_verified = ($2::"ReportStatus" = 'verified'::"ReportStatus"),
      reviewed_by = $3,
      reviewed_at = CURRENT_TIMESTAMP
  WHERE id = $1
    AND status = $4::"ReportStatus";

  -- Q-44 [WRITE]: Record STATUS_CHANGED Audit Log Entry
  -- Source: backend/src/services/report.service.js:958 (tx.auditLog.create)
  -- Workflow Mapping: actor_id is adminId ($2); report_id is currentReport.id ($3).
  -- Parameters:
  --   $1: id (text, generated log UUID)
  --   $2: actor_id (text FK -> users.id, adminId)
  --   $3: report_id (text FK -> reports.id, reportId)
  --   $4: old_value (varchar(100), expectedCurrentStatus)
  --   $5: new_value (varchar(100), targetStatus)
  --   $6: notes (text, audit notes)
  INSERT INTO audit_logs (
    id, actor_id, action, report_id, old_value, new_value, notes, created_at
  ) VALUES (
    $1, $2, 'STATUS_CHANGED'::"AuditAction", $3, $4, $5, $6, CURRENT_TIMESTAMP
  );
  -- Q-45 [READ]: Retrieve Final Updated Report Hierarchy (INSIDE TX-04)
  -- Source: backend/src/services/report.service.js:972 (tx.report.findUnique)
  -- Application Use Case: Fetches full updated report graph with nested relations
  -- directly before transaction commit for response dispatch without truncation.
  -- Parameters:
  --   $1: reportId (text)
  SELECT
    r.id, r.status, r.is_verified, r.company_name_raw, r.reviewed_at,
    c.id AS company_id, c.name AS company_name, c.domain AS company_domain, c.flagged AS company_flagged,
    rec.id AS recruiter_id, rec.name AS recruiter_name,
    sub.id AS submitter_id, sub.name AS submitter_name, sub.role AS submitter_role,
    rev.id AS reviewer_id, rev.name AS reviewer_name, rev.role AS reviewer_role,
    ra.id AS assessment_id, ra.score AS risk_score, ra.category AS risk_category, ra.summary, ra.assessed_at,
    ri.identifier_id, i.type AS identifier_type, i.value AS identifier_value, i.confidence
  FROM reports r
  LEFT JOIN companies c ON r.company_id = c.id
  LEFT JOIN recruiters rec ON r.recruiter_id = rec.id
  LEFT JOIN users sub ON r.submitted_by = sub.id
  LEFT JOIN users rev ON r.reviewed_by = rev.id
  LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
  LEFT JOIN report_identifiers ri ON r.id = ri.report_id
  LEFT JOIN identifiers i ON ri.identifier_id = i.id
  WHERE r.id = $1;

COMMIT;


-- =============================================================================
-- SECTION 5: OFFER VERIFICATION ENGINE & CANDIDATE HISTORY
-- Operations: Q-46 through Q-57
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-46 [READ]: Pre-Scoring Intelligence Lookup on Offer Check
-- Source: backend/src/services/check.service.js:143 (prisma.identifier.findMany)
-- Application Use Case: Correlates candidate offer input against verified indicators.
-- Parameters:
--   $1: type1 ("IdentifierType") | $2: normalized1 (text)
-- -----------------------------------------------------------------------------
SELECT
  i.id, i.type, i.value, i.normalized_value, i.risk_score, i.confidence,
  r.id AS report_id, r.company_name_raw, r.status, r.is_verified,
  ra.score AS risk_score, ra.category AS risk_category
FROM identifiers i
LEFT JOIN report_identifiers ri ON i.id = ri.identifier_id
LEFT JOIN reports r ON ri.report_id = r.id AND r.status = 'verified'::"ReportStatus"
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
WHERE (i.type = $1::"IdentifierType" AND i.normalized_value = $2);


-- -----------------------------------------------------------------------------
-- Q-47 [WRITE]: Record Offer Check with JSONB Assessment Result Snapshot
-- Source: backend/src/services/check.service.js:242 (prisma.offerCheck.create)
-- Application Use Case: Persists candidate check input, computed score, and JSONB snapshot.
-- Parameters:
--   $1: id (text, check UUID)
--   $2: user_id (text, nullable FK -> users.id)
--   $3: company_name (varchar(200))
--   $4: phone_query (varchar(20))
--   $5: email_query (varchar(254))
--   $6: upi_query (varchar(80))
--   $7: domain_query (varchar(253))
--   $8: risk_score (smallint)
--   $9: risk_category ("RiskCategory")
--   $10: result (jsonb snapshot)
--   $11: ip_hash (char(64), HMAC-SHA256 client IP hash)
-- -----------------------------------------------------------------------------
INSERT INTO offer_checks (
  id, user_id, company_name, phone_query, email_query, upi_query, domain_query,
  risk_score, risk_category, result, ip_hash, checked_at
) VALUES (
  $1, $2, $3, $4, $5, $6, $7, $8, $9::"RiskCategory", $10::jsonb, $11, CURRENT_TIMESTAMP
)
RETURNING *;


-- -----------------------------------------------------------------------------
-- Q-48 [READ]: Count User's Offer Check History
-- Source: backend/src/services/check.service.js:300 (prisma.offerCheck.count)
-- Application Use Case: Returns total checks count for candidate history pagination.
-- Parameters:
--   $1: userId (text) | $2: riskCategoryFilter (optional, text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM offer_checks
WHERE user_id = $1
  AND ($2::text IS NULL OR risk_category = $2::"RiskCategory");


-- -----------------------------------------------------------------------------
-- Q-49 [READ]: Paginated User Offer Check History
-- Source: backend/src/services/check.service.js:301 (prisma.offerCheck.findMany)
-- Application Use Case: Retrieves paginated candidate offer checks.
-- Parameters:
--   $1: userId (text) | $2: riskCategoryFilter (text) | $3: limit (int) | $4: offset (int)
-- -----------------------------------------------------------------------------
SELECT id, company_name, phone_query, email_query, upi_query, domain_query,
       risk_score, risk_category, checked_at, result
FROM offer_checks
WHERE user_id = $1
  AND ($2::text IS NULL OR risk_category = $2::"RiskCategory")
ORDER BY checked_at DESC
LIMIT $3 OFFSET $4;


-- -----------------------------------------------------------------------------
-- Q-50 [READ]: Get Single Offer Check by ID
-- Source: backend/src/services/check.service.js:352 (prisma.offerCheck.findUnique)
-- Application Use Case: Looks up single offer check ensuring ownership isolation.
-- Parameters:
--   $1: checkId (text)
-- -----------------------------------------------------------------------------
SELECT id, user_id, company_name, phone_query, email_query, upi_query,
       domain_query, risk_score, risk_category, checked_at, result
FROM offer_checks
WHERE id = $1
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-51 [READ]: User Dashboard KPI — Total Checks Run
-- Source: backend/src/services/check.service.js:406 (prisma.offerCheck.count)
-- Application Use Case: Computes total checks performed by authenticated candidate.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM offer_checks
WHERE user_id = $1;


-- -----------------------------------------------------------------------------
-- Q-52 [READ]: User Dashboard KPI — Total Reports Submitted
-- Source: backend/src/services/check.service.js:407 (prisma.report.count)
-- Application Use Case: Computes total fraud reports submitted by candidate.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM reports
WHERE submitted_by = $1;


-- -----------------------------------------------------------------------------
-- Q-53 [READ]: User Dashboard KPI — Total Saved Reports
-- Source: backend/src/services/check.service.js:408 (prisma.savedReport.count)
-- Application Use Case: Computes total reports bookmarked by candidate.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM saved_reports
WHERE user_id = $1;


-- -----------------------------------------------------------------------------
-- Q-54 [READ]: User Dashboard KPI — High & Critical Risk Checks Count
-- Source: backend/src/services/check.service.js:409 (prisma.offerCheck.count)
-- Application Use Case: Computes number of high/critical risk checks for user.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM offer_checks
WHERE user_id = $1
  AND risk_category IN ('critical'::"RiskCategory", 'high'::"RiskCategory");


-- -----------------------------------------------------------------------------
-- Q-55 [READ]: User Dashboard KPI — Average Risk Score Aggregation
-- Source: backend/src/services/check.service.js:415 (prisma.offerCheck.aggregate)
-- Application Use Case: Computes arithmetic mean risk score across candidate checks.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT AVG(risk_score) AS avg_risk_score
FROM offer_checks
WHERE user_id = $1
  AND risk_score IS NOT NULL;


-- -----------------------------------------------------------------------------
-- Q-56 [READ]: User Dashboard KPI — 7-Day Activity Trend
-- Source: backend/src/services/check.service.js:419 (prisma.offerCheck.findMany)
-- Application Use Case: Fetches timestamps of checks within rolling 7-day UTC window.
-- Parameters:
--   $1: userId (text) | $2: startDateUtc (timestamp(3))
-- -----------------------------------------------------------------------------
SELECT checked_at
FROM offer_checks
WHERE user_id = $1
  AND checked_at >= $2
ORDER BY checked_at ASC;


-- -----------------------------------------------------------------------------
-- Q-57 [READ]: User Dashboard KPI — Recent 5 Checks
-- Source: backend/src/services/check.service.js:426 (prisma.offerCheck.findMany)
-- Application Use Case: Retrieves 5 most recent offer checks for dashboard display.
-- Parameters:
--   $1: userId (text)
-- -----------------------------------------------------------------------------
SELECT id, user_id, company_name, phone_query, email_query, upi_query,
       domain_query, risk_score, risk_category, checked_at, result
FROM offer_checks
WHERE user_id = $1
ORDER BY checked_at DESC
LIMIT 5;



-- =============================================================================
-- SECTION 6: INTELLIGENCE GRAPH, SHARED INDICATORS & FRAUD CLUSTERS
-- Operations: Q-58 through Q-66
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-58 [READ]: Identify Shared Identifiers (Linked to >= 2 Verified Reports)
-- Source: backend/src/services/graph.service.js:155 (prisma.reportIdentifier.groupBy)
-- Application Use Case: Discovers genuine shared intelligence indicators across verified reports.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT ri.identifier_id, COUNT(ri.report_id) AS report_count
FROM report_identifiers ri
JOIN reports r ON ri.report_id = r.id
WHERE r.status = 'verified'::"ReportStatus"
GROUP BY ri.identifier_id
HAVING COUNT(ri.report_id) >= 2
ORDER BY report_count DESC;


-- -----------------------------------------------------------------------------
-- Q-59 [READ]: Fetch Verified Junctions for Shared Identifiers
-- Source: backend/src/services/graph.service.js:182 (prisma.reportIdentifier.findMany)
-- Application Use Case: Retrieves junction rows for candidate shared indicators
-- joining report metadata, risk assessments, and cluster assignments.
-- Parameters:
--   $1: candidateSharedIds (text[], array of identifier UUIDs)
-- -----------------------------------------------------------------------------
SELECT
  ri.report_id, ri.identifier_id, ri.confidence, ri.match_type,
  i.id AS i_id, i.type, i.value, i.risk_score, i.flagged, i.confidence AS i_conf,
  r.id AS r_id, r.company_name_raw, r.status,
  ra.score AS risk_score, ra.category AS risk_category,
  cl.id AS cluster_id, cl.name AS cluster_name
FROM report_identifiers ri
JOIN identifiers i ON ri.identifier_id = i.id
JOIN reports r ON ri.report_id = r.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN cluster_reports cr ON r.id = cr.report_id
LEFT JOIN clusters cl ON cr.cluster_id = cl.id
WHERE ri.identifier_id = ANY($1::text[])
  AND r.status = 'verified'::"ReportStatus"
ORDER BY r.submitted_at DESC, ri.report_id ASC, ri.identifier_id ASC;


-- -----------------------------------------------------------------------------
-- Q-60 [READ]: Subgraph Initialization — Validate Report Start Node
-- Source: backend/src/services/graph.service.js:362 (prisma.report.findFirst)
-- Application Use Case: Verifies starting entity is a verified report.
-- Parameters:
--   $1: startNodeId (text)
-- -----------------------------------------------------------------------------
SELECT id
FROM reports
WHERE id = $1
  AND status = 'verified'::"ReportStatus"
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-61 [READ]: Subgraph Initialization — Validate Identifier Start Node
-- Source: backend/src/services/graph.service.js:366 (prisma.identifier.findFirst)
-- Application Use Case: Verifies starting entity is an identifier linked to verified reports.
-- Parameters:
--   $1: startNodeId (text) | $2: flaggedOnly (boolean)
-- -----------------------------------------------------------------------------
SELECT i.id
FROM identifiers i
WHERE i.id = $1
  AND ($2::boolean = false OR i.flagged = true)
  AND EXISTS (
    SELECT 1 FROM report_identifiers ri
    JOIN reports r ON ri.report_id = r.id
    WHERE ri.identifier_id = i.id AND r.status = 'verified'::"ReportStatus"
  )
LIMIT 1;


-- -----------------------------------------------------------------------------
-- Q-62 [READ]: Subgraph BFS Step 1 — Expand Reports to Identifiers
-- Source: backend/src/services/graph.service.js:405 (prisma.reportIdentifier.findMany)
-- Application Use Case: Batched BFS expansion from frontier reports to identifiers.
-- Parameters:
--   $1: frontierReportIds (text[]) | $2: flaggedOnly (boolean)
-- -----------------------------------------------------------------------------
SELECT DISTINCT ri.identifier_id
FROM report_identifiers ri
JOIN reports r ON ri.report_id = r.id
LEFT JOIN identifiers i ON ri.identifier_id = i.id
WHERE ri.report_id = ANY($1::text[])
  AND r.status = 'verified'::"ReportStatus"
  AND ($2::boolean = false OR i.flagged = true);


-- -----------------------------------------------------------------------------
-- Q-63 [READ]: Subgraph BFS Step 2 — Expand Identifiers to Reports
-- Source: backend/src/services/graph.service.js:428 (prisma.reportIdentifier.findMany)
-- Application Use Case: Batched BFS expansion from frontier identifiers to reports.
-- Parameters:
--   $1: frontierIdentifierIds (text[])
-- -----------------------------------------------------------------------------
SELECT DISTINCT ri.report_id
FROM report_identifiers ri
JOIN reports r ON ri.report_id = r.id
WHERE ri.identifier_id = ANY($1::text[])
  AND r.status = 'verified'::"ReportStatus";


-- -----------------------------------------------------------------------------
-- Q-64 [READ]: Subgraph Batch Read — Visited Verified Report Nodes
-- Source: backend/src/services/graph.service.js:456 (prisma.report.findMany)
-- Application Use Case: Retrieves full node metadata for visited verified reports.
-- Parameters:
--   $1: visitedReportIds (text[])
-- -----------------------------------------------------------------------------
SELECT
  r.id, r.company_name_raw, r.status,
  ra.score AS risk_score, ra.category AS risk_category,
  cl.id AS cluster_id, cl.name AS cluster_name
FROM reports r
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN cluster_reports cr ON r.id = cr.report_id
LEFT JOIN clusters cl ON cr.cluster_id = cl.id
WHERE r.id = ANY($1::text[])
  AND r.status = 'verified'::"ReportStatus";


-- -----------------------------------------------------------------------------
-- Q-65 [READ]: Subgraph Batch Read — Visited Identifier Nodes
-- Source: backend/src/services/graph.service.js:476 (prisma.identifier.findMany)
-- Application Use Case: Retrieves full node metadata for visited identifiers.
-- Parameters:
--   $1: visitedIdentifierIds (text[]) | $2: flaggedOnly (boolean)
-- -----------------------------------------------------------------------------
SELECT id, type, value, risk_score, flagged, confidence
FROM identifiers
WHERE id = ANY($1::text[])
  AND ($2::boolean = false OR flagged = true);


-- -----------------------------------------------------------------------------
-- Q-66 [READ]: Subgraph Batch Read — Visited Junction Edges
-- Source: backend/src/services/graph.service.js:490 (prisma.reportIdentifier.findMany)
-- Application Use Case: Retrieves junction edges connecting visited graph nodes.
-- Parameters:
--   $1: visitedReportIds (text[]) | $2: visitedIdentifierIds (text[])
-- -----------------------------------------------------------------------------
SELECT ri.report_id, ri.identifier_id, ri.confidence
FROM report_identifiers ri
JOIN reports r ON ri.report_id = r.id
WHERE ri.report_id = ANY($1::text[])
  AND ri.identifier_id = ANY($2::text[])
  AND r.status = 'verified'::"ReportStatus";


-- =============================================================================
-- SECTION 7: PLATFORM KPIS, ANALYTICS, CLUSTERS & AUDIT TRAILS
-- Operations: Q-67 through Q-83
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Q-67 [READ]: Public Landing Stats — Verified Reports Count
-- Source: backend/src/services/graph.service.js:594 (prisma.report.count)
-- Application Use Case: Public counter of verified fraud incident reports.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM reports
WHERE status = 'verified'::"ReportStatus";


-- -----------------------------------------------------------------------------
-- Q-68 [READ]: Public Landing Stats — Verified Connected Identifiers Count
-- Source: backend/src/services/graph.service.js:597 (prisma.identifier.count)
-- Application Use Case: Public counter of identifiers linked to verified reports.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(DISTINCT i.id)
FROM identifiers i
JOIN report_identifiers ri ON i.id = ri.identifier_id
JOIN reports r ON ri.report_id = r.id
WHERE r.status = 'verified'::"ReportStatus";


-- -----------------------------------------------------------------------------
-- Q-69 [READ]: Public Landing Stats — Shared Indicators Grouping
-- Source: backend/src/services/graph.service.js:606 (prisma.reportIdentifier.groupBy)
-- Application Use Case: Groups identifiers to calculate platform shared count (>= 2).
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT ri.identifier_id, COUNT(ri.report_id) AS report_count
FROM report_identifiers ri
JOIN reports r ON ri.report_id = r.id
WHERE r.status = 'verified'::"ReportStatus"
GROUP BY ri.identifier_id;


-- -----------------------------------------------------------------------------
-- Q-70 [READ]: Public Landing Stats — Active Verified Clusters Count
-- Source: backend/src/services/graph.service.js:615 (prisma.cluster.count)
-- Application Use Case: Public counter of active clusters linked to verified reports.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(DISTINCT cl.id)
FROM clusters cl
JOIN cluster_reports cr ON cl.id = cr.cluster_id
JOIN reports r ON cr.report_id = r.id
WHERE cl.status = 'active'::"ClusterStatus"
  AND r.status = 'verified'::"ReportStatus";


-- -----------------------------------------------------------------------------
-- Q-71 [READ]: Admin Overview KPI — Total Platform Reports
-- Source: backend/src/services/admin.service.js:38 (prisma.report.count)
-- Application Use Case: Computes total reports across all moderation statuses.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM reports;


-- -----------------------------------------------------------------------------
-- Q-72 [READ]: Admin Overview KPI — Report Count Grouped by Status
-- Source: backend/src/services/admin.service.js:39 (prisma.report.groupBy)
-- Application Use Case: Aggregates incident reports by status (pending/verified/rejected/investigating).
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT status, COUNT(id) AS status_count
FROM reports
GROUP BY status;


-- -----------------------------------------------------------------------------
-- Q-73 [READ]: Admin Overview KPI — Current Assessments Grouped by Risk Category
-- Source: backend/src/services/admin.service.js:43 (prisma.riskAssessment.groupBy)
-- Application Use Case: Aggregates platform risk distribution across active assessments.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT category, COUNT(id) AS category_count
FROM risk_assessments
WHERE is_current = TRUE
GROUP BY category;


-- -----------------------------------------------------------------------------
-- Q-74 [READ]: Admin Overview KPI — Total Platform Identifiers
-- Source: backend/src/services/admin.service.js:48 (prisma.identifier.count)
-- Application Use Case: Computes total known contact indicators.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM identifiers;


-- -----------------------------------------------------------------------------
-- Q-75 [READ]: Admin Overview KPI — Total Flagged Identifiers
-- Source: backend/src/services/admin.service.js:49 (prisma.identifier.count)
-- Application Use Case: Computes total flagged contact indicators.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM identifiers
WHERE flagged = true;


-- -----------------------------------------------------------------------------
-- Q-76 [READ]: Admin Overview KPI — Total Active Clusters
-- Source: backend/src/services/admin.service.js:50 (prisma.cluster.count)
-- Application Use Case: Computes total active fraud clusters.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM clusters
WHERE status = 'active'::"ClusterStatus";


-- -----------------------------------------------------------------------------
-- Q-77 [READ]: Admin Overview KPI — Total Registered Users
-- Source: backend/src/services/admin.service.js:51 (prisma.user.count)
-- Application Use Case: Computes total registered candidate and administrator accounts.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM users;


-- -----------------------------------------------------------------------------
-- Q-78 [READ]: Admin Overview KPI — Total Offer Checks Executed
-- Source: backend/src/services/admin.service.js:52 (prisma.offerCheck.count)
-- Application Use Case: Computes total candidate offer checks executed platform-wide.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM offer_checks;


-- -----------------------------------------------------------------------------
-- Q-79 [READ]: Admin Identifier Directory Count
-- Source: backend/src/services/admin.service.js:136 (prisma.identifier.count)
-- Application Use Case: Filtered count of identifiers in admin management directory.
-- Parameters:
--   $1: typeFilter (optional, text)
--   $2: flaggedFilter (optional, boolean)
--   $3: search (optional, text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM identifiers
WHERE ($1::text IS NULL OR type = $1::"IdentifierType")
  AND ($2::boolean IS NULL OR flagged = $2)
  AND ($3::text IS NULL OR value ILIKE '%' || $3 || '%' OR normalized_value ILIKE '%' || $3 || '%');


-- -----------------------------------------------------------------------------
-- Q-80 [READ]: Admin Identifier Directory Paginated with Report Counts
-- Source: backend/src/services/admin.service.js:137 (prisma.identifier.findMany)
-- Application Use Case: Retrieves paginated identifiers for admin inspection with
-- count of linked reports via LEFT JOIN to report_identifiers.
-- Parameters:
--   $1: typeFilter (text) | $2: flaggedFilter (boolean) | $3: search (text)
--   $4: limit (int) | $5: offset (int)
-- -----------------------------------------------------------------------------
SELECT
  i.id, i.type, i.value, i.normalized_value, i.risk_score,
  i.flagged, i.confidence, i.notes, i.first_seen, i.last_seen,
  COUNT(ri.report_id) AS report_count
FROM identifiers i
LEFT JOIN report_identifiers ri ON i.id = ri.identifier_id
WHERE ($1::text IS NULL OR i.type = $1::"IdentifierType")
  AND ($2::boolean IS NULL OR i.flagged = $2)
  AND ($3::text IS NULL OR i.value ILIKE '%' || $3 || '%' OR i.normalized_value ILIKE '%' || $3 || '%')
GROUP BY i.id
ORDER BY i.last_seen DESC, i.id ASC
LIMIT $4 OFFSET $5;


-- -----------------------------------------------------------------------------
-- Q-81 [READ]: Fraud Cluster Inspection with Member Report Relations
-- Source: backend/src/services/admin.service.js:187 (prisma.cluster.findMany)
-- Application Use Case: Retrieves fraud clusters with nested member reports, current
-- risk assessment scores, and connected identifier IDs via relational joins; average
-- risk scores and unique identifier sets are aggregated in-memory by the application
-- service layer in JavaScript from this result set.
-- Parameters: None
-- -----------------------------------------------------------------------------
SELECT
  cl.id, cl.name, cl.description, cl.confidence, cl.status,
  cl.connection_basis, cl.discovered_at, cl.updated_at,
  r.id AS member_report_id, r.status AS member_report_status, r.company_name_raw,
  ra.score AS member_risk_score,
  ri.identifier_id
FROM clusters cl
LEFT JOIN cluster_reports cr ON cl.id = cr.cluster_id
LEFT JOIN reports r ON cr.report_id = r.id
LEFT JOIN risk_assessments ra ON r.id = ra.report_id AND ra.is_current = TRUE
LEFT JOIN report_identifiers ri ON r.id = ri.report_id
ORDER BY cl.discovered_at DESC;


-- -----------------------------------------------------------------------------
-- Q-82 [READ]: Filtered Audit Logs Count
-- Source: backend/src/services/admin.service.js:284 (prisma.auditLog.count)
-- Application Use Case: Total count for admin audit log pagination.
-- Parameters:
--   $1: actionFilter (optional, text) | $2: reportIdFilter (optional, text)
-- -----------------------------------------------------------------------------
SELECT COUNT(*)
FROM audit_logs
WHERE ($1::text IS NULL OR action = $1::"AuditAction")
  AND ($2::text IS NULL OR report_id = $2);


-- -----------------------------------------------------------------------------
-- Q-83 [READ]: Paginated Platform Audit Trail Inspection with Actor Join
-- Source: backend/src/services/admin.service.js:285 (prisma.auditLog.findMany)
-- Application Use Case: Retrieves immutable platform audit logs resolving actor names.
-- Parameters:
--   $1: actionFilter (text) | $2: reportIdFilter (text) | $3: limit (int) | $4: offset (int)
-- -----------------------------------------------------------------------------
SELECT
  a.id, a.actor_id, a.action, a.report_id, a.identifier_id, a.cluster_id,
  a.target_user_id, a.old_value, a.new_value, a.notes, a.created_at,
  u.id AS actor_user_id, u.name AS actor_name, u.role AS actor_role
FROM audit_logs a
JOIN users u ON a.actor_id = u.id
WHERE ($1::text IS NULL OR a.action = $1::"AuditAction")
  AND ($2::text IS NULL OR a.report_id = $2)
ORDER BY a.created_at DESC, a.id ASC
LIMIT $3 OFFSET $4;


-- =============================================================================
-- END OF QUERIES (Q-01 through Q-83 successfully documented)
-- =============================================================================
