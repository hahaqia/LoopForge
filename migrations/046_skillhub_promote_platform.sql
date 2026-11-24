-- 把项目里从 SkillHub 安装的技能提升为平台技能（内部 SkillHub）。
--
-- 背景：改造前安装必须带 projectId，市场技能落在项目里；改造后安装产物是
-- projectId 为空的平台技能，项目侧只能复制快照。本脚本为存量项目技能补一份
-- 平台技能，并把项目行清掉 source，让它变成自足副本（id、角色绑定都不变）。
--
-- 可重复执行：平台行按 "<slug>"（被项目行占用时用 "<slug>-platform"）命名，
-- 已存在时跳过插入；项目行 source 清掉后不再被游标选中。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysql -h <host> -u <user> -p <database> < migrations/046_skillhub_promote_platform.sql

DROP PROCEDURE IF EXISTS migrate_skillhub_promote_platform;

DELIMITER $$

CREATE PROCEDURE migrate_skillhub_promote_platform()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_skill VARCHAR(64);
  DECLARE v_slug VARCHAR(128);
  DECLARE v_platform_id VARCHAR(64);
  DECLARE v_taken INT DEFAULT 0;

  DECLARE skill_cur CURSOR FOR
    SELECT s.id, json_unquote(json_extract(s.payload, '$.source.slug'))
      FROM skills s
     WHERE coalesce(json_unquote(json_extract(s.payload, '$.projectId')), '') <> ''
       AND json_unquote(json_extract(s.payload, '$.source.provider')) = 'skillhub'
       AND coalesce(json_unquote(json_extract(s.payload, '$.source.slug')), '') <> '';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  OPEN skill_cur;
  skill_loop: LOOP
    FETCH skill_cur INTO v_skill, v_slug;
    IF done THEN
      LEAVE skill_loop;
    END IF;

    -- 平台 id 上限 64 字符，超长时用摘要后缀避免截断碰撞。
    SET v_platform_id = v_slug;
    IF char_length(v_platform_id) > 64 THEN
      SET v_platform_id = concat(left(v_platform_id, 43), '-', substring(md5(v_platform_id), 1, 20));
    END IF;

    -- 同 id 被某个项目行占用时，平台行换后缀。
    SELECT count(*) INTO v_taken
      FROM skills
     WHERE id = v_platform_id
       AND coalesce(json_unquote(json_extract(payload, '$.projectId')), '') <> '';
    IF v_taken > 0 THEN
      SET v_platform_id = concat(left(v_slug, 48), '-platform');
      IF char_length(v_platform_id) > 64 THEN
        SET v_platform_id = concat(left(v_slug, 43), '-', substring(md5(v_slug), 1, 20));
      END IF;
    END IF;

    INSERT INTO skills (id, name, payload, updated_at)
    SELECT v_platform_id,
           s.name,
           json_set(s.payload, '$.id', v_platform_id, '$.projectId', '', '$.shared', true),
           now(3)
      FROM skills s
     WHERE s.id = v_skill
    ON DUPLICATE KEY UPDATE skills.id = skills.id;

    INSERT INTO skill_files (skill_id, path, content, size, sha256, unix_mode, updated_at)
    SELECT v_platform_id, f.path, f.content, f.size, f.sha256, f.unix_mode, now(3)
      FROM skill_files f
     WHERE f.skill_id = v_skill
    ON DUPLICATE KEY UPDATE skill_files.skill_id = skill_files.skill_id;

    UPDATE skills
       SET payload = json_remove(payload, '$.source'), updated_at = now(3)
     WHERE id = v_skill;
  END LOOP;
  CLOSE skill_cur;
END$$

DELIMITER ;

CALL migrate_skillhub_promote_platform();
DROP PROCEDURE migrate_skillhub_promote_platform;
