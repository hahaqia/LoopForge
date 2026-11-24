-- 取消项目 SOP 的跨项目共享：SOP 复用统一收敛为「平台 SOP → 复制到项目」。
-- 由运维手动执行，不随部署自动运行。
--
-- 执行前请先核对第 1 段的结果：这些 SOP 可能已被共享定时任务的版本快照 pin 引用，
-- 取消共享后其他项目的订阅方会解析失败。处理方式（二选一）：
--   a) 在「定时任务」里把引用的 SOP 改为平台 SOP；
--   b) 重新发布一版共享任务，让新版本不再引用被取消共享的 SOP。
--
-- 可重复执行。

-- 1) 列出将被取消共享的 SOP，供人工确认
SELECT `id`,
       `name`,
       JSON_UNQUOTE(JSON_EXTRACT(`payload`, '$.projectId')) AS `projectId`
  FROM `workflows`
 WHERE JSON_UNQUOTE(JSON_EXTRACT(`payload`, '$.shared')) = 'true';

-- 2) 去掉 shared 标记：SOP 留在原项目，成为项目私有资产
UPDATE `workflows`
   SET `payload` = JSON_REMOVE(`payload`, '$.shared')
 WHERE JSON_UNQUOTE(JSON_EXTRACT(`payload`, '$.shared')) = 'true';
