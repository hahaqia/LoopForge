-- 技能改为项目隔离（a1 方案）。
--
-- 背景：skills 表里 projectId 为空的平台技能，此前靠 shared 对全部项目生效，
-- 角色可以直接绑定平台技能 id。改造后平台技能不再自动生效，项目必须先复制
-- 一份到本项目才能绑定。本脚本为「历史已绑定平台技能的角色」补一份项目副本，
-- 并把 role.skills 里的平台技能 id 改写为副本 id，保证升级后老角色行为不变。
--
-- 本脚本可重复执行：副本按 "<skillId>-<projectId>" 命名，已存在时跳过覆盖，
-- 不会覆盖项目里对该副本的手工修改。
--
-- 执行方式（部署不会自动运行，需手动执行）：
--   mysql -h <host> -u <user> -p <database> < migrations/045_project_skill_scopes.sql

DROP PROCEDURE IF EXISTS migrate_project_skill_scopes;

DELIMITER $$

CREATE PROCEDURE migrate_project_skill_scopes()
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_agent VARCHAR(64);
  DECLARE v_project VARCHAR(191);
  DECLARE v_skill VARCHAR(64);
  DECLARE v_new_id VARCHAR(64);
  DECLARE v_payload JSON;
  DECLARE v_arr JSON;

  DECLARE pair_cur CURSOR FOR
    SELECT a.id,
           json_unquote(json_extract(a.payload, '$.projectId')),
           s.id,
           a.payload
      FROM agents a
      JOIN skills s
        ON json_contains(coalesce(json_extract(a.payload, '$.skills'), json_array()), json_quote(s.id))
     WHERE coalesce(json_unquote(json_extract(s.payload, '$.projectId')), '') = ''
       AND coalesce(json_unquote(json_extract(a.payload, '$.projectId')), '') <> '';
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  OPEN pair_cur;
  pair_loop: LOOP
    FETCH pair_cur INTO v_agent, v_project, v_skill, v_payload;
    IF done THEN
      LEAVE pair_loop;
    END IF;

    -- 副本 id 上限 64 字符，超长时用摘要后缀避免截断碰撞。
    SET v_new_id = concat(v_skill, '-', v_project);
    IF char_length(v_new_id) > 64 THEN
      SET v_new_id = concat(left(v_new_id, 43), '-', substring(md5(v_new_id), 1, 20));
    END IF;

    INSERT INTO skills (id, name, payload, updated_at)
    SELECT v_new_id,
           s.name,
           json_set(s.payload, '$.id', v_new_id, '$.projectId', v_project, '$.shared', false),
           now(3)
      FROM skills s
     WHERE s.id = v_skill
    ON DUPLICATE KEY UPDATE id = id;

    INSERT INTO skill_files (skill_id, path, content, size, sha256, unix_mode, updated_at)
    SELECT v_new_id, f.path, f.content, f.size, f.sha256, f.unix_mode, now(3)
      FROM skill_files f
     WHERE f.skill_id = v_skill
    ON DUPLICATE KEY UPDATE skill_id = skill_id;

    SET v_arr = (
      SELECT json_arrayagg(IF(jt.v = v_skill, v_new_id, jt.v))
        FROM json_table(v_payload, '$.skills[*]' COLUMNS (v VARCHAR(191) PATH '$')) jt
    );
    IF v_arr IS NOT NULL THEN
      UPDATE agents SET payload = json_set(v_payload, '$.skills', v_arr) WHERE id = v_agent;
    END IF;
  END LOOP;
  CLOSE pair_cur;
END$$

DELIMITER ;

CALL migrate_project_skill_scopes();
DROP PROCEDURE migrate_project_skill_scopes;
