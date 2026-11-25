function renderCatalogScopes(){
  const workflows=state.data?.workflows||[],agents=state.data?.agents||[];
  const sopProject=workflows.filter(w=>!catalogGeneric(w)&&catalogOwned(w.projectId)).length;
  const sopGeneric=workflows.filter(w=>catalogGeneric(w)).length;
  const agentProject=agents.filter(a=>catalogOwned(a.projectId)).length;
  const agentShared=agents.filter(a=>catalogShared(a.projectId,a.shared)).length;
  const set=(id,n)=>{const el=document.querySelector(`[data-scope-count="${id}"]`);if(el)el.textContent=n};
  set('sop-project',sopProject);set('sop-generic',sopGeneric);set('agent-project',agentProject);set('agent-shared',agentShared);
  document.querySelectorAll('[data-scope-for]').forEach(bar=>{
    const current=bar.dataset.scopeFor==='agent'?state.agentScope:state.sopScope;
    bar.querySelectorAll('[data-scope]').forEach(btn=>btn.classList.toggle('on',btn.dataset.scope===current));
  });
}
// 角色仍可跨项目共享；SOP 不再共享（复用统一走「平台 SOP → 复制到项目」）。
async function toggleShare(agentId){
  const item=(state.data.agents||[]).find(x=>x.id===agentId);
  if(!item||!catalogOwned(item.projectId))return toast('只能共享本项目的内容');
  try{
    // 先回读完整定义：列表里的角色可能缺少技能/规则等字段。
    const full=await api(`/api/agents/${encodeURIComponent(agentId)}`);
    if(!catalogOwned(full.projectId))return toast('只能共享本项目的内容');
    // Sharing a role also shares the project's skills bound to it, and a
    // shared skill is installed into every conversation, so name them first.
    // The list is reloaded: a skill may have been added since the page loaded.
    if(!full.shared&&(full.skills||[]).length)state.data.skills=await api('/api/skills',{silent:true});
    const newlyShared=!full.shared?(state.data.skills||[]).filter(s=>(full.skills||[]).includes(s.id)&&s.projectId===full.projectId&&!s.shared):[];
    if(newlyShared.length&&!(await afConfirm({title:'共享角色',message:`共享这个角色会同时共享它绑定的技能：${newlyShared.map(s=>s.name||s.id).join('、')}。${SHARED_SKILL_NOTICE}`,confirmText:'共享'})))return;
    const saved=await api('/api/agents',{method:'PUT',body:JSON.stringify({...full,shared:!full.shared})});
    const list=state.data.agents||[],i=list.findIndex(x=>x.id===saved.id);
    if(i>=0)list[i]=saved;else list.unshift(saved);
    if(state.selectedAgent===saved.id)state.selectedAgent=saved.id;
    if(saved.shared){(state.data.rules||[]).forEach(item=>{if((saved.rules||[]).includes(item.id)&&item.projectId===saved.projectId)item.shared=true});(state.data.skills||[]).forEach(item=>{if((saved.skills||[]).includes(item.id)&&item.projectId===saved.projectId)item.shared=true})}
    renderAgents();
    toast(saved.shared?'已共享，其他项目可在共享页看到':'已取消共享');
  }catch(e){toast(e.message)}
}
// --- 通用模板：依赖预检与复制 -------------------------------------------------
// Generic templates are platform blueprints. Their 发起 MR node needs a 工蜂 Git
// Token to push and a 工蜂 MCP to create the merge
// request, so the catalog surfaces that dependency before adoption.
const GENERIC_REQUIREMENT_CHECKS={
  'gongfeng-git-token':{label:'Git 访问令牌',hint:'按主机认证并推送工作分支。',fix:'settings',fixLabel:'去个人配置配置',check:()=>!!(userById(state.currentUser?.id)||{}).gitHttpCredentialsConfigured},
  'gongfeng-mcp':{label:'工蜂 MCP',hint:'调用工蜂接口创建 MR；未安装时复制出的 SOP 需安装后为「交付工程师」角色绑定。',fix:'mcp',fixLabel:'去能力资产添加',check:()=>gongfengMCPInstalled()},
  'tapd-mcp':{label:'TAPD MCP',hint:'把验收结论回写 TAPD；未安装时只产出待人工粘贴的说明。',fix:'mcp',fixLabel:'去能力资产添加',check:()=>tapdMCPInstalled()}
};
function gongfengMarketItem(){
  return (state.mcpMarket||[]).find(item=>(item.aliases||[]).includes('gongfeng')||/gongfeng/i.test(item.url||''))||null;
}
// With the catalog loaded, a market-installed row is recognised by its market
// ID or alias even when that ID does not mention the service. Rows without a
// market ID (custom MCPs) and installs made before the catalog loads fall back
// to name/URL matching. Kept self-contained: genericRequirementRows swallows
// errors, so a missing helper from another file would silently read as "not installed".
function projectMCPInstalled(market,pattern){
  const keys=market?[market.id,...(market.aliases||[])].map(key=>String(key||'').toLowerCase()).filter(Boolean):[];
  return (state.data?.mcpServers||[]).some(item=>{
    if(item.scope!=='project'||item.projectId!==state.projectFilter)return false;
    if(keys.length&&item.marketId&&keys.includes(String(item.marketId).toLowerCase()))return true;
    return pattern.test(`${item.name||''} ${item.url||''} ${item.marketId||''}`);
  });
}
function gongfengMCPInstalled(){return projectMCPInstalled(gongfengMarketItem(),/gongfeng|工蜂/i)}
function tapdMarketItem(){
  return (state.mcpMarket||[]).find(item=>(item.aliases||[]).includes('tapd')||/tapd/i.test(item.url||''))||null;
}
function tapdMCPInstalled(){return projectMCPInstalled(tapdMarketItem(),/tapd/i)}
function genericRequirementRows(w){
  return (w?.requirements||[]).map(req=>{
    const meta=GENERIC_REQUIREMENT_CHECKS[req.key]||{};
    let ok=false;
    try{ok=typeof meta.check==='function'?!!meta.check():false}catch(e){ok=false}
    return {key:req.key,label:req.label||meta.label||req.key,hint:req.hint||meta.hint||'',nodeId:req.nodeId||'',ok,fix:meta.fix||'',fixLabel:meta.fixLabel||'去处理'};
  });
}
function genericRequirementChips(w){
  const rows=genericRequirementRows(w);
  if(!rows.length)return '';
  return `<div class="sop-requirements">${rows.map(r=>sopBadge(r.label,r.ok?'success':'warn',r.ok?'check':'alert',r.hint)).join('')}</div>`;
}
function sopResourceRequirements(w){
  const project=(state.data?.projects||[]).find(p=>p.id===(w?.projectId||state.projectFilter))||(state.data?.projects||[]).find(p=>p.id===state.projectFilter);
  const driver=((state.data?.sandboxes||[]).find(sb=>sb.id===w?.sandboxProfileId)||{}).driver||(/docker/i.test(w?.sandboxProfileId||'')?'docker':'');
  const usesRepo=(catalogGeneric(w)||(w?.tags||[]).some(t=>String(t).startsWith('generic-source:')))&&!!project?.defaultRepositoryId;
  const rows=[];
  if(usesRepo)rows.push({key:'run-repo',label:'GitHub 仓库（已绑定）',ok:true,hint:'使用项目已绑定的仓库。访问私有仓库或推送代码时需要在个人配置中配置 GitHub Token；未绑定仓库时可在任务工作区直接运行。'});
  if(driver==='docker')rows.push({key:'run-docker',label:'Docker',ok:state.data?.capabilities?.docker!==false,hint:state.data?.capabilities?.docker===false?'平台连不上 Docker，这个 SOP 现在跑不了。重新运行 scripts/install.sh 会自动安装并挂载 Docker。':'在隔离的 Docker 沙箱里运行，首次运行会构建镜像，需要几分钟。'});
  return rows;
}
function sopRunRequirements(w){
  const nodes=w?.nodes||[],user=userById(state.currentUser?.id)||{};
  const resources=sopResourceRequirements(w);
  if(catalogGeneric(w)||(w?.tags||[]).some(tag=>tag.startsWith('generic-source:')))return resources;
  const rows=[];
  const executorIds=nodes.filter(n=>n.type==='agent'&&!isPreviewBuildNode(n.id)).map(node=>{
    const role=(state.data?.agents||[]).find(a=>a.id===node.agentId);
    return role?.executorId||node.executorId||'codebuddy';
  });
  if(w?.preview?.enabled)executorIds.push(workflowPreviewExecutor(w));
  const providers=new Set();
  for(const id of executorIds){
    const kind=(state.data?.executors||[]).find(e=>e.id===id)?.kind||id;
    if(['codebuddy','codex','claude','claude-code','opencode','cursor','agy','kimi','pi','dsh','zcode'].includes(kind))providers.add(kind==='claude'?'claude-code':kind);
  }
  const agentLabels={opencode:'OpenCode',cursor:'Cursor CLI',agy:'Antigravity',kimi:'Kimi Code',pi:'Pi',dsh:'DeepSeek Harness',zcode:'ZCode'};
  for(const kind of providers){
    const known={codebuddy:['CodeBuddy','codeBuddyApiKey','codeBuddyApiKeyConfigured'],codex:['Codex','codexApiKey','codexApiKeyConfigured'],'claude-code':['Claude Code','claudeCodeApiKey','claudeCodeApiKeyConfigured']}[kind];
    const [label,field,flag]=known||[agentLabels[kind]||kind,'agentCli.'+kind,'agentCliConfigured'];
    if(!known){
      rows.push({key:'run-key-'+kind,field,fix:'settings',fixLabel:'去个人配置配置',label:label+' API Key',ok:!!user.agentCliCredentials?.[kind]?.apiKeyConfigured,hint:lfT('Agent 节点使用 '+label+'，请在个人配置里配置对应 API Key。','Agent nodes use '+label+'. Configure its API key in Settings.')});
      continue;
    }
    rows.push({key:'run-key-'+kind,field,fix:'settings',fixLabel:'去个人配置配置',label:label+' API Key',ok:!!user[flag]||!!window.AgentFlowAssistantModels?.catalog().engines?.find(engine=>engine.id===kind&&engine.configured),hint:lfT('Agent 节点使用 '+label+'，请在个人配置里配置对应 API Key。','Agent nodes use '+label+'. Configure its API key in Settings.')});
  }
  return [...rows,...resources];
}
function sopRunRequirementChips(w){
  const rows=sopRunRequirements(w);
  if(!rows.length)return '';
  return `<div class="sop-requirements" aria-label="运行条件">${rows.map(r=>sopBadge((r.ok?'':'需要 ')+r.label,r.ok?'success':'warn',r.ok?'check':'alert',r.hint)).join('')}</div>`;
}
// --- 流程模板卡片 -------------------------------------------------------------
// Each card exposes one primary action; the rest live in the ⋯ popover.
const SOP_HEALTH_TONES={'运行中':{tone:'info',icon:'lamp'},'待审批':{tone:'warn',icon:'user-hold'},'已闭环':{tone:'success',icon:'check'},'有阻塞':{tone:'error',icon:'alert'},'未闭环':{tone:'error',icon:'alert'},'从未运行':{tone:'neutral',icon:'circle'}};
function sopHealthTone(health){return SOP_HEALTH_TONES[health?.label]||{tone:'neutral',icon:'circle'}}
function sopBadge(label,tone,icon,title){
  const mark=icon==='lamp'?'<span class="sop-lamp" aria-hidden="true"><i></i></span>':icon?huiIcon(icon):'';
  return `<span class="sop-badge tone-${tone}"${title?` title="${escapeHTML(title)}"`:''}>${mark}<span class="sop-badge-label">${escapeHTML(label)}</span></span>`;
}
function sopHealthBadge(health){const {tone,icon}=sopHealthTone(health);return sopBadge(health?.label||'',tone,icon)}
function sopStatusBadge(w){
  if(catalogGeneric(w))return sopBadge('通用','accent','layers');
  if(w?.status==='published')return sopBadge('已发布','success','check');
  if(w?.status==='archived')return sopBadge('已归档','neutral','circle');
  return sopBadge('草稿','neutral','edit');
}
function sopCardHead(left,hint,right){return `<div class="sop-card-head"><div>${left}<span class="sop-card-hint">${escapeHTML(hint||'')}</span></div>${right}</div>`}
function sopCardTitle(w){return `<div class="sop-card-title"><span class="sop-card-tile">${huiIcon('workflow')}</span><h3 title="${escapeHTML(w.name)}">${escapeHTML(w.name)}</h3></div>`}
function sopCardPrimary(attr,id,label,icon='',title=''){return `<button type="button" class="sop-card-primary" ${attr}="${escapeHTML(id)}" data-hover-ink-control${title?` title="${escapeHTML(title)}"`:''}>${icon?huiIcon(icon):''}${escapeHTML(label)}</button>`}
function sopCardMoreButton(w){return `<button type="button" class="sop-card-more" data-sop-menu="${escapeHTML(w.id)}" data-hover-ink-control aria-haspopup="menu" aria-expanded="false" aria-label="更多操作" title="更多操作">${huiIcon('more-horizontal')}</button>`}
function sopRunKpis(m,liveCount){return `<div class="sop-kpis"><span><b>${m.totalRuns||0}</b>运行</span><span><b>${m.succeededRuns||0}</b>成功</span><span${m.failedRuns>0?' class="is-bad"':''}><b>${m.failedRuns||0}</b>失败</span><span><b>${liveCount}</b>进行中</span></div>`}
function sopRunCardBody(w,m,liveCount){
  const health=metricHealth(m,liveCount);
  return `${sopCardHead(sopHealthBadge(health),m.totalRuns?`${percent(m.successRate)} 成功率`:health.hint,sopStatusBadge(w))}${sopCardTitle(w)}<p>${escapeHTML(w.description||'暂无流程说明')}</p>${sopRunRequirementChips(w)}${sopRunKpis(m,liveCount)}`;
}
function projectSOPCard(w,m={},liveCount=0){
  const recent=formatTimestamp(m.lastRunAt);
  const meta=`${w.owner||'未分配负责人'} · v${w.version||1} · ${recent?`最近 ${recent}`:'尚未运行'}`;
  return `<article class="sop-card${state.highlightSOPId===w.id?' is-highlight':''}" data-sop="${escapeHTML(w.id)}" tabindex="0" role="button" aria-label="打开流程设计器：${escapeHTML(w.name)}">${sopRunCardBody(w,m,liveCount)}<div class="sop-card-foot"><span class="sop-card-meta" title="${escapeHTML(meta)}">${escapeHTML(meta)}</span>${sopCardPrimary('data-open-sop',w.id,'打开')}${sopCardMoreButton(w)}</div></article>`;
}
function genericSOPCard(w){
  const nodes=w.nodes||[],agentCount=nodes.filter(n=>n.type==='agent').length,gates=nodes.filter(n=>n.type==='approval').length;
  const tags=(w.tags||[]).filter(t=>!t.startsWith('generic-source:')).join(' · ')||'平台模板';
  const edit=isPlatformAdmin()?sopCardPrimary('data-edit-generic',w.id,'编辑模板','edit'):'';
  return `<article class="sop-card generic${state.highlightSOPId===w.id?' is-highlight':''}" data-generic-id="${escapeHTML(w.id)}" tabindex="0" role="button" aria-label="打开流程设计器：${escapeHTML(w.name)}">${sopCardHead(sopStatusBadge(w),'平台维护 · 复制到项目后可用',sopBadge(`v${w.version||1}`,'neutral',''))}${sopCardTitle(w)}<p>${escapeHTML(w.description||'平台提供的通用流程模板')}</p>${sopRunRequirementChips(w)}${genericRequirementChips(w)}<div class="sop-kpis"><span><b>${nodes.length}</b>节点</span><span><b>${agentCount}</b>角色节点</span><span><b>${gates}</b>人工门禁</span><span><b>v${w.version||1}</b>版本</span></div><div class="sop-card-foot"><span class="sop-card-meta" title="${escapeHTML(`${w.owner||'平台'} · ${tags}`)}"><span class="sop-card-tag">${escapeHTML(w.owner||'平台')}</span>${escapeHTML(tags)}</span>${edit}</div></article>`;
}
function sopCatalogCard(w,metrics,live){
  if(catalogGeneric(w))return genericSOPCard(w);
  const m=metrics.get(w.id)||{},liveCount=live.filter(r=>r.workflowId===w.id).length;
  return projectSOPCard(w,m,liveCount);
}
// --- 流程模板卡片 · ⋯ 菜单 -----------------------------------------------------
const SOP_MENU_ACTIONS={
  delete:{hook:'data-delete-workflow',run:id=>deleteWorkflow(id)},
  promote:{hook:'data-promote-workflow',run:id=>promoteWorkflowToPlatform(id)}
};
function sopCardMenuItems(w){
  if(!w)return [];
  // 平台 SOP 只有「编辑模板」一个动作，直接放在卡片底部，不再套「⋯」浮层。
  if(catalogGeneric(w))return [];
  if(!catalogOwned(w.projectId))return [];
  const items=isPlatformAdmin()?[{action:'promote',label:'提升为平台模板',icon:'arrow-up'},'-']:[];
  items.push({action:'delete',label:'删除',icon:'trash',danger:true});
  return items;
}
function sopCardMenuHTML(w){
  return sopCardMenuItems(w).map(item=>item==='-'?'<span class="sop-popover-sep" role="separator"></span>':`<button type="button" role="menuitem" tabindex="-1" class="issue-popover-item${item.danger?' danger':''}" data-sop-action="${item.action}" ${SOP_MENU_ACTIONS[item.action].hook}="${escapeHTML(w.id)}">${huiIcon(item.icon,'popover-icon')}${escapeHTML(item.label)}</button>`).join('');
}
let sopMenuPopover=null,sopMenuTrigger=null;
function ensureSOPMenuPopover(){
  if(sopMenuPopover)return sopMenuPopover;
  const menu=document.createElement('div');
  menu.id='sopActionPopover';
  menu.className='issue-action-popover sop-action-popover';
  menu.setAttribute('role','menu');
  menu.setAttribute('aria-label','SOP 更多操作');
  menu.hidden=true;
  document.body.appendChild(menu);
  menu.addEventListener('click',e=>{
    const item=e.target.closest('[data-sop-action]');if(!item)return;
    e.stopPropagation();
    const action=SOP_MENU_ACTIONS[item.dataset.sopAction],id=item.getAttribute(action?.hook||'');
    hideSOPCardMenu(true);
    if(action&&id)action.run(id);
  });
  menu.addEventListener('keydown',e=>{
    const items=[...menu.querySelectorAll('[role="menuitem"]')],i=items.indexOf(document.activeElement);
    if(e.key==='ArrowDown'||e.key==='ArrowUp'){
      e.preventDefault();
      const n=items.length,down=e.key==='ArrowDown';if(!n)return;
      items[i<0?(down?0:n-1):(i+(down?1:n-1))%n].focus();
    }
    else if(e.key==='Home'||e.key==='End'){e.preventDefault();items[e.key==='Home'?0:items.length-1]?.focus()}
    else if(e.key==='Escape'||e.key==='Tab'){e.preventDefault();e.stopPropagation();hideSOPCardMenu(true)}
  });
  document.addEventListener('click',e=>{
    if(menu.hidden||menu.contains(e.target)||e.target.closest?.('[data-sop-menu]'))return;
    hideSOPCardMenu();
  });
  document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!menu.hidden)hideSOPCardMenu(true)});
  window.addEventListener('resize',()=>hideSOPCardMenu(),{passive:true});
  window.addEventListener('scroll',e=>{if(!menu.contains(e.target))hideSOPCardMenu()},{passive:true,capture:true});
  sopMenuPopover=menu;
  return menu;
}
function hideSOPCardMenu(restoreFocus=false){
  if(!sopMenuPopover||sopMenuPopover.hidden)return;
  const trigger=sopMenuTrigger;
  sopMenuPopover.hidden=true;
  sopMenuPopover.innerHTML='';
  sopMenuTrigger=null;
  trigger?.setAttribute('aria-expanded','false');
  if(restoreFocus&&trigger?.isConnected)trigger.focus({preventScroll:true});
}
function positionSOPCardMenu(){
  const menu=sopMenuPopover,trigger=sopMenuTrigger;if(!menu||!trigger)return;
  const r=trigger.getBoundingClientRect(),w=menu.offsetWidth||188,h=menu.offsetHeight||88;
  const left=Math.max(8,Math.min(r.right-w,window.innerWidth-w-8));
  let top=r.bottom+6;
  if(top+h>window.innerHeight-8)top=Math.max(8,r.top-h-6);
  menu.style.left=`${Math.round(left)}px`;
  menu.style.top=`${Math.round(top)}px`;
}
function showSOPCardMenu(trigger){
  const menu=ensureSOPMenuPopover();
  if(!menu.hidden&&sopMenuTrigger===trigger)return hideSOPCardMenu(true);
  hideSOPCardMenu();
  if(typeof hideIssueActionMenu==='function')hideIssueActionMenu();
  const w=(state.data?.workflows||[]).find(x=>x.id===trigger.dataset.sopMenu);
  const html=w?sopCardMenuHTML(w):'';
  if(!html)return;
  menu.innerHTML=html;
  window.AgentFlowHarnessIcons?.hydrate?.(menu);
  menu.hidden=false;
  sopMenuTrigger=trigger;
  trigger.setAttribute('aria-expanded','true');
  positionSOPCardMenu();
  menu.querySelector('[role="menuitem"]')?.focus({preventScroll:true});
}
// A metrics refresh replaces the card markup; keep an open menu attached to the new ⋯.
function syncSOPCardMenu(root){
  if(!sopMenuPopover||sopMenuPopover.hidden||sopMenuTrigger?.isConnected)return;
  const id=sopMenuTrigger?.dataset.sopMenu;
  const next=[...root.querySelectorAll('.sop-card:not(.is-leaving) [data-sop-menu]')].find(b=>b.dataset.sopMenu===id);
  if(!next)return hideSOPCardMenu();
  sopMenuTrigger=next;
  next.setAttribute('aria-expanded','true');
  positionSOPCardMenu();
}
// --- 流程模板卡片 · 动效 -------------------------------------------------------
// Cards enter once per reveal context (view activation + scope + filter + sort);
// content refreshes inside the same context only move cards whose slot changed.
const sopCatalogMotion=(()=>{
  const seen=new Set(),entering=new Map();
  const reduced=typeof window!=='undefined'&&typeof window.matchMedia==='function'?window.matchMedia('(prefers-reduced-motion: reduce)'):{matches:false};
  const now=()=>typeof performance!=='undefined'?performance.now():Date.now();
  const enterMs=550,stepMs=30,maxIndex=10;
  let activation=0,played=-1,context=null;
  const keyOf=el=>el.dataset.sop?`sop:${el.dataset.sop}`:el.dataset.genericId?`generic:${el.dataset.genericId}`:'';
  const liveCards=root=>[...root.querySelectorAll('.sop-card:not(.is-leaving)')];
  const visible=root=>root.getClientRects().length>0;
  function snapshot(root){
    const cards=new Map();
    if(!visible(root))return {cards,visible:false};
    liveCards(root).forEach(el=>{const key=keyOf(el);if(key)cards.set(key,{el,rect:el.getBoundingClientRect()})});
    return {cards,host:root.getBoundingClientRect(),visible:true};
  }
  function enter(el,key,index,elapsed=0){
    el.style.setProperty('--card-index',String(index));
    if(elapsed)el.style.animationDelay=`${Math.min(index,maxIndex)*stepMs-elapsed}ms`;
    el.classList.add('is-entering');
    el.addEventListener('animationend',function done(e){if(e.target!==el)return;el.classList.remove('is-entering');el.style.animationDelay='';entering.delete(key);el.removeEventListener('animationend',done)});
  }
  function flip(el,dx,dy){
    el.style.transition='none';
    el.style.transform=`translate(${dx}px, ${dy}px)`;
    requestAnimationFrame(()=>requestAnimationFrame(()=>{
      if(!el.isConnected)return;
      el.style.transition='transform .58s var(--hui-ease-flow), box-shadow .4s var(--hui-ease-flow), border-color .3s var(--hui-ease-flow)';
      el.style.transform='';
      setTimeout(()=>{if(!el.style.transform)el.style.transition=''},640);
    }));
  }
  function leave(root,before,keep){
    before.cards.forEach((prev,key)=>{
      if(keep.has(key))return;
      const ghost=prev.el;
      ghost.classList.remove('is-entering');
      ghost.classList.add('is-leaving');
      ghost.setAttribute('aria-hidden','true');
      ghost.setAttribute('inert','');
      ghost.removeAttribute('tabindex');
      Object.assign(ghost.style,{left:`${prev.rect.left-before.host.left}px`,top:`${prev.rect.top-before.host.top}px`,width:`${prev.rect.width}px`,height:`${prev.rect.height}px`,transform:'',transition:'',animationDelay:''});
      root.appendChild(ghost);
      const remove=()=>ghost.remove();
      ghost.addEventListener('animationend',remove,{once:true});
      setTimeout(remove,260);
    });
  }
  function play(root,before,revealKey){
    const ctx=`${activation}|${revealKey}`,replay=ctx!==context;
    context=ctx;
    if(replay){seen.clear();entering.clear()}
    // Cards left over from before the view was re-entered are not on screen to move from.
    if(played!==activation)before={cards:new Map(),visible:false};
    played=activation;
    const cards=liveCards(root);
    if(reduced.matches||!visible(root)){
      if(visible(root))cards.forEach(el=>seen.add(keyOf(el)));
      return;
    }
    const t=now(),keep=new Set(cards.map(keyOf));
    let index=0;
    cards.forEach(el=>{
      const key=keyOf(el),prev=before.visible?before.cards.get(key):null,running=entering.get(key);
      if(prev&&running&&t-running.start<enterMs+Math.min(running.index,maxIndex)*stepMs){
        enter(el,key,running.index,t-running.start);
      }else if(prev){
        entering.delete(key);
        const r=el.getBoundingClientRect(),dx=prev.rect.left-r.left,dy=prev.rect.top-r.top;
        if(Math.abs(dx)>.5||Math.abs(dy)>.5)flip(el,dx,dy);
      }else if(!seen.has(key)){
        entering.set(key,{start:t,index});
        enter(el,key,index++);
      }
      seen.add(key);
    });
    if(before.visible)leave(root,before,keep);
  }
  // 手动刷新：数据未变时卡片本不会动，这里强制重播入场，让「刷新」有可见变化。
  function replay(root){
    if(reduced.matches||!visible(root))return;
    const t=now();
    let index=0;
    liveCards(root).forEach(el=>{const key=keyOf(el);if(!key)return;entering.set(key,{start:t,index});enter(el,key,index++)});
  }
  return {snapshot,play,replay,reset(){activation++;seen.clear();entering.clear()},get reduced(){return reduced.matches}};
})();
function sopCatalogFocus(root){
  const el=document.activeElement;
  if(!el||!root.contains(el))return null;
  const card=el.closest('.sop-card');if(!card)return null;
  const part=el===card?'':el.matches('[data-sop-menu]')?'[data-sop-menu]':el.matches('.sop-card-primary')?'.sop-card-primary':'';
  return {sop:card.dataset.sop||'',generic:card.dataset.genericId||'',part};
}
function restoreSOPCatalogFocus(root,focus){
  if(!focus)return;
  const card=liveSOPCards(root).find(c=>(focus.sop&&c.dataset.sop===focus.sop)||(focus.generic&&c.dataset.genericId===focus.generic));
  (card&&focus.part?card.querySelector(focus.part):card)?.focus({preventScroll:true});
}
function liveSOPCards(root){return [...root.querySelectorAll('.sop-card:not(.is-leaving)')]}
function openSOPDesigner(id,missing='SOP 不存在或已删除'){
  const wf=(state.data.workflows||[]).find(x=>x.id===id);
  if(!wf)return toast(missing);
  // 设计器在平台侧，离开项目面板前把内嵌的 SOP 视图归还，避免它留在项目容器里。
  if(state.sopHosted&&typeof unmountProjectAssetSurface==='function'){state.paSurface='assets';unmountProjectAssetSurface()}
  state.workflow=clone(wf);state.selectedNode=null;renderWorkflowMeta();renderCanvas();renderProperties();switchView('flow');
}
function activateSOPCard(card){
  if(card.dataset.genericId)openGenericTemplateEditor(card.dataset.genericId);
  else if(card.dataset.sop)openSOPDesigner(card.dataset.sop);
}
function bindSOPCatalogEvents(root){
  if(root.dataset.sopEvents)return;
  root.dataset.sopEvents='1';
  root.addEventListener('click',e=>{
    const card=e.target.closest('.sop-card');
    if(!card||card.classList.contains('is-leaving'))return;
    const btn=e.target.closest('button');
    if(btn){
      e.stopPropagation();
      if(btn.dataset.sopMenu)return showSOPCardMenu(btn);
      hideSOPCardMenu();
      if(btn.dataset.openSop)openSOPDesigner(btn.dataset.openSop,'项目副本不存在或已删除');
      if(btn.dataset.editGeneric)openGenericTemplateEditor(btn.dataset.editGeneric);
      return;
    }
    hideSOPCardMenu();
    activateSOPCard(card);
  });
  root.addEventListener('keydown',e=>{
    if((e.key!=='Enter'&&e.key!==' ')||!e.target.matches?.('.sop-card:not(.is-leaving)'))return;
    e.preventDefault();
    hideSOPCardMenu();
    activateSOPCard(e.target);
  });
}
async function openGenericTemplateEditor(id){
  const w=(state.data?.workflows||[]).find(x=>x.id===id&&catalogGeneric(x));
  if(!w)return toast('通用模板不存在或已下架');
  if(!isPlatformAdmin())return toast('只有平台管理员可以编辑通用模板');
  state.workflow=clone(w);state.selectedNode=null;markWorkflowClean();
  clearGenericTemplateAgents();
  renderWorkflowMeta();renderCanvas();renderProperties();switchView('flow');
  await refreshGenericWorkflowRoles();
}
function platformSandboxChoices(){return (state.data?.sandboxes||[]).filter(s=>s.id&&(!s.projectId||s.shared))}
// 流程模板页（平台视角）新建平台 SOP：只有平台管理员可见，创建后直接进入设计器。
async function newPlatformSOP(){
  if(!isPlatformAdmin())return toast('只有平台管理员可以维护平台 SOP');
  const sandbox=platformSandboxChoices()[0];
  if(!sandbox)return toast('平台还没有共享沙箱，请先在「高级设置 › 沙箱」里创建一个共享沙箱');
  const name=await afPrompt({title:'新建平台 SOP',message:'平台 SOP 会出现在「流程模板」里，各项目复制后使用。',defaultValue:''});
  if(!name)return;
  const workflow={id:uid('generic-sop'),name,generic:true,projectId:'',shared:false,owner:'平台',tags:[],description:'',status:'draft',version:1,revision:0,sandboxProfileId:sandbox.id,nodes:[],edges:[]};
  try{
    const saved=await api('/api/workflows',{method:'PUT',body:JSON.stringify(workflow)});
    state.data.workflows.push(saved);
    state.workflow=clone(saved);state.selectedNode=null;state.sopScope='generic';markWorkflowClean();
    renderAll();switchView('flow');toast('平台 SOP 已创建，请继续设计节点','ok');
  }catch(e){toast(e.message||'创建平台 SOP 失败')}
}
// 项目 SOP 提升为平台模板：复制进平台目录，项目原件保留。
async function promoteWorkflowToPlatform(id){
  const src=(state.data?.workflows||[]).find(w=>w.id===id);
  if(!src)return toast('SOP 不存在或已删除');
  if(!isPlatformAdmin())return toast('只有平台管理员可以提升为平台模板');
  const name=await afPrompt({title:'提升为平台模板',message:'会复制为新的平台 SOP，项目内原 SOP 保持不变。',defaultValue:src.name});
  if(!name)return;
  try{
    const created=await api(`/api/workflows/${encodeURIComponent(id)}/promote`,{method:'POST',body:JSON.stringify({id:uid('generic-sop'),name,owner:'平台'})});
    state.data.workflows.push(created);
    renderSOPCatalog();toast('已提升为平台模板，可在「流程模板」里查看','ok');
  }catch(e){toast(e.message||'提升为平台模板失败')}
}
function renderSOPCatalog(){
  renderCatalogScopes();
  // 平台 SOP 是全局配置：这一屏不出现按项目统计的运行 / Token 指标，顶栏项目切换也一并收起。
  const generic=state.sopScope==='generic';
  document.body.classList.toggle('sop-platform-scope',generic);
  // 平台 SOP 与项目 SOP 共用同一个主按钮：按当前视角切换文案与行为，避免出现第二个新建入口。
  const newBtn=$('#newSOP');if(newBtn){newBtn.hidden=generic&&!isPlatformAdmin();newBtn.textContent=generic?'＋ 新建平台 SOP':'＋ 新建 SOP';}
  let workflows=scopedWorkflows();
  const metrics=new Map((state.data.workflowMetrics||[]).map(m=>[m.workflowId,m]));
  const live=liveRuns();
  const all=[...metrics.values()],totalRuns=all.reduce((n,m)=>n+m.totalRuns,0),succeeded=all.reduce((n,m)=>n+m.succeededRuns,0),failed=all.reduce((n,m)=>n+m.failedRuns,0),active=live.length,tokens=all.reduce((n,m)=>n+m.totalTokens,0);
  const overview=$('#sopOverview');
  if(overview){
    overview.hidden=generic;
    overview.innerHTML=generic?'':`<div class="overview-metric primary"><span>本项目运行</span><b>${totalRuns}</b><small>${workflows.length} 条项目 SOP</small></div><div class="overview-metric success"><span>已闭环</span><b>${succeeded}</b><small>${totalRuns?percent(succeeded*100/totalRuns):'暂无运行'}</small></div><div class="overview-metric live"><span>进行中 / 待审批</span><b>${active}</b><small>实时更新 · 不含中断残留</small></div><div class="overview-metric danger${failed>0?' is-bad':''}"><span>失败运行</span><b>${failed}</b><small>${totalRuns?percent(failed*100/totalRuns):'0%'}</small></div><div class="overview-metric"><span>Token 消耗</span><b>${formatTokens(tokens)}</b><small>当前项目累计</small></div>`;
  }
  // 健康状态与排序都建立在运行数据上，平台视角没有这些数据，一并隐藏。
  const filters=$('#sopsView .sop-toolbar-filters');if(filters)filters.hidden=generic;
  const filter=generic?'all':($('#sopHealthFilter')?.value||'all'),sort=generic?'name':($('#sopSort')?.value||'recent');
  if(filter!=='all')workflows=workflows.filter(w=>metricHealth(metrics.get(w.id), live.filter(r=>r.workflowId===w.id).length).key===filter);
  if(generic)workflows.sort((a,b)=>String(a.name||'').localeCompare(String(b.name||''),'zh-Hans-CN'));
  else workflows.sort((a,b)=>{const x=metrics.get(a.id)||{},y=metrics.get(b.id)||{};if(sort==='runs')return (y.totalRuns||0)-(x.totalRuns||0);if(sort==='closure')return (y.closureRate||0)-(x.closureRate||0);if(sort==='failures')return (y.failedRuns||0)-(x.failedRuns||0);return new Date(y.lastRunAt||0)-new Date(x.lastRunAt||0)});
  $('#sopStats').innerHTML=`<span class="issue-stat">${workflows.length} SOPs</span><span class="issue-stat">${workflows.filter(w=>w.status==='published').length} 已发布</span><span class="issue-stat">${new Set(workflows.map(w=>w.owner).filter(Boolean)).size} 负责人</span>`;
  const empty=state.sopScope==='generic'?'平台还没有 SOP 模板。管理员可点右上角「＋ 新建平台 SOP」。':'当前项目还没有 SOP。可以新建，或在项目配置里从平台 SOP 复制一份。';
  const emptyText=filter!=='all'&&scopedWorkflows().length?'当前筛选下没有 SOP。可以切换健康状态查看全部。':empty;
  const sopCatalog=$('#sopCatalog');
  bindSOPCatalogEvents(sopCatalog);
  const before=sopCatalogMotion.snapshot(sopCatalog),focus=sopCatalogFocus(sopCatalog);
  sopCatalog.innerHTML=workflows.map(w=>sopCatalogCard(w,metrics,live)).join('')||`<div class="empty-properties sop-empty">${huiIcon('workflow-empty')}<b>${emptyText}</b></div>`;
  window.AgentFlowHarnessIcons?.hydrate?.(sopCatalog);
  sopCatalogMotion.play(sopCatalog,before,[state.projectFilter,state.sopScope,filter,sort].join('|'));
  restoreSOPCatalogFocus(sopCatalog,focus);
  syncSOPCardMenu(sopCatalog);
}
// 刷新按钮的可见反馈：按下去立刻转起来，数据没变也重播卡片入场，结束后给一条汇总。
function setSOPRefreshBusy(busy){
  const btn=$('#refreshSOPs');if(!btn)return;
  btn.disabled=busy;
  btn.classList.toggle('is-loading',busy);
  btn.setAttribute('aria-busy',busy?'true':'false');
  btn.innerHTML=`<span class="sop-refresh-glyph" aria-hidden="true">↻</span>${busy?'刷新中…':'刷新'}`;
}
// feedback 仅由用户点击传入；页面切换时的自动拉取保持静默，不碰按钮状态。
async function refreshWorkflowMetrics(feedback=false){
  const loud=feedback===true;
  const btn=loud?$('#refreshSOPs'):null;
  if(btn&&btn.disabled)return;          // 进行中连点不叠加请求
  const started=Date.now(),minMs=520;   // 接口再快也转这么久，避免闪一下就复原
  if(loud)setSOPRefreshBusy(true);
  try{
    const opt={silent:true};
    const [metrics,runs]=await Promise.all([api('/api/workflow-metrics'+projectQuery(),opt),api('/api/runs',opt)]);
    state.data.workflowMetrics=metrics;state.data.runs=runs;
    updateApprovalBadge();renderSOPCatalog();
    if(loud){
      sopCatalogMotion.replay($('#sopCatalog'));
      await new Promise(r=>setTimeout(r,Math.max(0,minMs-(Date.now()-started))));
      // 平台视角没有项目运行数据，汇总里只报 SOP 数量。
      const generic=state.sopScope==='generic';
      const summary=generic?`已刷新 · ${scopedWorkflows().length} 个平台 SOP`:`已刷新 · ${scopedWorkflows().length} 个项目 SOP · ${(runs||[]).length} 次运行`;
      toast(summary,'ok',1800);
    }
  }catch(e){
    if(loud)toast(e.message||'刷新失败','err');
    else toast(e.message);
  }finally{
    if(loud)setSOPRefreshBusy(false);
  }
}

