(function(root){'use strict';
function create({el,getState,send,document:doc=root.document,clock=()=>Date.now(),setTimer=setTimeout,clearTimer=clearTimeout,onSignedIn=()=>{},afterIntro=callback=>callback()}){
 let dialog,form,email,password,submit,status,closeButton,reveal,notice,google,googleLabel,emailToggle,forgot,googleStarted=false,emailExpanded=false,opening=false,autoOpened=false,wasSignedIn=false,timer;
 const current=()=>getState().account||{};
 const passwordReady=a=>a.configured===true&&a.serviceReady===true&&a.passwordLoginReady===true;
 const googleReady=a=>a.configured===true&&a.serviceReady===true&&a.googleLoginReady===true;
 const ready=a=>passwordReady(a)||googleReady(a);
 const mandatory=a=>a.enabled===true&&!a.signedIn;
 function erase(){if(password){password.value='';password.type='password';}if(reveal){reveal.textContent='Afficher';reveal.setAttribute('aria-pressed','false');reveal.setAttribute('aria-label','Afficher le mot de passe');}}
 function stopTimer(){if(timer!==undefined){clearTimer(timer);timer=undefined;}}
 function paint(a=current()){
  if(!dialog)return;stopTimer();
  const waiting=Math.max(0,Number(a.loginRetryAt||0)*1000-clock()),busy=a.pending===true||a.checkingAccess===true;
  submit.disabled=!passwordReady(a)||busy||waiting>0;email.disabled=busy||!passwordReady(a);password.disabled=email.disabled;reveal.disabled=email.disabled;
  google.hidden=!googleReady(a);google.disabled=busy||waiting>0;google.setAttribute('aria-busy',String(busy&&googleStarted));googleLabel.textContent=busy&&googleStarted?'Connexion à Google…':'Continuer avec Google';
  form.hidden=googleReady(a)&&!emailExpanded&&!email.value&&!password.value;emailToggle.hidden=!googleReady(a);emailToggle.disabled=busy;emailToggle.setAttribute('aria-expanded',String(!form.hidden));emailToggle.textContent=form.hidden?'Continuer avec mon e-mail':'Masquer la connexion par e-mail';forgot.hidden=form.hidden;
  submit.textContent=busy?'Connexion…':'Se connecter';
  closeButton.hidden=mandatory(a);
  status.textContent=String(a.message||(!ready(a)?'La connexion par mot de passe est en préparation.':''));
  status.classList.toggle('error',!busy&&!!a.message&&!a.signedIn&&!String(a.message).includes('annulée'));
  notice.hidden=!mandatory(a);
  if(dialog.open&&waiting>0)timer=setTimer(()=>{timer=undefined;paint();},Math.min(waiting+50,901000));
 }
 function ensure(){
  if(dialog)return;
  dialog=el('dialog','playmelt-login');dialog.setAttribute('aria-labelledby','playmeltLoginTitle');
  const shell=el('div','login-shell'),visual=el('aside','login-visual'),mark=el('img','login-mark');mark.src='PlaymeltMark.png';mark.alt='';
  visual.append(mark,el('strong','login-wordmark','playmelt'));
  const main=el('section','login-main');closeButton=el('button','login-close','×');closeButton.type='button';closeButton.setAttribute('aria-label','Fermer la connexion');closeButton.addEventListener('click',()=>dialog.close());
  const title=el('h2','','Connexion');title.id='playmeltLoginTitle';notice=el('p','login-notice','Connecte ton compte Playmelt pour continuer.');
  google=el('button','login-google');google.type='button';google.hidden=true;const googleMark=el('img','login-google-mark');googleMark.src='GoogleG.png';googleMark.alt='';googleLabel=el('span','','Continuer avec Google');google.append(googleMark,googleLabel);
  google.addEventListener('click',()=>{const a=current();if(!googleReady(a)||a.signedIn||a.pending||a.checkingAccess||Number(a.loginRetryAt||0)*1000>clock())return;erase();googleStarted=true;send('signInPlaymeltGoogle');paint({...a,pending:true});});
  emailToggle=el('button','login-email-toggle','Continuer avec mon e-mail');emailToggle.type='button';emailToggle.setAttribute('aria-controls','playmeltEmailLogin');emailToggle.addEventListener('click',()=>{emailExpanded=!emailExpanded;paint();if(!form.hidden)email.focus();});
  form=el('form','login-form');form.id='playmeltEmailLogin';
  function field(label,input,target=input){const row=el('div','login-field'),caption=el('label','',label);caption.htmlFor=target.id;row.append(caption,input);return row;}
  email=el('input');email.type='email';email.id='playmeltLoginEmail';email.name='email';email.autocomplete='username';email.required=true;email.maxLength=254;email.placeholder='ton@email.fr';email.spellcheck=false;
  password=el('input');password.type='password';password.id='playmeltLoginPassword';password.name='password';password.autocomplete='current-password';password.required=true;password.maxLength=1024;password.setAttribute('aria-label','Mot de passe Playmelt');
  const passwordRow=el('div','login-password');reveal=el('button','login-reveal','Afficher');reveal.type='button';reveal.setAttribute('aria-pressed','false');reveal.setAttribute('aria-label','Afficher le mot de passe');
  reveal.addEventListener('click',()=>{const showing=password.type==='password';password.type=showing?'text':'password';reveal.textContent=showing?'Masquer':'Afficher';reveal.setAttribute('aria-pressed',String(showing));reveal.setAttribute('aria-label',showing?'Masquer le mot de passe':'Afficher le mot de passe');});passwordRow.append(password,reveal);
  submit=el('button','button primary login-submit','Se connecter');submit.type='submit';status=el('p','login-status');status.setAttribute('role','status');status.setAttribute('aria-live','polite');
  form.append(field('E-mail',email),field('Mot de passe',passwordRow,password),submit);
  form.addEventListener('submit',event=>{
   event.preventDefault();const a=current();if(!passwordReady(a)||a.signedIn||a.pending||a.checkingAccess||Number(a.loginRetryAt||0)*1000>clock())return;
   if(!email.value.trim()||!password.value)return;
   const value=password.value;erase();send('signInPlaymelt',{email:email.value.trim(),password:value});
  });
  const links=el('div','login-links');
  for(const [label,section]of [['Créer mon compte','registration'],['Mot de passe oublié','password']]){const b=el('button','login-link',label);b.type='button';if(section==='password')forgot=b;b.addEventListener('click',()=>send('openPlaymeltAccount',{section}));links.append(b);}
  main.append(closeButton,title,notice,google,emailToggle,status,form,links);shell.append(visual,main);dialog.append(shell);doc.body.append(dialog);
  dialog.addEventListener('cancel',event=>{if(mandatory(current()))event.preventDefault();});
  dialog.addEventListener('close',()=>{erase();stopTimer();if(googleStarted&&!current().signedIn)send('cancelPlaymeltGoogle');googleStarted=false;});
 }
 function open(){const a=current();if(a.signedIn){send('refreshPlaymelt');return;}ensure();if(opening)return;opening=true;afterIntro(()=>{opening=false;if(current().signedIn)return;if(!dialog.open)dialog.showModal();paint();(googleReady(current())?google:email).focus();});}
 function sync(a=current()){
  if(wasSignedIn&&!a.signedIn)autoOpened=false;wasSignedIn=!!a.signedIn;
  if(a.signedIn){if(dialog?.open){erase();dialog.close();onSignedIn(a);}return;}
  if(ready(a)&&!autoOpened){autoOpened=true;open();}else paint(a);
 }
 root.addEventListener?.('pagehide',()=>{erase();stopTimer();if(googleStarted)send('cancelPlaymeltGoogle');googleStarted=false;});
 return {open,sync,close(){if(dialog?.open&&!mandatory(current()))dialog.close();}};
}
root.PlaymeltAccountLogin={create};if(typeof module!=='undefined')module.exports={create};
})(typeof window!=='undefined'?window:globalThis);
