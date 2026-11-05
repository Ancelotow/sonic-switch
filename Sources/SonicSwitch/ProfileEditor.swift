import SwiftUI
import VPNCore

struct ProfileEditor: View {
    @ObservedObject var model: AppModel
    @State var draft: VPNProfile
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var forgetPassword = false
    @State private var error: String?
    private var existing: Bool { model.profiles.contains { $0.id == draft.id } }
    private var savedPassword: Bool { model.savedPasswords.contains(draft.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing ? "Modifier le VPN" : "Ajouter un VPN")
                .font(.title2).fontWeight(.semibold).padding(24)
            Form {
                Section("Connexion") {
                    TextField("Nom affiché", text: $draft.name)
                    TextField("Nom du profil SonicWall", text: $draft.connectionName)
                    TextField("Serveur", text: $draft.server, prompt: Text("vpn.exemple.fr:4433"))
                    Text("Pour un profil déjà présent dans Mobile Connect, garde son nom exact ; le serveur peut rester vide.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Identifiants") {
                    TextField("Utilisateur", text: $draft.username)
                    SecureField(savedPassword ? "Nouveau mot de passe" : "Mot de passe", text: $password)
                        .disabled(forgetPassword)
                    if savedPassword {
                        Text("Laisse ce champ vide pour garder le mot de passe enregistré.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Oublier le mot de passe enregistré", isOn: $forgetPassword)
                    } else {
                        Text("Facultatif : si tu le renseignes, il sera enregistré dans le Trousseau macOS.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField(draft.usesRealm ? "Realm" : "Domaine", text: $draft.group, prompt: Text("Facultatif"))
                    Toggle("Serveur SMA 1000 (utiliser realm)", isOn: $draft.usesRealm)
                }
                Section {
                    Toggle("Favori", isOn: $draft.favorite)
                    Text("À la connexion, le mot de passe est transmis à Mobile Connect via son mécanisme URL Control officiel. Les codes MFA restent à saisir dans SonicWall.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 24).padding(.bottom, 12) }
            HStack {
                Spacer()
                Button("Annuler") { password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") {
                    if draft.connectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.connectionName = draft.name }
                    do {
                        try model.save(draft, password: password, forgetPassword: forgetPassword)
                        password = ""
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(.teal).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 560, height: 660)
            .onDisappear { password = "" }
    }
}
