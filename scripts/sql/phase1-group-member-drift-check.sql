-- Phase 1 group_member compatibility drift checks.
-- Run only against local/dev/staging databases during Phase 1 readiness.
-- This query is read-only and must not be used as prod rollout evidence by itself.

SELECT 'missing_active_membership' AS check_name,
       COUNT(*) AS drift_count
FROM `user`
WHERE `user`.`group_id` IS NOT NULL
  AND `user`.`is_deleted` = FALSE
  AND NOT EXISTS (
      SELECT 1
      FROM `group_member`
      WHERE `group_member`.`user_id` = `user`.`id`
        AND `group_member`.`group_id` = `user`.`group_id`
        AND `group_member`.`status` = 'ACTIVE'
  );

SELECT 'legacy_group_mismatch' AS check_name,
       COUNT(*) AS drift_count
FROM `group_member`
JOIN `user` ON `user`.`id` = `group_member`.`user_id`
WHERE `group_member`.`status` = 'ACTIVE'
  AND `user`.`is_deleted` = FALSE
  AND (
      `user`.`group_id` IS NULL
      OR `user`.`group_id` <> `group_member`.`group_id`
  );

SELECT 'orphan_active_membership' AS check_name,
       COUNT(*) AS drift_count
FROM `group_member`
LEFT JOIN `user` ON `user`.`id` = `group_member`.`user_id`
LEFT JOIN `group` ON `group`.`id` = `group_member`.`group_id`
WHERE `group_member`.`status` = 'ACTIVE'
  AND (
      `user`.`id` IS NULL
      OR `group`.`id` IS NULL
      OR `user`.`is_deleted` = TRUE
  );

SELECT 'owner_without_active_membership' AS check_name,
       COUNT(*) AS drift_count
FROM `group`
WHERE `group`.`owner_id` IS NOT NULL
  AND NOT EXISTS (
      SELECT 1
      FROM `group_member`
      WHERE `group_member`.`group_id` = `group`.`id`
        AND `group_member`.`user_id` = `group`.`owner_id`
        AND `group_member`.`role` = 'OWNER'
        AND `group_member`.`status` = 'ACTIVE'
  );
