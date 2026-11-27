BEGIN READ ONLY;

SELECT coalesce(jsonb_agg(jsonb_build_object(
  'event_id', btrim(id), 'event_name', event_name, 'action_source', action_source,
  'status', status, 'occurred_at', event_at, 'receipt_at', sent_at, 'attempts', attempts,
  'http_status', http_status, 'error_code', error_code, 'error_subcode', error_subcode
) ORDER BY id), '[]'::jsonb)
FROM cra.meta_outbox
WHERE mode = 'production' AND status IN ('sent', 'uncertain', 'leased');

ROLLBACK;
