# Playmelt — moteur Windows hébergé sur macOS

Décision du 26 octobre 2026 : le moteur s'exécute dans un processus macOS,
sans Wine et sans machine virtuelle. Sur Apple Silicon, les instructions x64
des exécutables Windows passent encore par Rosetta. Le mot « natif » décrit
l'hôte et les services macOS, pas une conversion du jeu en code ARM64.

L'application installée n'intègre pas ce prototype. Les fichiers Windows de
Satisfactory sont préparés, mais leur présence ne constitue pas une installation
jouable. Aucun jeu ni composant graphique n'a été exécuté pour cette décision.

## Séparation des responsabilités

| Couche | Choix | Preuve nécessaire avant activation |
|---|---|---|
| Processus | Helper macOS x86_64 à durée de vie bornée, piloté par Playmelt | Arrêt, collecte d'erreurs et nettoyage des seuls processus créés |
| Exécutables | Chargeur PE indépendant existant | TLS/TEB, CRT, DLL, exceptions et dépendances réellement nécessaires au jeu |
| Fonctions Windows | Services explicites et refus des fonctions non implémentées | Contrat de chaque fonction, ABI, erreurs et durée de vie vérifiés |
| Graphisme | Candidat `d3dmetal-native` avec le framework Apple acquis séparément | Transitions CPU, version exacte du framework, puis tests graphiques autorisés |
| Fenêtre et entrées | AppKit/CAMetalLayer et adaptateurs Windows dédiés | Thread principal, handles, dimensions, événements et callbacks |
| Installation | Fichiers officiels et session du client du propriétaire | Manifeste, prérequis, enregistrement, puis lancement réellement fonctionnel |

Un répertoire isolé facilite la gestion des fichiers. Il ne fournit ni Win32,
ni DirectX, ni l'isolation d'une sandbox. Le prototype n'accepte toujours aucun
exécutable externe en ligne de commande.

## Premier verrou : les données de thread

L'inspection locale de Satisfactory relève un gabarit TLS de 369 octets et deux
callbacks dans l'exécutable Shipping ; la DLL Core en contient 3 216 octets,
deux callbacks et une entrée DLL non nulle. Les 2 708 occurrences d'imports dans
les sept fichiers inspectés incluent des exports Unreal : ce nombre n'est pas
un décompte d'API Windows manquantes. Source locale :
`work/satisfactory-pe-inspection.json`.

Le TLS statique Windows x64 utilise les données du TEB accessibles via GS.
Darwin x86 utilise aussi GS pour ses données pthread. Modifier GS puis appeler
directement du C hôte serait donc insuffisant. La [sonde CPU isolée](loader/GS_PROBE.md)
a réussi le 26 octobre 2026 sous Rosetta : deux accès réels au bloc guest,
deux passages vers un service hôte et restauration finale. Elle vérifie
`pthread_self`, `errno`, huit registres généraux et dix registres XMM après des
modifications volontaires côté hôte. Les 184 contrôles hôtes ASan/UBSan, neuf
contrôles de classification et trois contrôles négatifs ont également passé.
Ces derniers précèdent le changement de GS : ils vérifient le compte rendu
et l'arrêt des enfants, pas la récupération d'une faute sous GS guest.

Reçu : `work/gs-probe-proof-attempt1.log` ; contrôle indépendant des sept
empreintes, des processus terminés et des temporaires supprimés :
`work/gs-probe-root-verification.json`. Aucun PE n'est chargé par cette sonde :
elle exécute notre séquence assembleur, avec un appel indirect au format Win64.

Même une sonde réussie ne couvre pas les signaux asynchrones, les exceptions,
la réentrance, les nouveaux threads d'un jeu ou toutes les versions de Rosetta.
Elle ne doit pas lever le refus du répertoire TLS dans le chargeur strict.

Le raccordement à une [fixture PE embarquée](loader/GS_PE_PROBE.md) a ensuite
réussi : le chargeur strict prépare le PE de 5 120 octets, sa table d'import et
ses permissions RX/R/RW. Son point d'entrée effectue deux appels IAT et deux
écritures dans le bloc de test avant de retourner zéro. Un second processus
vérifie le refus volontaire du premier appel : retour un, aucune seconde
écriture, contexte restauré. Les deux images sont déchargées et leur absence
confirmée par Mach. Le désassemblage indépendant confirme les appels IAT et les
gardes d'erreur immédiatement après ceux-ci.

Cette fixture n'a toujours pas de répertoire TLS PE : le bloc reste préparé
par l'hôte. Les 19 contrôles de génération, 14 contrôles hôtes ASan/UBSan et
les deux parcours exécutés sont distincts d'une initialisation Windows complète.
Preuves : `work/gs-pe-proof-attempt2.log`, `work/gs-pe-encoding-review.json`
et `work/gs-pe-root-verification.json`. L'essai de compilation initial, arrêté
par un avertissement sur un helper inutilisé dans la variante inerte, reste
conservé dans `work/gs-pe-proof-attempt1.log` ; aucun PE n'y avait été exécuté.

Références : [TLS et format PE Microsoft](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#the-tls-section),
[initialisation CRT Microsoft](https://learn.microsoft.com/en-us/cpp/c-runtime-library/crt-initialization?view=msvc-170),
[GS dans XNU, révision fixe](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/x86_64/idt64.s).

## Backend graphique retenu pour qualification

Le candidat est [utmapp/d3dmetal-native à la révision
422df8736de0f371d5ecee71e04b3ed19c4a2183](https://github.com/utmapp/d3dmetal-native/tree/422df8736de0f371d5ecee71e04b3ed19c4a2183).
Sa bibliothèque macOS fournit l'interface hôte GFXT attendue par le framework
Apple. Son build dépend des frameworks macOS et de `directx-native` ; QEMU,
Neptune et un Windows invité ne sont pas requis par cette bibliothèque.

Les entrées D3D et méthodes COM déclarent l'ABI Microsoft x64 ; les services
GFXT hôtes utilisent l'ABI SysV. Le commentaire SysV en tête de `dmn_init.cpp`
ne décrit pas ses exports actuels, déclarés `DMN_MS_ABI`. Les méthodes D3D12
qui renvoient des structures exigent également
`WIDL_EXPLICIT_AGGREGATE_RETURNS=1` dans le contrat de construction.

Cela ne justifie pas un branchement direct des pointeurs COM dans le jeu : les
transitions GS, les callbacks et chaque forme de retour doivent être qualifiés.
Les handles d'événements et les pseudo-HWND du backend ne sont pas les tokens
du prototype Win32. Ils nécessitent un adaptateur avec une propriété explicite.

`dmn_init()` charge le framework, appelle `GFXT_Initialize` et installe des
interceptions Metal. Il n'a pas de procédure de fermeture : sa durée de vie est
celle du processus. Même une requête `dmn_framework_has_entry_point()` peut
déclencher cette initialisation. Aucune de ces fonctions n'est un contrôle
statique autorisé pendant les rendus. Le chargement générique `dlopen(name)`
interne ne doit pas devenir notre implémentation de `LoadLibrary` Windows.

Sources fixes : [interface](https://github.com/utmapp/d3dmetal-native/blob/422df8736de0f371d5ecee71e04b3ed19c4a2183/include/d3dmetal_native.h),
[exports et initialisation](https://github.com/utmapp/d3dmetal-native/blob/422df8736de0f371d5ecee71e04b3ed19c4a2183/src/dmn_init.cpp),
[ABI COM](https://github.com/utmapp/d3dmetal-native/blob/422df8736de0f371d5ecee71e04b3ed19c4a2183/include/native/windows/windows_base.h),
[construction](https://github.com/utmapp/d3dmetal-native/blob/422df8736de0f371d5ecee71e04b3ed19c4a2183/meson.build),
[chargement des bibliothèques](https://github.com/utmapp/d3dmetal-native/blob/422df8736de0f371d5ecee71e04b3ed19c4a2183/src/dmn_gfxt_library.cpp).

Le wrapper est MIT ; `directx-native` est Apache 2.0. Les déclarations d'interfaces
incluent des origines Wine/MinGW : absence de runtime Wine ne signifie pas
absence de toute déclaration issue de ces projets. La licence Apple reste
séparée. Aucun code tiers n'est incorporé par cette note. Le framework Apple
4.0 beta 3 local n'est pas qualifié avec ce wrapper et ne doit pas être modifié
par les scripts upstream de remplacement d'imports privés.

DXMT natif reste une alternative D3D10/11, mais ses conventions d'appel natives
exigent un autre pont vers le PE Microsoft x64. Le choix actuel privilégie le
backend couvrant également D3D12, sans prétendre que cette couverture est déjà
vérifiée dans Playmelt.

## Ordre des validations

1. Initialiser un vrai template TLS déclaré par une fixture PE, son zéro initial
   et son index, avec un opt-in distinct ; les callbacks non pris en charge
   doivent rester des refus explicites.
2. Construire le TLS statique et l'ordre d'initialisation des modules, avec
   notifications, dépendances et nettoyage ; conserver les refus hors contrat.
3. Traiter les prérequis CRT et les exceptions réellement observés. L'actuel
   calcul limité d'une trame appelante ne constitue pas SEH ni un runtime C++.
4. Qualifier les appels D3D/COM et leurs callbacks avec un backend CPU factice
   explicitement identifié, puis le backend Apple exact après autorisation
   graphique. Les résultats factices ne prouvent jamais DirectX fonctionnel.
5. Raccorder les autres services requis, Steamworks, fenêtre, entrées et audio,
   puis tester Satisfactory réellement après la fin des rendus confirmée.

La mémoire unifiée n'est pas une réserve de VRAM dédiée : le budget futur doit
tenir compte des allocations réelles, de la pression mémoire et de l'état
thermique. Aucun quota système ni réservation GPU n'est modifié. Les capacités
DLSS, FSR et HDR restent à prouver séparément ; aucune émulation de nom de GPU
ou annonce de fonctionnalité ne remplace une implémentation.

Pendant les rendus : aucune ouverture de jeu, Steam, Wine ou VM ; aucune
initialisation graphique, exécution de shader, inférence ou mesure GPU. Seules
les petites sondes CPU autorisées, compilées séquentiellement à priorité réduite,
peuvent avancer. Les mesures 1080p, 1440p et 4K restent absentes tant que le jeu
n'a pas effectivement été testé selon le protocole préparé.
