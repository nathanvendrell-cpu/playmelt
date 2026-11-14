const {test}=require('node:test');const assert=require('node:assert/strict');const {offers}=require('../Resources/Discover.js');
test('offers exclude expired giveaways, upcoming games and duplicate promotions',()=>{
 const feed={freeGames:[{id:'a',title:'Gift',current:true,start:10,end:30},{id:'b',current:true,start:1,end:15},{id:'c',current:false,start:25,end:40}],offers:[{id:'steam:1',kind:'sale',end:40},{id:'steam:1',kind:'sale',end:40},{id:'gog:1',kind:'sale',end:19}]};
 assert.deepEqual(offers(feed,20).map(x=>x.id),['epic:a','steam:1']);assert.equal(offers(feed,20)[0].priceCents,0);
});
