# Playmelt — revue globale d'interface, v001 (12/11/2026, 20 h 30)

Base observée : app installée `~/Applications/Playmelt.app` (binaire du 12/11 à 19 h 49), fenêtre 1372 × 895,
bibliothèque réelle (1 318 jeux). Les sources ont encore bougé après ce binaire (20 h 03–20 h 05) : chaque point
est à revérifier sur la version courante avant correction. Aucune source modifiée pendant cette revue.
Écrans non ouverts : Big Picture (passe en plein écran), fenêtre d'abonnement, assistant de première ouverture
(lus dans le code seulement).

## A. Règles à poser (une fois, pour toute l'app)

1. **Surfaces.** Coque claire pour tout ce qui est outil (barre latérale, bandeau, listes, réglages) ;
   sombre réservé aux médias (bandeau héros, cartes d'offres, fiche jeu). Un même contenu = un même composant
   partout : aujourd'hui une actu est une bande sombre sur l'Accueil, une carte blanche dans Actus et une
   rangée illustrée dans la fiche jeu.
2. **Boutons, trois niveaux.** La règle « One solid action-button treatment » de `Resources/Experience.css`
   passe tout en orange (`.button`, `.row-link`, `.page-back`, `.mini-play`, désinstallation…).
   Résultat mesuré : 11 boutons orange sur Paramètres → Connexions, 6 sur une fiche jeu, 7 sur l'Accueil.
   Proposition : orange = l'action principale de l'écran (Jouer, Installer, Continuer vers le paiement) ;
   neutre (blanc sur clair, verre sur sombre) = Paramètres, Fichiers, Gérer, Ouvrir, Connecter, Actualiser ;
   texte = Tout voir, Retour, liens ; Désinstaller = neutre, rouge au survol.
3. **Titres = libellés du menu.** « Installés » ouvre « Jeux installés », « Téléchargements » ouvre
   « Téléchargements & Installations », « Profil » ouvre « Profil Playmelt ».
4. **Une seule voix.** Tutoiement (Accueil, abonnement : « de tes jeux », « Toutes tes plateformes ») et
   vouvoiement (Profil, Paramètres, assistant : « Votre pseudo », « Vos jeux installés ») cohabitent.
5. **Rayons.** 16 px pour les cartes, 12 px pour les affiches, 9 px pour les boutons. Les affiches de la
   grille sont à angles droits alors que les cartes « Continuer à jouer » sont arrondies.

## B. Mise en page et place

1. **Barre latérale (bloquant).** 16 entrées pour ~690 px utiles : la liste défile sous le logo. Selon la
   position, « Accueil » et « Bibliothèque » sont cachés, ou « Big Picture » et « Paramètres » passent sous la
   carte du compte. Proposition : Profil et Paramètres dans la carte du bas (avatar, pseudo, niveau, roue),
   Big Picture en bouton du bandeau → 13 entrées qui tiennent sans défilement.
2. **Carte du bas.** Elle affiche encore le sélecteur de compte Steam (« lafripsi », « À synchroniser »,
   « Connexion ») alors que l'app est un hub multi-plateformes : sa place est dans Paramètres → Connexions.
3. **Accueil.** Trois rangées sombres de suite puis « Sorties » en très grandes cartes pour un nom et un prix ;
   trois pastilles orange « Toutes les nouveautés » en bas. Les offres de l'Accueil doublent la vue Offres.
4. **Installés.** La rangée « Joués récemment » montre les 5 mêmes jeux que la grille juste dessous.
5. **Vue plateforme (Steam).** Bandeau « Les offres du moment » puis titre « Promotions » : deux titres pour
   un bloc ; les jeux de la plateforme n'arrivent qu'après un écran de promotions.
6. **Fiche jeu.** La ligne « Sur ce Mac » ne contient que la définition de l'écran et « Installé » : à fondre
   dans la ligne de chiffres clés. Chaque actu répète la même image trois fois (vignette, scène, fond flou).

## C. Parcours client et licence

1. **Deux systèmes en parallèle.** La fenêtre d'abonnement validée (durées, prix, clé de licence :
   `openSubscription`, `openCheckout`, `activateLicense`) ne s'ouvre que si le contrôle bloque, et il est
   désactivé (`PlaymeltPaywallEnabled` absent). Le nouveau service de comptes (`connectPlaymelt`,
   `openPlaymeltAccount`) vit dans Paramètres → Profil & abonnement. Aucun lien entre les deux.
2. **Texte de développement visible.** « Le service de comptes est en préparation. Vos jeux et votre
   progression restent disponibles dans cette version de développement. »
3. **Parcours cible.** Paramètres → Abonnement : un état lisible (Essai · jusqu'au…, Actif, À activer),
   une action principale (S'abonner ouvre la fenêtre de formules ; sinon Gérer), « J'ai une clé » en lien.
   Rappel discret de l'état dans la carte du bas.
4. **Mot « Offres ».** Dans le menu il désigne les promotions des boutiques ; il se confond avec les
   formules d'abonnement. Proposition : « Bons plans ».
5. **Première ouverture.** L'étape 3 parle d'une VM Windows « pas encore opérationnelle » : à retirer
   (deux étapes : pseudo, comptes).
6. **Réglages internes exposés.** Case « Rendus en cours » sans explication en tête de Mac & moteurs
   (protection des rendus 7AGENCY), bloc « À vérifier », « SESSION PRIVÉE », « Résultat non mesuré : aucune
   série de données exploitable ».

## D. Finitions

1. Cartes « Mises à jour » de l'Accueil : titre coupé au milieu de la 2e ligne ; le logo du jeu passe sous
   le texte (Satisfactory, Rocket League).
2. Images absentes : Pathogenic (cartes vides dans Actus et sur l'Accueil) ; prévoir le repli sur l'image
   de bibliothèque puis un aplat avec le nom.
3. Affiches de la grille : badge « Installé » sur chaque carte de la vue Installés (redondant) ; pastille de
   rang sous chaque affiche (bruit) → au survol ou dans la fiche seulement.
4. Fiche jeu : point de plateforme Epic noir sur fond sombre (invisible).
5. Bouton Actualiser du bandeau en orange plein.
6. Paramètres → Connexions : carrés de lettres colorés (S, E, X, G, A…) au lieu des points de plateforme
   utilisés partout ailleurs ; six fois « import de bibliothèque non intégré ».
7. Téléchargements vide : « installation optimisée » (remplissage).
8. Fenêtre inactive : les cartes « Continuer à jouer » se voilent de gris.
9. Tests d'interface `ui-epic-session` et `ui-grid` en échec depuis avant la v2.

## E. Ordre proposé

B1 → A2 → C1–C3 → A3/A4 → D1–D6 → B3–B6 → reste. Sauvegarde de l'app installée avant chaque installation,
aucun push sans accord.

## F. État après application (12/11/2026, 20 h 45)

Accord de Nathan : trois niveaux de boutons, application de l'ensemble. Codex travaille sur Stripe et la licence :
la logique de compte, de paiement et de licence n'a pas été touchée.

Appliqué et contrôlé dans l'app installée (12 suites de tests d'interface au vert) :
A2 (boutons), A3 (titres), A4 (tutoiement), A5 (rayons), B1, B2 (carte d'identité ; sélecteur Steam visible
seulement avec plusieurs comptes), B4, B5, B6, C2 (texte), C4 (« Bons plans »), C5 (assistant en 2 étapes),
D1, D2 (repli sur le texte dans Actus), D3 (grille), D4, D5, D6, D7.

Non fait :
- A1 : un seul composant d'actu pour l'Accueil, Actus et la fiche jeu (refonte, pas une finition).
- B3 : l'Accueil garde ses trois rangées sombres ; seules les sorties ont été compactées.
- C1, C3 : relier la fenêtre de formules et le service de comptes (chantier Stripe/licence de Codex).
- C6 : la case « Rendus en cours » et le bloc « À vérifier » restent visibles (décision produit : les masquer
  dans une version commerciale ?).
- D2 : les illustrations de Pathogenic restent introuvables sur le CDN ; la carte se replie sur son texte.
- Non vérifié à l'écran : Big Picture, fenêtre d'abonnement, assistant de première ouverture, fenêtres de
  profil et de signalement (boutons restylés par règle, non ouverts).

Fichiers modifiés : `index.html`, `Resources/Experience.css`, `Resources/Settings.js`, `Resources/Onboarding.js`,
`Resources/Discover.js`, `Resources/Experience.js`. Rien de commité (sources mêlées au travail non commité de Codex).
Sauvegarde de l'app d'avant : `Backups.noindex/Playmelt-installed__2.1.0__20261112-2038-avant-revue-v3`.
