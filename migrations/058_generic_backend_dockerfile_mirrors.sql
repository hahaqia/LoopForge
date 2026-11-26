-- 058_generic_backend_dockerfile_mirrors.sql
--
-- 把 generic-backend 运行镜像的 apt / npm 源换成国内镜像。
--
-- 背景：官方源在开发机上 apt 约 100kB/s、registry.npmjs.org 约 240kB/s。
-- 一条 RUN 里装 @openai/codex + @anthropic-ai/claude-code + @tencent-ai/codebuddy-code
-- 会让首次派发长时间卡在「构建沙箱镜像」，实测 40 分钟无进展，同时占满 runner
-- 唯一的并发槽（-concurrency 1），后面排队的任务全部显示为运行中但实际没开始。
-- 换成中科大 apt（约 900kB/s）和 npmmirror（约 4.7MB/s）后，同内容构建 65 秒完成。
--
-- 内容须与 internal/runtime/sandbox_docker.go 的 IsolatedDockerfile 保持一致；
-- 改了那边要同步重跑本脚本，否则存量 catalog 行仍走旧定义。
--
-- 幂等：重复执行只是把同样的 content 再写一遍；镜像内容不变时缓存 tag 不变，
-- 已构建的 agentflow-img-<hash> 继续命中，不会触发重建。
--
-- 执行后需要重新构建一次镜像才能生效，平台下次派发时会自动构建。
--
-- 明文对照（hex 只是为了避免反斜杠和单引号转义出错）：
--
--   FROM node:22-bookworm
--   RUN if [ -f /etc/apt/sources.list.d/debian.sources ]; then sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' /etc/apt/sources.list.d/debian.sources; fi \
--    && apt-get update && apt-get install -y --no-install-recommends git openssh-client python3 ripgrep ca-certificates curl && rm -rf /var/lib/apt/lists/*
--   RUN npm install -g --registry=https://registry.npmmirror.com @openai/codex @anthropic-ai/claude-code
--   ARG CODEBUDDY_PACKAGE=@tencent-ai/codebuddy-code
--   RUN if [ -n "$CODEBUDDY_PACKAGE" ]; then npm install -g --registry=https://registry.npmmirror.com "$CODEBUDDY_PACKAGE"; fi
--   WORKDIR /workspace

UPDATE dockerfiles
SET payload = JSON_SET(payload, '$.content', CONVERT(0x46524f4d206e6f64653a32322d626f6f6b776f726d0a52554e206966205b202d66202f6574632f6170742f736f75726365732e6c6973742e642f64656269616e2e736f7572636573205d3b207468656e20736564202d692027737c6465622e64656269616e2e6f72677c6d6972726f72732e757374632e6564752e636e7c6727202f6574632f6170742f736f75726365732e6c6973742e642f64656269616e2e736f75726365733b206669205c0a202626206170742d67657420757064617465202626206170742d67657420696e7374616c6c202d79202d2d6e6f2d696e7374616c6c2d7265636f6d6d656e647320676974206f70656e7373682d636c69656e7420707974686f6e3320726970677265702063612d636572746966696361746573206375726c20262620726d202d7266202f7661722f6c69622f6170742f6c697374732f2a0a52554e206e706d20696e7374616c6c202d67202d2d72656769737472793d68747470733a2f2f72656769737472792e6e706d6d6972726f722e636f6d20406f70656e61692f636f6465782040616e7468726f7069632d61692f636c617564652d636f64650a41524720434f444542554444595f5041434b4147453d4074656e63656e742d61692f636f646562756464792d636f64650a52554e206966205b202d6e202224434f444542554444595f5041434b41474522205d3b207468656e206e706d20696e7374616c6c202d67202d2d72656769737472793d68747470733a2f2f72656769737472792e6e706d6d6972726f722e636f6d202224434f444542554444595f5041434b414745223b2066690a574f524b444952202f776f726b73706163650a USING utf8mb4)),
    updated_at = NOW(3)
WHERE id = 'generic-backend';
