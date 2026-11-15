(function(root){'use strict';
function create({el,document:doc=root.document,matchMedia=query=>root.matchMedia?.(query),setTimer=setTimeout,clearTimer=clearTimeout}){
 let started=false,finished=false,dialog,timer;const waiting=new Set(),motion=matchMedia('(prefers-reduced-motion: reduce)');
 function finish(){
  if(finished)return;finished=true;if(timer!==undefined){clearTimer(timer);timer=undefined;}
  motion?.removeEventListener?.('change',motionChanged);root.removeEventListener?.('pagehide',shutdown);
  if(dialog){if(dialog.open)dialog.close();dialog.remove();dialog=undefined;}
  const callbacks=[...waiting];waiting.clear();for(const callback of callbacks)callback();
 }
 function shutdown(){waiting.clear();finish();}
 function motionChanged(event){if(event.matches)finish();}
 function start(){
  if(started)return;started=true;if(motion?.matches){finish();return;}
  dialog=el('dialog','playmelt-intro');dialog.setAttribute('aria-label','Ouverture de Playmelt');
  const stage=el('div','intro-stage'),lockup=el('div','intro-lockup'),emblem=el('div','intro-emblem'),letter=el('div','intro-p');
  const image=(src,cls)=>{const node=el('img',cls);node.src=src;node.alt='';node.draggable=false;node.decoding='sync';return node;};
  letter.append(el('span','intro-ring'),image('PlaymeltMarkInk.png','intro-ink'),image('PlaymeltMarkOrange.png','intro-orange intro-orange-main'),el('span','intro-sheen'),el('span','intro-spark'));
  emblem.append(letter);
  const word=el('div','intro-word');word.append(image('PlaymeltWordmark.png','intro-wordmark'));
  lockup.append(emblem,word);stage.append(el('div','intro-glow'),lockup);dialog.append(stage);doc.body.append(dialog);
  dialog.addEventListener('cancel',event=>{event.preventDefault();finish();});
  dialog.addEventListener('click',finish);
  dialog.addEventListener('animationend',event=>{if(event.target===dialog&&event.animationName==='playmeltIntroExit')finish();});
  motion?.addEventListener?.('change',motionChanged);root.addEventListener?.('pagehide',shutdown,{once:true});
  timer=setTimer(finish,1250);dialog.showModal();
 }
 return {start,finish,after(callback){if(finished)callback();else waiting.add(callback);},get finished(){return finished;}};
}
root.PlaymeltAppIntro={create};if(typeof module!=='undefined')module.exports={create};
})(typeof window!=='undefined'?window:globalThis);
