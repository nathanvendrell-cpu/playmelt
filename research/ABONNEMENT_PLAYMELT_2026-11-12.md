# Playmelt — abonnement : prêt techniquement, inactif

État au 12/11/2026. Rien n'est encaissé, aucun compte n'est créé, rien n'est publié.

## Offres (validées par Nathan le 12/11/2026)

Prix TTC, dégressifs sur la durée, base 19,99 €/mois.

| Offre | Prix | Équivalent mensuel | Économie |
|---|---|---|---|
| 1 mois | 19,99 € | 19,99 € | — |
| 3 mois | 53,99 € | 18,00 € | −10 % |
| 6 mois | 95,99 € | 16,00 € | −20 % |
| 1 an | 167,99 € | 14,00 € | −30 % |
| À vie | 399,00 € | paiement unique (≈ 2,4 ans d'offre annuelle) | — |

Les prix vivent dans `Entitlement.swift` (`PlaymeltPlan.priceCents`) pour l'affichage.
Le prix réellement facturé est celui configuré chez le fournisseur de paiement : les deux
doivent rester identiques.

## Ce qui est en place dans l'app

- `Entitlement.swift` : offres, activation / vérification / retrait d'une clé de licence,
  stockage dans le trousseau, 7 jours de jeu hors ligne, refus d'une horloge reculée,
  refus d'une clé d'un autre magasin ou produit, expiration.
- Contrôle au lancement de jeu (`route` dans `main.swift`) ; l'installation reste libre.
- Écran « Abonnement Playmelt » (offres, clé, retrait du Mac), affiché seulement si le
  paywall est actif et l'accès refusé.
- Tests : `tests/EntitlementTests.swift` (28 contrôles, faux serveur, aucun réseau).
- **Inactif par défaut** : sans `PlaymeltPaywallEnabled = true` dans l'Info.plist, l'app
  se comporte exactement comme avant.

## Fournisseur retenu : « merchant of record » (Lemon Squeezy)

Raison : app vendue hors App Store (DMG + Sparkle). Un merchant of record encaisse à ta
place, gère la TVA européenne pays par pays, les factures, les remboursements et les
abonnements, et délivre une clé de licence par achat avec une API publique de vérification.
Aucun serveur 7AGENCY n'est nécessaire. Alternative : Paddle (pas de clés de licence
intégrées, il faudrait un petit serveur de licences).

## Ce que toi seul peux faire (comptes, contrats, argent)

1. Créer le compte vendeur (Lemon Squeezy ou Paddle), avec ton entreprise et ton IBAN.
2. Créer le produit « Playmelt » avec 5 variantes (les offres ci-dessus), et activer
   « License keys » (1 Mac par clé ou 2, à décider) ; la licence d'un abonnement doit
   expirer avec l'abonnement.
3. Me donner : identifiant du magasin, identifiant du produit, identifiants des 5 variantes,
   lien de paiement. Je les mets dans `build.sh` (Info.plist de la version `--release`) :
   `PlaymeltLicenseStoreID`, `PlaymeltLicenseProductIDs`, `PlaymeltLicenseVariantPlans`,
   `PlaymeltCheckoutURL`, puis `PlaymeltPaywallEnabled = true`.
4. Pages légales sur le site : CGV, mentions légales, confidentialité (RGPD), et la
   case de **renonciation au droit de rétractation de 14 jours** pour un contenu numérique
   fourni immédiatement (sinon remboursement possible sous 14 jours).

## À régler AVANT d'encaisser (risques réels)

1. **Licence Apple du Game Porting Toolkit.** Le cœur DX12 / DLSS de Playmelt repose sur
   D3DMetal, que l'utilisateur importe lui-même. Vendre un abonnement dont la valeur dépend
   d'un outil Apple sous licence d'évaluation doit être validé par un juriste (CrossOver a
   un accord avec Apple). Playmelt ne redistribue pas D3DMetal : c'est déjà le bon modèle.
2. **`Resources/steam_api64.dll`** : c'est la DLL Steam de Valve. Elle est versionnée dans le
   dépôt public et copiée dans l'app par `build.sh`, alors qu'aucun code ne l'appelle. Il faut
   la retirer de l'app et du dépôt avant toute vente : sa redistribution n'est pas autorisée
   hors des jeux Steamworks.
3. **Dépôt GitHub public** (choix gardé le 12/11) : n'importe qui peut recompiler Playmelt
   sans le contrôle d'abonnement. La licence propriétaire l'interdit juridiquement, mais ne
   l'empêche pas techniquement. Le passer en privé reste la seule protection technique.
4. **Fonctions d'identité matérielle** (scripts `gpu_hardwareid_*`, `m3_private_*`) et jeux
   protégés par un anti-triche : à exclure ou faire valider, car ils peuvent contrevenir aux
   conditions des éditeurs.
5. **Marque** : déposer « Playmelt » à l'INPI (classe 9, logiciels ; classe 42) protège le
   nom. L'idée elle-même ne se protège pas ; le code, si, par le droit d'auteur (la licence
   et l'historique Git datent la création).
