-- 品牌重命名：展示层 LoopForge → 智研工坊，技术标识 loopforge → zhiyan。
-- 面向「已安装旧版并保留数据」的升级场景；新装环境由 seed 直接写入新名称，无需执行。
-- 由运维手动执行，不随部署自动运行。

-- ---------- 目录资产（用户可见的名称、描述、提示词）----------
UPDATE `projects`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `generic_templates`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `workflows`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `agents`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `rules`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `skills`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `executors`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `mcp_servers`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `sandboxes`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `dockerfiles`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `environments`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

UPDATE `repositories`
   SET `name` = REPLACE(`name`, 'LoopForge', '智研工坊'),
       `payload` = REPLACE(REPLACE(`payload`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `name` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%' OR `payload` LIKE '%loopforge%';

-- ---------- 历史运行记录（运行详情、日志、产物里残留的旧名）----------
UPDATE `runs`
   SET `input` = REPLACE(`input`, 'LoopForge', '智研工坊'),
       `human_context` = REPLACE(`human_context`, 'LoopForge', '智研工坊'),
       `snapshot` = REPLACE(REPLACE(`snapshot`, 'LoopForge', '智研工坊'), 'loopforge', 'zhiyan')
 WHERE `input` LIKE '%LoopForge%' OR `human_context` LIKE '%LoopForge%'
    OR `snapshot` LIKE '%LoopForge%' OR `snapshot` LIKE '%loopforge%';

UPDATE `run_logs` SET `payload` = REPLACE(`payload`, 'LoopForge', '智研工坊') WHERE `payload` LIKE '%LoopForge%';
UPDATE `run_events` SET `message` = REPLACE(`message`, 'LoopForge', '智研工坊'),
                         `payload` = REPLACE(`payload`, 'LoopForge', '智研工坊')
 WHERE `message` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%';
UPDATE `run_telemetry` SET `payload` = REPLACE(`payload`, 'LoopForge', '智研工坊') WHERE `payload` LIKE '%LoopForge%';
UPDATE `run_artifacts` SET `content` = REPLACE(`content`, 'LoopForge', '智研工坊') WHERE `content` LIKE '%LoopForge%';

UPDATE `assistant_sessions` SET `title` = REPLACE(`title`, 'LoopForge', '智研工坊'),
                                `payload` = REPLACE(`payload`, 'LoopForge', '智研工坊')
 WHERE `title` LIKE '%LoopForge%' OR `payload` LIKE '%LoopForge%';
UPDATE `assistant_generations` SET `payload` = REPLACE(`payload`, 'LoopForge', '智研工坊') WHERE `payload` LIKE '%LoopForge%';
