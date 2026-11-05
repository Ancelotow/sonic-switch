import SwiftUI
import VPNCore

@MainActor struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var loginAssistant = LoginAssistant.shared
    @State private var search = ""
    @State private var editing: VPNProfile?
    @State private var deleting: VPNProfile?
    // NavigationSplitView can reconcile List selection while drawing. Keep its
    // binding local instead of publishing an ObservableObject change mid-render.
    @State private var selection: UUID?
    private var selected: VPNProfile? { model.profiles.first { $0.id == selection } }
    private var filtered: [VPNProfile] {
        model.sortedProfiles.filter { search.isEmpty || ($0.name + " " + $0.server).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "network.badge.shield.half.filled")
                        .font(.title).foregroundStyle(.teal)
                    VStack(alignment: .leading) {
                        Text("SonicSwitch").font(.headline)
                        Text("Tes VPN, au même endroit").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 18)
                TextField("Rechercher un VPN", text: $search)
                    .textFieldStyle(.roundedBorder).padding(.horizontal, 12)
                    .accessibilityLabel("Rechercher un VPN")
                List(selection: $selection) {
                    ForEach(filtered) { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.favorite ? "star.fill" : "network")
                                .foregroundStyle(profile.favorite ? .orange : .teal)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).fontWeight(.medium)
                                Text(profile.server.isEmpty ? "Profil Mobile Connect" : profile.server)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if model.monitoringError == nil,
                               model.services.contains(where: { $0.name == profile.connectionName && $0.isConnected }) {
                                Circle().fill(.green).frame(width: 7, height: 7).accessibilityLabel("Connecté")
                            }
                        }.padding(.vertical, 6).tag(profile.id)
                    }
                }.listStyle(.sidebar)
                VStack(spacing: 8) {
                    Button { editing = VPNProfile() } label: {
                        Label("Ajouter un VPN", systemImage: "plus").frame(maxWidth: .infinity)
                    }.controlSize(.large).disabled(!model.ready || model.busy)
                    Button("Importer les profils SonicWall") { Task { await model.importProfiles() } }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        .disabled(!model.ready || model.busy)
                }.padding(12)
            }.navigationSplitViewColumnWidth(min: 245, ideal: 270, max: 330)
        } detail: {
            ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                statusBar
                if let message = model.message {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Connexion impossible", systemImage: "exclamationmark.triangle.fill").fontWeight(.semibold)
                        Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("Afficher Mobile Connect") { model.openSonicWall() }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
                if let profile = selected {
                    profileDetail(profile)
                } else {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "network").font(.system(size: 48)).foregroundStyle(.teal)
                        Text("Choisis ton prochain VPN").font(.title2).fontWeight(.semibold)
                        Text("Sélectionne un profil ou ajoute un serveur SonicWall.")
                            .foregroundStyle(.secondary)
                        Button("Ajouter un VPN") { editing = VPNProfile() }
                            .buttonStyle(.borderedProminent).tint(.teal).disabled(!model.ready || model.busy)
                    }.frame(maxWidth: .infinity)
                    Spacer()
                }
            }.padding(30)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(.teal)
        .onAppear { selection = model.selectedID }
        .onChange(of: model.selectedID) { value in
            if selection != value { selection = value }
        }
        .onChange(of: selection) { value in
            Task { @MainActor in
                if model.selectedID != value { model.selectedID = value }
            }
        }
        .sheet(item: $editing) { profile in ProfileEditor(model: model, draft: profile) }
        .confirmationDialog("Supprimer ce profil de SonicSwitch ?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Supprimer le profil et son mot de passe", role: .destructive) {
                if let deleting { model.delete(deleting) }
                deleting = nil
            }
        } message: { Text("La configuration dans Mobile Connect et la connexion actuelle sont conservées.") }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(model.monitoringError != nil ? .orange : model.active?.isConnected == true ? .green : .gray)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.monitoringError != nil ? "État VPN indisponible" : model.active.map { "\($0.name) · \($0.stateLabel)" } ?? "Aucun VPN SonicWall actif")
                    .font(.subheadline).fontWeight(.medium)
                if let error = model.monitoringError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
                Button("Afficher Mobile Connect") { model.openSonicWall() }
            }
            if model.active != nil || model.busy {
                Button(model.busy ? "Annuler et déconnecter" : "Déconnecter") { model.disconnect() }
            }
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func profileDetail(_ profile: VPNProfile) -> some View {
        let connected = model.monitoringError == nil && model.services.contains { $0.name == profile.connectionName && $0.isConnected }
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(profile.name).font(.system(size: 32, weight: .bold, design: .rounded)).textSelection(.enabled)
                    Text("SonicWall SSL VPN").foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = profile } label: { Image(systemName: "pencil") }.help("Modifier le profil")
                    .disabled(model.busy || !model.ready)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 18) {
                infoRow("Serveur", profile.server.isEmpty ? "Configuré dans Mobile Connect" : profile.server)
                infoRow("Profil SonicWall", profile.connectionName)
                infoRow("Identifiant", profile.username.isEmpty ? "Géré par Mobile Connect" : profile.username)
                if !profile.group.isEmpty { infoRow(profile.usesRealm ? "Realm" : "Domaine", profile.group) }
                GridRow {
                    Text("Mot de passe").foregroundStyle(.secondary)
                    Label(model.savedPasswords.contains(profile.id) ? "Enregistré dans le Trousseau" : "À enregistrer ou géré par SonicWall",
                          systemImage: model.savedPasswords.contains(profile.id) ? "lock.shield" : "key")
                        .foregroundStyle(model.savedPasswords.contains(profile.id) ? .teal : .secondary)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            if model.savedPasswords.contains(profile.id) {
                VStack(alignment: .leading, spacing: 8) {
                    if !loginAssistant.permissionGranted {
                        Button("Autoriser le remplissage automatique") { loginAssistant.requestPermission() }
                        Text("Une autorisation Accessibilité de macOS est nécessaire pour remplir le formulaire de Mobile Connect.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if loginAssistant.connectionName == profile.connectionName, let message = loginAssistant.message {
                        Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    if model.passwordSentFor == profile.id {
                        Label("Mot de passe envoyé à Mobile Connect", systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.teal)
                    }
                    Button { model.copyPassword(profile) } label: {
                        Label("Copier le mot de passe", systemImage: "doc.on.doc")
                    }.disabled(model.copyingPassword)
                    Text("Si SonicWall le redemande, colle-le avec ⌘V. La copie expire après 30 secondes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button { model.connect(profile) } label: {
                Label(connected ? "Connecté" : model.active != nil ? "Basculer vers ce VPN" : "Connecter",
                      systemImage: connected ? "checkmark.shield.fill" : "bolt.fill")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).controlSize(.large).tint(.teal)
                .disabled(model.busy || !model.ready || connected || model.monitoringError != nil)
                .keyboardShortcut(.return, modifiers: .command)
            if let notice = model.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(.teal)
                Text("Mots de passe conservés dans le Trousseau de ce Mac. SonicWall assure la connexion et demande les codes MFA si nécessaire.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Ouvrir Mobile Connect") { model.openSonicWall() }.buttonStyle(.link)
                Spacer()
                Button(role: .destructive) { deleting = profile } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Supprimer de SonicSwitch").disabled(model.busy || !model.ready)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
