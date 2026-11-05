# SonicSwitch

Une petite application native macOS pour basculer entre plusieurs VPN **SonicWall SSL VPN**. Elle utilise **SonicWall Mobile Connect**, déjà installé sur le Mac, pour établir les tunnels. Elle n’implémente pas de protocole VPN et ne remplace pas le client SonicWall.

## Utilisation

1. Ouvrir l’application **SonicSwitch.app** produite dans le dossier `dist`.
2. Les noms des profils SonicWall existants sont importés au premier lancement. Le bouton **Importer les profils SonicWall** permet d’en ajouter d’autres ultérieurement.
3. Sélectionner un profil, cliquer sur le crayon, renseigner l’utilisateur et le mot de passe, puis **Enregistrer**. Laisser le serveur vide pour conserver la configuration d’un profil existant. Le domaine est facultatif si SonicWall le connaît déjà.
4. Cliquer sur **Connecter** ou **Basculer vers ce VPN**. L’ancien VPN SonicWall doit être complètement déconnecté avant le lancement du suivant. Les autres fournisseurs de VPN sont ignorés.
5. Utiliser le menu **VPN** dans la barre de menus pour changer de profil rapidement. Fermer la fenêtre laisse ce menu disponible. Quitter SonicSwitch conserve le tunnel actif.

La fenêtre reste disponible pendant la connexion, y compris lors de l’accès au Trousseau. Le menu VPN ouvre la fenêtre avant un basculement. Mobile Connect est ensuite affiché au premier plan pour rendre visibles ses demandes d’autorisation, d’identifiants ou de MFA. Le bouton **Afficher Mobile Connect** permet de le retrouver. Les étapes et les erreurs restent affichées dans SonicSwitch.

Pour un nouveau VPN, renseigner son serveur, par exemple `vpn.exemple.fr:4433`, son utilisateur et son domaine. Le nom du profil SonicWall doit être unique. Pour SMA 1000, activer l’option **realm**.

Pour un profil existant utilisant un mot de passe SonicSwitch, les champs utilisateur, domaine et serveur vides sont complétés à la connexion avec la configuration publique de ce profil macOS. Les valeurs saisies dans SonicSwitch restent prioritaires ; le type domaine/realm reste celui choisi dans l’éditeur. Aucun identifiant secret de SonicWall n’est importé.

Si Mobile Connect redemande les identifiants malgré URL Control, sélectionner le profil dans SonicSwitch et cliquer **Autoriser le remplissage automatique**. Dans **Réglages Système > Confidentialité et sécurité > Accessibilité**, autoriser SonicSwitch, puis relancer la tentative. Cette autorisation macOS permet à SonicSwitch de renseigner le formulaire de connexion de Mobile Connect. Elle ne peut pas être accordée par l’application elle-même.

Le remplissage attend que Mobile Connect soit au premier plan. Il vérifie l’adresse exacte du serveur (port compris) et le champ utilisateur dans son formulaire avant d’écrire le mot de passe. Un seul champ sécurisé doit être présent. Le bouton de connexion est actionné uniquement s’il est identifié sans ambiguïté ; sinon, valider dans SonicWall. Les formulaires de MFA, de changement de mot de passe, de proxy ou qui ne permettent pas d’identifier le serveur sont ignorés. Le remplissage ne passe ni par le clavier simulé ni par le presse-papiers et ne lit pas le contenu des champs sécurisés. Le secret en mémoire est libéré à la fin de la tentative, y compris lors d’une annulation.

## Mots de passe

Les secrets sont enregistrés dans le **Trousseau macOS**, dans des éléments propres à SonicSwitch, sans synchronisation iCloud. Le fichier JSON des profils ne contient que les noms, serveurs, utilisateurs, domaines et favoris ; il est écrit de façon atomique avec des permissions `0600` dans `~/Library/Application Support/SonicSwitch/profiles.json`.

À la connexion, l’application lit le secret et le transmet directement à l’application SonicWall identifiée par son identifiant de bundle, avec le paramètre `password` de son mécanisme officiel **URL Control**. Cette transmission contient donc le secret dans une URL locale en mémoire, transmise par macOS à SonicWall. SonicSwitch ne journalise pas cette URL, ne la copie pas automatiquement dans le presse-papiers et n’utilise ni navigateur ni commande shell pour la transmettre. Le stockage et la journalisation éventuels effectués par macOS ou SonicWall sont hors de son contrôle. Il faut laisser la journalisation de débogage SonicWall désactivée en usage normal.

La mention **Mot de passe envoyé à Mobile Connect** confirme la lecture et l’envoi du secret, pas son acceptation par le serveur. Si SonicWall demande encore le mot de passe, le bouton **Copier le mot de passe** permet de le coller avec ⌘V. Cette copie est volontaire, marquée confidentielle et temporaire pour les gestionnaires qui respectent ces indications. SonicSwitch l’efface après 30 secondes ou à sa fermeture, uniquement si rien d’autre n’a remplacé le presse-papiers. L’application ne peut pas garantir l’effacement des copies faites par un autre gestionnaire de presse-papiers.

Le champ de mot de passe reste masqué et vide lors des modifications. Vide signifie conserver l’existant ; l’option **Oublier le mot de passe enregistré** supprime le secret de SonicSwitch. Supprimer un profil retire aussi ce secret, sans effacer la configuration ni les identifiants éventuellement déjà conservés par SonicWall. Les mots de passe déjà détenus par SonicWall ne sont pas importés.

## Autorisations et limites

- Dans les préférences de **Mobile Connect**, activer **URL Control** si ce réglage est désactivé. SonicWall ou macOS peut demander une confirmation pour la première utilisation ou la création d’un VPN.
- Les certificats, validations d’entreprise et codes MFA sont traités dans Mobile Connect. Une politique du serveur peut imposer une nouvelle saisie des identifiants.
- Si la reconnexion automatique ou la connexion à la demande relance le VPN précédent, le basculement est interrompu. Désactiver ces options dans SonicWall ou les Réglages Système pour utiliser le basculement manuel.
- Le suivi lit uniquement la liste des services VPN avec `scutil --nc list`. Une erreur de lecture bloque le basculement. Le bouton **Annuler et déconnecter** arrête une tentative et déconnecte les VPN SonicWall actifs.
- Le lancement d’une demande n’est pas présenté comme une connexion réussie : l’application attend la confirmation macOS. Si aucun tunnel ne démarre sous 20 secondes, elle indique de vérifier **Préférences > URL Control** et les validations SonicWall. Un tunnel en cours d’établissement dispose de deux minutes. Une interruption ou un code d’erreur renvoyé par SonicWall est signalé sans attendre ce délai. Après expiration, vérifier Mobile Connect ou cliquer sur **Déconnecter** ; une authentification peut encore être en attente.
- Le retour officiel `callbackurl` est limité à un code numérique, associé à un identifiant aléatoire par tentative. Il ne transporte aucun mot de passe ni texte d’erreur libre et ne peut pas déclarer un tunnel connecté à la place de macOS.
- Application avec signature ad hoc, sans certificat Developer ID, notarisation Apple ni mise à jour automatique. Une recompilation peut provoquer une nouvelle demande d’accès au Trousseau ou à Accessibilité. Un téléchargement depuis GitHub peut être bloqué par Gatekeeper ; la création du DMG ne fournit pas de signature Apple.

## Compilation et tests

Prérequis : macOS 13 ou ultérieur, Swift 5.9 ou ultérieur et SonicWall Mobile Connect. Les tests nécessitent Xcode complet, notamment XCTest. Les scripts privilégient Xcode installé dans `/Applications/Xcode.app` ; `DEVELOPER_DIR` permet de choisir une autre installation. Aucune dépendance externe.

```sh
zsh scripts/test.sh
zsh scripts/build-app.sh
zsh scripts/build-dmg.sh
open dist/SonicSwitch.app
```

La compilation cible l’architecture du Mac de compilation (Apple Silicon sur ce Mac mini). Les sources sont séparées entre `VPNCore` (profils, Trousseau, commandes URL, basculement) et `SonicSwitch` (SwiftUI, surveillance et intégration macOS). Les tests de basculement utilisent un transport simulé : ils ne modifient aucune connexion réseau réelle. Le test du Trousseau crée puis efface son propre élément temporaire, avec des identifiants de test.

Pour compiler un DMG universel Apple Silicon + Intel :

```sh
zsh scripts/build-app.sh --arch arm64 --arch x86_64
zsh scripts/build-dmg.sh
```

Le DMG contient l’application et un raccourci vers Applications pour l’installation par glisser-déposer. Son nom inclut la version et l’architecture. Une somme SHA-256 accompagne l’image ; `hdiutil verify` et la vérification de signature sont exécutés pendant sa création.

## GitHub Actions et versions

Le dépôt est [Ancelotow/sonic-switch](https://github.com/Ancelotow/sonic-switch). Les workflows utilisent des runners macOS 15 avec Xcode et des actions épinglées sur des commits.

- **Vérifications macOS** : pour les pull requests et les pushes sur les branches autres que `main`, exécute les tests, compile les deux architectures et conserve un DMG de test pendant 7 jours.
- **Version et DMG** : à chaque push sur `main`, exécute les tests, incrémente la version corrective et le numéro de build dans `scripts/Info.plist`, compile le DMG universel puis publie le commit de version, le tag et la [GitHub Release](https://github.com/Ancelotow/sonic-switch/releases) avec le DMG et sa somme SHA-256. La première version automatique est `0.1.5` (build 6).
- Dans l’onglet **Actions > Version et DMG > Run workflow**, choisir `patch`, `minor` ou `major` pour une publication manuelle depuis `main`. Le calcul repart de la plus grande version du plist ou des tags `vX.Y.Z`, comparés numériquement.

La publication utilise le `GITHUB_TOKEN` fourni par GitHub avec la permission `contents: write` ; aucun secret supplémentaire n’est nécessaire pour une signature ad hoc. Les commits du bot ne redéclenchent pas de publication. Les publications sont sérialisées ; si `main` avance pendant la compilation, le push atomique est refusé et la publication suivante reprend les nouvelles modifications, sans écraser l’historique. Le DMG reste disponible dans les artefacts du workflow pendant 30 jours si la publication échoue. Si une protection de branche interdit les commits du bot, il faut autoriser ce mode de publication dans la configuration du dépôt.

Avant un nouveau push local après une publication, récupérer le commit automatique : `git pull --rebase`. Pour vérifier le calcul sans modifier la version : `python3 scripts/bump-version.py --dry-run`. Les tests de calcul se lancent avec `python3 scripts/test-version.py`.

Documentation du protocole : [commande connect — guide officiel SonicWall pour macOS](https://www.sonicwall.com/support/technical-documentation/docs/mc-macos_user_guide/Content/mobile_connect-5.0-macos_user_guide/preferences-and-url-control/using-the-connect-command.htm). Voir aussi [les préférences URL Control chez SonicWall](https://www.sonicwall.com/zh-cn/support/technical-documentation/docs/mc-macos_user_guide/Content/mobile_connect-5.0-macos_user_guide/preferences-and-url-control/preferences-overview.htm).
