import SwiftUI

/// "Manage roles": row-level security roles, a DAX filter per table.
struct RolesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Gérer les rôles")).font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    List(selection: $selected) {
                        ForEach(state.roles) { r in Text(r.name).tag(r.id) }
                    }
                    .frame(width: 180, height: 260)
                    HStack {
                        Button { selected = state.addRole() } label: { Image(systemName: "plus") }
                        Button {
                            if let id = selected { state.deleteRole(id); selected = state.roles.first?.id }
                        } label: { Image(systemName: "minus") }
                        .disabled(selected == nil)
                    }
                    .buttonStyle(.borderless)
                }
                if let id = selected, let role = state.roles.first(where: { $0.id == id }) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField(L("Nom du rôle"), text: Binding(get: { role.name }, set: { n in state.mutateRole(id) { $0.name = n } }))
                                .textFieldStyle(.roundedBorder)
                            Text(L("Filtres DAX par table (les lignes où l'expression est vraie restent visibles) :"))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            ForEach(state.tables.filter { $0.calculationItems == nil }) { t in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(t.name).font(.system(size: 11, weight: .semibold))
                                    let expr = role.filters[t.name] ?? ""
                                    TextField(L("Aucun filtre"), text: Binding(get: { expr }, set: { e in
                                        state.mutateRole(id) { $0.filters[t.name] = e.isEmpty ? nil : e }
                                    }))
                                    .font(.system(size: 12, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                                    if !expr.isEmpty, let err = MeasureCompiler.validate(expr, home: t.name, name: "", state.model) {
                                        Text(err).font(.system(size: 10)).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: 420, height: 290)
                } else {
                    Text(L("Ajoutez un rôle avec +.")).foregroundStyle(.secondary).frame(width: 420, height: 290)
                }
            }
            Text(L("Exemple : [Région] = \"Nord\", ou [Email] = USERPRINCIPALNAME()."))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button(L("Fermer")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { selected = state.roles.first?.id }
    }
}

extension AppState {
    func addRole() -> UUID {
        var n = L("Rôle %@", roles.count + 1), k = roles.count + 2
        while roles.contains(where: { $0.name == n }) { n = L("Rôle %@", k); k += 1 }
        let r = SecurityRole(name: n)
        roles.append(r)
        didChange()
        return r.id
    }

    func deleteRole(_ id: UUID) {
        if roles.first(where: { $0.id == id })?.name == viewAsRole { viewAsRole = nil }
        roles.removeAll { $0.id == id }
        didChange()
    }

    func mutateRole(_ id: UUID, _ body: (inout SecurityRole) -> Void) {
        guard let i = roles.firstIndex(where: { $0.id == id }) else { return }
        let old = roles[i].name
        body(&roles[i])
        if viewAsRole == old { viewAsRole = roles[i].name }
        didChange()
    }
}

/// Banner shown while the report is viewed as a role.
struct RoleBanner: View {
    @Environment(AppState.self) private var state
    var body: some View {
        if let r = state.viewAsRole {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.shield.checkmark")
                Text(L("Affichage en tant que : %@", r) + (state.viewAsUser.isEmpty ? "" : " (\(state.viewAsUser))"))
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L("Arrêter")) { state.viewAsRole = nil }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.yellow.opacity(0.25))
        }
    }
}
