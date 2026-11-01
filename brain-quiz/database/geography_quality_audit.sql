-- IQ LEAGUE · Geography bank QA
-- Run against the Lovable Cloud PostgreSQL database BEFORE enabling geography.
-- Read only. Checks all rows with exact answer distribution.
WITH v AS (
 SELECT id,qtype,tier,item,
  item->'options' AS choices,
  (item->>'correct')::int AS key_index,
  jsonb_array_length(item->'options') AS count_choices,
  (SELECT count(DISTINCT opt) FROM jsonb_array_elements_text(item->'options') opt) AS unique_choices,
  (SELECT count(*) FROM jsonb_array_elements_text(item->'options') opt WHERE opt = item->'options'->>(item->>'correct')::int) AS correct_occurrences
 FROM public.challenge_geo_bank
),
issues AS (
 SELECT id,qtype,tier,
 CASE
 WHEN count_choices<>4 THEN 'NOT_FOUR_OPTIONS'
 WHEN unique_choices<>4 THEN 'DUPLICATE_OPTIONS'
 WHEN key_index NOT BETWEEN 0 AND 3 THEN 'INVALID_CORRECT_INDEX'
 WHEN correct_occurrences<>1 THEN 'NOT_UNIQUE_CORRECT_ANSWER'
 WHEN item->>'prompt' IS NULL OR length(trim(item->>'prompt'))<8 THEN 'INVALID_PROMPT'
 WHEN qtype IN ('flag_country','flag_continent') AND COALESCE(item->>'flag_code','') !~ '^[A-Z]{2}$' THEN 'MISSING_FLAG'
 ELSE NULL END AS issue
 FROM v
)
SELECT * FROM issues WHERE issue IS NOT NULL ORDER BY issue,id;

-- Totals: release only if bad_rows=0 AND every question type has valid,
-- independently verified subject matter.
WITH v AS (
 SELECT item, jsonb_array_length(item->'options') n,
 (SELECT count(DISTINCT opt) FROM jsonb_array_elements_text(item->'options') opt) distinct_n
 FROM public.challenge_geo_bank
)
SELECT count(*) total_questions,
 count(*) FILTER (WHERE n<>4) bad_option_count,
 count(*) FILTER (WHERE distinct_n<>4) duplicate_options
FROM v;
