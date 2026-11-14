const { test } = require('node:test');
const assert = require('node:assert/strict');
const { rank, tiers, installed, selection, delta } = require('../Resources/Experience.js');

test('ranks use seconds with exact boundaries, including Factorio', () => {
  for (let i = 1; i < tiers.length; i++) {
    assert.equal(rank(tiers[i][0] * 3600 - 1).index, i - 1);
    assert.equal(rank(tiers[i][0] * 3600).index, i);
  }
  assert.equal(rank(3016260).name, 'Grand maître');
  assert.equal(rank(0).name, 'Nouveau venu');
  assert.equal(rank(-1).index, 0);
  assert.equal(rank(Infinity).index, 0);
  assert.equal(rank(NaN).index, 0);
  assert.equal(rank(3600000).next, null);
  assert.equal(rank(36000000).progress, 1);
});
test('installed collection follows additions, removals and selection without a fixed limit', () => {
  const a = { id:'a', title:'Alpha', installed:true, platform:'windows' };
  const b = { id:'b', title:'Bravo', installed:true, platform:'mac' };
  const c = { id:'c', title:'Charlie', installed:false, platform:'windows' };
  assert.deepEqual(installed([c,b,a,a]).map(g => g.id), ['a','b']);
  assert.equal(selection(installed([a,b,c]), 'b'), 1);
  assert.equal(selection(installed([a,c]), 'b', 1), 0);
  assert.equal(selection([], 'b', 1), -1);
  assert.equal(selection(installed([a,b,{...c,installed:true}]), 'b'), 1);
  assert.equal(installed([{...a,platform:'cloud'}]).length, 0);
  const many = Array.from({length:80}, (_,i) => ({...a,id:String(i),title:'Game '+i}));
  assert.equal(installed(many).length, 80);
});
test('orbit wraps through the nearest neighbour in both directions', () => {
  assert.equal(delta(4, 0, 5), -1);
  assert.equal(delta(0, 4, 5), 1);
  assert.equal(delta(0, 0, 1), 0);
  assert.equal(delta(1, 0, 2), 1);
});
