/* One bounded image queue for the library, news and store surfaces. */
(function(root){
  'use strict';
  const pending=[], jobs=new Map(), preferred=new Map(), failed=new Map();let active=0;
  const observer=typeof IntersectionObserver==='function'?new IntersectionObserver(entries=>{for(const e of entries)if(e.isIntersecting){observer.unobserve(e.target);enqueue(jobs.get(e.target));}},{rootMargin:'280px'}):null;
  function remember(map,key,value){map.delete(key);map.set(key,value);if(map.size>512)map.delete(map.keys().next().value);}
  function pump(){while(active<6&&pending.length){const job=pending.shift();if(job.cancelled)continue;job.running=true;active++;next(job);}}
  function enqueue(job){if(!job||job.queued||job.cancelled)return;job.queued=true;pending.push(job);pump();}
  function finish(job){clearTimeout(job.timer);if(job.running){job.running=false;active--;}pump();}
  function next(job){
    clearTimeout(job.timer);if(job.cancelled)return;
    const url=job.sources.shift();if(!url){job.image.classList.add('art-unavailable');finish(job);return;}
    job.current=url;job.image.onload=()=>{if(job.cancelled)return;remember(preferred,job.key,url);failed.delete(url);job.image.classList.add('art-loaded');job.image.classList.remove('art-unavailable');finish(job);job.onLoad?.(url);};
    job.image.onerror=()=>{if(job.cancelled)return;remember(failed,url,Date.now());next(job);};
    job.image.loading='eager';job.image.src=url;
    job.timer=setTimeout(()=>{if(!job.cancelled){remember(failed,url,Date.now());job.image.removeAttribute('src');next(job);}},12000);
  }
  function bind(image,urls,options={}){
    dispose(image);const sources=[...new Set((Array.isArray(urls)?urls:[urls]).filter(x=>typeof x==='string'&&/^(https:\/\/|metalmaxart:\/\/)/.test(x)))];
    const key=sources.join('|'),best=preferred.get(key);if(best&&sources.includes(best))sources.splice(sources.indexOf(best),1),sources.unshift(best);
    const available=sources.filter(x=>!failed.has(x)||Date.now()-failed.get(x)>60000);
    image.classList.add('pm-artwork');image.classList.remove('art-loaded','art-unavailable');image.decoding='async';image.referrerPolicy='no-referrer';
    const job={image,sources:available,key,onLoad:options.onLoad};jobs.set(image,job);
    image.disposeArtwork=()=>dispose(image);
    if(options.eager||!observer)enqueue(job);else observer.observe(image);return image;
  }
  function dispose(image){const job=jobs.get(image);if(!job)return;job.cancelled=true;observer?.unobserve(image);image.onload=null;image.onerror=null;clearTimeout(job.timer);image.removeAttribute('src');jobs.delete(image);finish(job);}
  if(typeof MutationObserver==='function'&&root.document)new MutationObserver(records=>{for(const record of records)for(const node of record.removedNodes){if(node.nodeType!==1||node.isConnected)continue;if(jobs.has(node))dispose(node);for(const img of node.querySelectorAll?.('img.pm-artwork')||[])if(!img.isConnected)dispose(img);}}).observe(root.document.documentElement,{childList:true,subtree:true});
  root.addEventListener?.('pagehide',()=>{for(const image of jobs.keys())dispose(image);observer?.disconnect();});
  const api={bind,dispose,stats:()=>({active,pending:pending.filter(x=>!x.cancelled).length,tracked:jobs.size})};
  if(typeof module!=='undefined'&&module.exports)module.exports=api;else root.PlaymeltArtwork=api;
})(typeof window==='undefined'?globalThis:window);
