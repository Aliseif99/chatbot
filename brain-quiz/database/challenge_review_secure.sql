-- IQ LEAGUE / Secure question review (read-only)
-- Safe deployment: no table rewrites, no data deletion, no grading changes.
-- Intended for the Lovable Cloud database of project
-- 7b556b4f-e4e2-4864-abaf-11301094251a.
-- Not deployed automatically: requires running in that project's database.

BEGIN;

CREATE OR REPLACE FUNCTION public.challenge_review(
  _room uuid,
  _token text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO pg_catalog, public
AS $function$
DECLARE
  p public.challenge_players%ROWTYPE;
  r public.challenge_rooms%ROWTYPE;
  items jsonb;
  total_count integer;
  right_count integer;
  blank_count integer;
BEGIN
  -- A host token or a guessed room id must never be enough to read answers.
  IF _room IS NULL OR _token IS NULL
      OR length(_token) <> 64
      OR _token !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'رمز مراجعة غير صالح' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO p
  FROM public.challenge_players
  WHERE room_id = _room
    AND token_hash = encode(sha256(convert_to(_token, 'UTF8')), 'hex')
  ORDER BY round DESC
  LIMIT 1;

  IF NOT FOUND OR p.status <> 'finished' THEN
    RAISE EXCEPTION 'المراجعة متاحة فقط بعد إنهاء مشاركتك' USING ERRCODE = '28000';
  END IF;

  SELECT * INTO r FROM public.challenge_rooms WHERE id = _room;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'الغرفة غير موجودة' USING ERRCODE = '22023';
  END IF;

  -- In live/knockout modes, no reveal until every entrant in the
  -- same round has either finished or been excluded.
  IF r.mode <> 'open' AND EXISTS (
    SELECT 1 FROM public.challenge_players q
    WHERE q.room_id = _room AND q.round = p.round
      AND q.status IN ('waiting', 'in_progress')
  ) THEN
    RETURN jsonb_build_object('status', 'pending');
  END IF;

  SELECT
    count(*)::integer,
    count(*) FILTER (WHERE p.answers[i] IS NOT NULL
      AND p.answers[i] = p.answer_key[i])::integer,
    count(*) FILTER (WHERE p.answers[i] IS NULL)::integer,
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'index', i - 1,
          'question', ((p.questions -> (i - 1)) - 'correct' - 'answer_key' - 'model' - 'id'),
          'user_answer', p.answers[i],
          'correct_index', p.answer_key[i],
          'is_correct', p.answers[i] IS NOT NULL
                        AND p.answers[i] = p.answer_key[i]
        )
        ORDER BY i
      ),
      '[]'::jsonb
    )
  INTO total_count, right_count, blank_count, items
  FROM generate_subscripts(p.answer_key, 1) AS indexes(i);

  IF total_count = 0 OR total_count <> jsonb_array_length(p.questions)
      OR total_count > 25 THEN
    RAISE EXCEPTION 'بيانات المراجعة غير مكتملة' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'status', 'ready',
    'room_id', r.id,
    'round', p.round,
    'score', p.score,
    'total', total_count,
    'correct', right_count,
    'wrong', total_count - right_count - blank_count,
    'unanswered', blank_count,
    'items', items
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.challenge_review(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.challenge_review(uuid, text)
  TO anon, authenticated, service_role;

COMMIT;

-- Post-deployment validation (run after deploying):
-- 1. Invalid token is rejected.
-- 2. A waiting or in-progress player is rejected.
-- 3. A completed player can review only their own 10 questions.
-- 4. Live competition returns {"status":"pending"}
--    while another player is waiting or in progress.
-- 5. Confirm no tables grant SELECT on answer_key to anon.
