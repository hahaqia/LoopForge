const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const bundle = fs.readFileSync(process.argv[2], 'utf8');
function source(name) {
  const match = new RegExp('^(?:async )?function ' + name + '\\(', 'm').exec(bundle);
  assert(match, name);
  const tail = bundle.slice(match.index);
  const next = /\n(?:async )?function |\n(?:let|const) [A-Za-z]|\n\/\/ /.exec(tail);
  return next ? tail.slice(0, next.index) : tail;
}
const context = { state: { projectFilter: '', agentUsage: null }, isPlatformAdmin: () => true, catalogOwned: () => false };
vm.createContext(context);
['agentPlatformManaged', 'agentDeleteBlockReason'].forEach(name => vm.runInContext(source(name), context));

// 平台共享角色（projectId 为空）即使 shared=true 也能删：没有「取消共享」这一步。
assert.equal(context.agentDeleteBlockReason({ id: 'a', projectId: '', shared: true }), '');
assert.equal(context.agentDeleteBlockReason({ id: 'a', shared: true }), '');
// 项目角色的共享状态仍然要求先取消共享。
assert.equal(context.agentDeleteBlockReason({ id: 'a', projectId: 'p1', shared: true }), '共享状态的角色不能删除，请先取消共享');
assert.equal(context.agentDeleteBlockReason({ id: 'a', projectId: 'p1', shared: false }), '');
// 仍被流程引用的角色不能删，平台角色也一样。
const usage = new Map([['a', 2]]);
assert.equal(context.agentDeleteBlockReason({ id: 'a', projectId: '', shared: true }, usage), '角色仍被流程引用，请先解除引用');

// 平台页：平台角色由平台管理员维护；项目页（传了 projectId）与普通成员都不可以。
assert.equal(context.agentPlatformManaged({ id: 'a', projectId: '' }), true);
assert.equal(context.agentPlatformManaged({ id: 'a', projectId: 'p1' }), false);
assert.equal(context.agentPlatformManaged({ id: 'a', projectId: '' }, { projectId: 'p1' }), false);
context.isPlatformAdmin = () => false;
assert.equal(context.agentPlatformManaged({ id: 'a', projectId: '' }), false);
