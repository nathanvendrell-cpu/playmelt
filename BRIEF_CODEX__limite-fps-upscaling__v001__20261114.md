# Brief Codex — limite de FPS et upscaling MetalFX pour tous les jeux (Claude M3, 14/11/2026)

Réponds en français. Demande de Nathan (14/11, vers 00 h 40), ses mots : « il faut demander à codex, la session
qui travail sur playmelt, de faire sa pour tous les jeux, de toute les plateformes ».
« ça » = limite de FPS + upscaling MetalFX, aujourd'hui absents hors Spider-Man 2.
Voir aussi `BRIEF_CODEX__deploiement-perf__v001__20261114.md` (deux correctifs `Core.swift` à déployer).

## Constat (lu dans le code et les binaires installés, rien lancé en jeu)

- `GameSettings.swift` : `capabilities()` renvoie `"display":special,"graphics":special` et `validFields()`
  n'autorise display/graphics que pour SM2. Les autres jeux n'ont que `backend` et `launchArgs`.
- `dynamicFPS` existant = cible de résolution dynamique de SM2 (0/30/60), pas une limite d'images : ne pas le réutiliser.
- Les lanceurs (`ensureLaunchScript`, `Core.swift`) sont statiques par jeu : aucun réglage graphique n'y arrive.
  Point d'injection simple : l'environnement de lancement dans `main.swift`, là où est posé
  `launchEnvironment["PLAYMELT_BENCHMARK_SESSION"]` ; vérifier aussi `launchManagedEpic`.
- DXMT installé (`Runtime/playmelt-wine10-dxmt-20261017/renderers/dxmt`), chaînes présentes dans les binaires :
  `DXMT_CONFIG`, `DXMT_CONFIG_FILE`, `d3d11.preferredMaxFrameRate`, `d3d11.metalSpatialUpscaleFactor`,
  `DXMT_METALFX_SPATIAL_SWAPCHAIN`. Sémantique d'après la doc DXMT, **non vérifiée en jeu ici**.
- D3DMetal 4.0b3 importé : chaîne `D3DM_MAX_FPS` présente dans le binaire. **Sémantique non vérifiée** :
  la confirmer (doc Apple ou essai mesuré) avant de l'afficher comme limite fonctionnelle.
- Écran interne du M3 : 120 Hz ; réglage par défaut `refreshRate` 60.

## À produire

1. Réglages par jeu, pour tout jeu Windows lancé par Playmelt (Steam, Epic, GOG, import local) :
   - limite de FPS : aucune / 30 / 40 / 45 / 60 / 90 / 120 ;
   - upscaling MetalFX (DX11/DXMT) : désactivé / ×1,5 / ×2, avec la résolution de rendu ajustée en conséquence
     (le jeu rend plus petit, MetalFX agrandit vers la taille de fenêtre choisie).
2. Schéma : nouveaux champs distincts, fichiers enregistrés existants toujours lisibles (valeurs par défaut si absents),
   `GameSettingsTests` et tests UI mis à jour.
3. Interface dans la fiche de réglages du jeu, libellés honnêtes : « Upscaling MetalFX (DirectX 11) » ;
   pour DirectX 12, l'upscaling passe par le jeu (FSR) ou par le pont DLSS → MetalFX non installé : ne pas le promettre.
4. Dire clairement dans l'interface ce qui n'est pas concerné : jeux Mac natifs et jeux cloud
   (Xbox Cloud, GeForce NOW, Luna) ne passent pas par Wine, ces réglages n'y ont aucun effet.
5. Spider-Man 2 : profil verrouillé par empreintes, ne pas le modifier sans qualification dédiée.

## Contraintes

- Aucun jeu lancé sans Nathan ; aucune valeur annoncée comme gain sans mesure.
- Sauvegarder l'app installée avant remplacement ; rien d'écrasé ; auto-tests natifs et UI rejoués.
- Rapport court à Nathan : fait, vérifié, non vérifié.
