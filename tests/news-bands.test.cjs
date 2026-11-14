'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),path=require('node:path');
function element(tag,cls='',text=''){return {tag,className:cls,textContent:text,children:[],handlers:{},classList:{add(){}},append(...nodes){this.children.push(...nodes)},replaceChildren(...nodes){this.children=nodes},addEventListener(name,fn){this.handlers[name]=fn}};}
function fixture(items,games=[]){
 const window={matchMedia:()=>({matches:true}),PlaymeltArtwork:{bind(node,urls){node.candidates=urls.filter(Boolean);return node}}};
 vm.runInNewContext(fs.readFileSync(path.join(__dirname,'../Resources/Discover.js'),'utf8'),{window,Date,Intl});const opened=[];
 const api=window.PlaymeltDiscover.create({el:element,getState:()=>({games}),getFeed:()=>({items}),openLink:url=>opened.push(url),artFor:game=>{assert(game);return {}},rank:()=>({})});return {api,opened};
}
test('a story without a matching library game still renders and opens its source',()=>{
 const story={gameId:'missing',gameTitle:'Jeu',title:'Correctif',kind:'update',date:1,url:'https://example.test/patch'},f=fixture([story]);
 const card=f.api.newsCard(story);assert.match(card.className,/game-news-band/);assert.equal(card.children[0].candidates.length,0);
 card.handlers.click();assert.equal(f.opened[0],story.url);
});
test('dossier variant shares the story component and artwork fallback',()=>{
 const story={gameId:'1',gameTitle:'Jeu',title:'Annonce',kind:'news',date:1,url:'https://example.test/news'},f=fixture([story],[{id:'1',title:'Jeu',imageURL:'https://example.test/art.jpg'}]);
 const card=f.api.newsCard(story,false,{context:true});assert.match(card.className,/news-band-context/);assert.equal(card.children[1].candidates[0],'https://example.test/art.jpg');
});
test('news only creates the first eighteen image bands until explicitly expanded',()=>{
 const items=Array.from({length:60},(_,i)=>({gameId:'missing',title:'Article '+i,kind:'news',date:1,url:'https://example.test/'+i})),f=fixture(items),pane=element('div');
 f.api.renderNews(pane);assert.equal(pane.children[0].children.length,18);
 pane.children[1].handlers.click();assert.equal(pane.children[0].children.length,36);
});
