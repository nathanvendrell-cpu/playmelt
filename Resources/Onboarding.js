(function(root){'use strict';
root.PlaymeltOnboarding={create(api){let dialog=null,step=0,offered=false;
function close(){dialog?.close();}
function show(){if(dialog)return;step=0;dialog=api.el('dialog','player-editor onboarding');dialog.setAttribute('aria-label','Configurer Playmelt');dialog.addEventListener('close',()=>{dialog.remove();dialog=null;});document.body.append(dialog);draw();dialog.showModal();}
function draw(){dialog.replaceChildren();const el=api.el,heading=el('div','player-editor-head'),skip=el('button','player-close','Plus tard');skip.type='button';skip.onclick=()=>{api.send('completeSetup');close();};heading.append(el('span','discover-kicker',`BIENVENUE · ${step+1} / 2`),skip);dialog.append(heading);
const titles=['Ton pseudo','Retrouve tes jeux'];dialog.append(el('h2','',titles[step]));
const form=el('form'),next=el('button','button primary',step===1?'Commencer':'Continuer');next.type='submit';
if(step===0){const input=el('input');input.name='nickname';input.placeholder='Ton pseudo';input.value=api.getState().player?.name||'';input.required=true;input.maxLength=40;input.setAttribute('aria-label','Ton pseudo');form.append(input);form.onsubmit=e=>{e.preventDefault();const name=input.value.trim();if(!name)return;api.send('savePlayerProfile',{name});step++;draw();};}
if(step===1){if(api.getState().account?.configured&&api.getState().account?.serviceReady){const account=el('button','settings-row-action','Connecter mon compte Playmelt');account.type='button';account.onclick=()=>{close();api.send('connectPlaymelt');};dialog.append(account);}dialog.append(el('p','settings-description','Connecte tes comptes maintenant, ou plus tard dans Paramètres.'));for(const [name,action]of [['Steam','syncLibrary'],['Epic Games','connectEpic'],['Xbox Game Pass','openXbox'],['GOG','openGOG']]){const row=el('div','settings-game-row'),b=el('button','settings-row-action','Connecter');b.type='button';b.onclick=()=>api.send(action);row.append(el('strong','',name),b);dialog.append(row);}form.onsubmit=e=>{e.preventDefault();api.send('completeSetup');close();};}
form.append(next);dialog.append(form);}
return {show,suggest(){const account=api.getState().account;if(account?.passwordLoginReady&&!account.signedIn)return;if(!offered&&api.getState().setupSuggested){offered=true;show();}}};}};
})(window);
