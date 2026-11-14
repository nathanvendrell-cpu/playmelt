(function(root){'use strict';
function presentation(account={}){
 const ready=account.configured===true&&account.serviceReady===true,signedIn=account.signedIn===true,active=signedIn&&['active','trialing'].includes(account.phase),verified=active&&account.accessVerified===true,lifetime=active&&account.plan==='lifetime',promotional=active&&account.plan==='promotional';
 let label=!ready?'Ouverture prochaine':!signedIn?'Compte à connecter':lifetime?'Accès à vie':promotional?'Accès promotionnel':account.phase==='trialing'?'Essai gratuit':active?'Abonnement actif':'Accès à activer';
 let detail=!ready?'Le compte sera disponible dès l’ouverture du service.':!signedIn?'Connecte ton compte pour retrouver ton accès et tes appareils.':active&&!verified?'Actualise ton accès pour confirmer cette licence sur ce Mac.':lifetime?'Accès lié à ton compte Playmelt.':account.phase==='trialing'?'Ton essai est lié à ton compte Playmelt.':active?'Ton accès est confirmé sur ce Mac.':'Choisis une formule ou active ton code depuis ton compte.';
 const until=Number(account.expiresAt);if(ready&&active&&!lifetime&&Number.isFinite(until)&&until>0&&Number.isFinite(new Date(until*1000).getTime()))detail+=(account.phase==='trialing'?' Essai jusqu’au ':' Jusqu’au ')+new Date(until*1000).toLocaleDateString('fr-FR')+'.';
 return {ready,signedIn,active,verified,lifetime,promotional,label,detail,manageLabel:lifetime||promotional?'Gérer mon compte':'Gérer mon abonnement'};
}
root.PlaymeltAccount={presentation};if(typeof module!=='undefined')module.exports={presentation};
})(typeof window!=='undefined'?window:globalThis);
