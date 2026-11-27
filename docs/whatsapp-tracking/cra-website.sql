BEGIN READ ONLY;

WITH visitor_rows AS (
  SELECT cra.key(visitor_id) AS visitor_key, analytics, ads, consent_version, consent_at AS consented_at,
         revoked_at, expires_at, first_touch, last_touch
  FROM cra.visitors
  WHERE expires_at > now()
  UNION ALL
  SELECT btrim(visitor_key), false, false, NULL, NULL, revoked_at, expires_at, '{}'::jsonb, '{}'::jsonb
  FROM cra.revocations
  WHERE expires_at > now()
), latest_visitors AS (
  SELECT DISTINCT ON (visitor_key) *
  FROM visitor_rows
  ORDER BY visitor_key, greatest(revoked_at, consented_at) DESC, (revoked_at IS NOT NULL) DESC
), events AS (
  SELECT cra.key(visitor_id) AS visitor_key, event_id, type AS kind, digest AS fingerprint, path,
         occurred_at, ads, last_touch
  FROM cra.site_events
  WHERE occurred_at > now() - interval '7 days'
), receipts AS (
  SELECT event_id, digest AS fingerprint, created_at
  FROM cra.intake_receipts
)
SELECT jsonb_build_object(
  'visitors', (SELECT coalesce(jsonb_agg(to_jsonb(latest_visitors)), '[]') FROM latest_visitors),
  'events', (SELECT coalesce(jsonb_agg(to_jsonb(events)), '[]') FROM events),
  'intake_receipts', (SELECT coalesce(jsonb_agg(to_jsonb(receipts)), '[]') FROM receipts)
);

ROLLBACK;
