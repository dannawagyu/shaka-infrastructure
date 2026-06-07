-- Phase 1 group_member compatibility repair dry-run.
-- Run only against local/dev/staging after backup evidence is captured.
-- This script intentionally ends with ROLLBACK. Replace with COMMIT only after
-- Auden reviews non-prod evidence and an operator owns the migration window.

START TRANSACTION;

INSERT INTO `group_member` (
    `group_id`,
    `user_id`,
    `role`,
    `status`,
    `joined_at`,
    `created_at`,
    `modified_at`
)
SELECT `user`.`group_id`,
       `user`.`id`,
       CASE WHEN `group`.`owner_id` = `user`.`id` THEN 'OWNER' ELSE 'MEMBER' END,
       'ACTIVE',
       CURRENT_TIMESTAMP(6),
       CURRENT_TIMESTAMP(6),
       CURRENT_TIMESTAMP(6)
FROM `user`
JOIN `group` ON `group`.`id` = `user`.`group_id`
WHERE `user`.`group_id` IS NOT NULL
  AND `user`.`is_deleted` = FALSE
ON DUPLICATE KEY UPDATE
    `role` = VALUES(`role`),
    `status` = 'ACTIVE',
    `left_at` = NULL,
    `modified_at` = CURRENT_TIMESTAMP(6);

UPDATE `group_member`
LEFT JOIN `user` ON `user`.`id` = `group_member`.`user_id`
SET `group_member`.`status` = 'LEFT',
    `group_member`.`left_at` = COALESCE(`group_member`.`left_at`, CURRENT_TIMESTAMP(6)),
    `group_member`.`modified_at` = CURRENT_TIMESTAMP(6)
WHERE `group_member`.`status` = 'ACTIVE'
  AND (
      `user`.`id` IS NULL
      OR `user`.`is_deleted` = TRUE
      OR `user`.`group_id` IS NULL
      OR `user`.`group_id` <> `group_member`.`group_id`
  );

SELECT 'post_repair_missing_active_membership' AS check_name,
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

ROLLBACK;
