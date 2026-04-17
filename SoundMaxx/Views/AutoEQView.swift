import SwiftUI

struct AutoEQView: View {
    @EnvironmentObject var eqModel: EQModel
    @StateObject private var autoEQManager = AutoEQManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var showFavoritesOnly = false
    @State private var selectedTypeFilter: String = "all"
    @State private var selectedHeadphone: AutoEQHeadphone?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            header

            searchField

            optionsRow

            if let info = autoEQManager.infoMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(info)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            if autoEQManager.isLoading {
                loadingView
            } else if let error = autoEQManager.errorMessage {
                errorView(error)
            } else {
                headphoneList
            }

            Spacer()

            footer
        }
        .padding()
        .frame(width: 400, height: 450)
        .onAppear {
            autoEQManager.loadHeadphoneIndexIfNeeded()
            autoEQManager.search(query: searchText)

            // Delay focus to ensure view is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "headphones")
                    .font(.title2)
                Text("AutoEQ Headphone Correction")
                    .font(.headline)
            }

            Text("Apply frequency response corrections for your headphones")
                .font(.caption)
                .foregroundColor(.secondary)
                .help("AutoEQ provides scientifically-measured corrections to flatten your headphone's frequency response")

            Link("Powered by AutoEQ", destination: URL(string: "https://github.com/jaakkopasanen/AutoEq")!)
                .font(.caption2)
                .help("Open AutoEQ project on GitHub")
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search headphones...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onChange(of: searchText) { newValue in
                    // Clear any error when user starts typing
                    autoEQManager.errorMessage = nil
                    autoEQManager.search(query: newValue)
                }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    autoEQManager.search(query: "")
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
        .help("Type to search for your headphones")
    }

    private var optionsRow: some View {
        VStack(spacing: 6) {
            Picker("Type", selection: $selectedTypeFilter) {
                Text("All").tag("all")
                Text("Over-ear").tag("over-ear")
                Text("In-ear").tag("in-ear")
                Text("On-ear").tag("on-ear")
                Text("Earbud").tag("earbud")
            }
            .pickerStyle(.segmented)
            .help("Filter by headphone type")

            HStack {
            Toggle("Favorites only", isOn: $showFavoritesOnly)
                .toggleStyle(.switch)
                .font(.caption)
                .help("Show only starred headphones")

            Spacer()

                Button {
                    autoEQManager.search(query: searchText)
                    autoEQManager.loadHeadphoneIndexIfNeeded(forceReload: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(autoEQManager.isLoading)
                .help("Force refresh the AutoEQ catalog from the network")

            Text("\(filteredHeadphones.count) results")
                .font(.caption2)
                .foregroundColor(.secondary)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(selectedHeadphone == nil ? "Loading AutoEQ catalog..." : "Fetching EQ data...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundColor(.orange)
            Text(error)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to List") {
                autoEQManager.errorMessage = nil
                selectedHeadphone = nil
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
    }

    private var filteredHeadphones: [AutoEQHeadphone] {
        let typeFiltered = autoEQManager.searchResults.filter { headphone in
            selectedTypeFilter == "all" || headphone.type == selectedTypeFilter
        }

        guard showFavoritesOnly else {
            return typeFiltered
        }

        return typeFiltered.filter { autoEQManager.isFavorite($0) }
    }

    private var emptyStateHint: String {
        if showFavoritesOnly {
            return "Star headphones in the list to save favorites"
        }

        if selectedTypeFilter != "all" {
            return "Try a different type filter or broaden your search"
        }

        return searchText.isEmpty ? "Check your network connection and try again" : "Try a different search term"
    }

    private var headphoneList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                let headphones = filteredHeadphones

                if headphones.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text(searchText.isEmpty ? "No AutoEQ headphones available" : "No headphones found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(emptyStateHint)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(headphones) { headphone in
                        headphoneRow(headphone)
                    }
                }
            }
        }
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
    }

    private func headphoneRow(_ headphone: AutoEQHeadphone) -> some View {
        HStack(spacing: 8) {
            Button {
                selectedHeadphone = headphone
                applyAutoEQ(headphone)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(headphone.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)

                        HStack(spacing: 4) {
                            Text(headphone.displayType)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text("•")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(headphone.sourceDisplayName)
                                .font(.system(size: 10))
                                .foregroundColor(.orange.opacity(0.8))
                        }
                    }

                    Spacer()

                    if selectedHeadphone?.id == headphone.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(selectedHeadphone?.id == headphone.id ? Color.accentColor.opacity(0.1) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to apply \(headphone.name) correction curve")

            Button {
                autoEQManager.toggleFavorite(headphone)
            } label: {
                Image(systemName: autoEQManager.isFavorite(headphone) ? "star.fill" : "star")
                    .foregroundColor(autoEQManager.isFavorite(headphone) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help(autoEQManager.isFavorite(headphone) ? "Remove favorite" : "Add favorite")
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .help("Close without applying changes")

            Spacer()

            if selectedHeadphone != nil {
                Text("Applied: \(selectedHeadphone!.name)")
                    .font(.caption)
                    .foregroundColor(.green)
                    .help("Currently applied headphone correction")
            }

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .help("Close and keep applied EQ settings")
        }
    }

    private func applyAutoEQ(_ headphone: AutoEQHeadphone) {
        autoEQManager.fetchEQ(for: headphone) { result in
            switch result {
            case .success(let curve):
                if let importedBands = curve.parametricBands, !importedBands.isEmpty {
                    eqModel.applyImportedBands(importedBands, preGain: curve.preGain)
                } else {
                    eqModel.applyImportedBands(EQBand.tenBand(withGains: curve.bands), preGain: curve.preGain)
                }
            case .failure:
                selectedHeadphone = nil
            }
        }
    }
}

#Preview {
    AutoEQView()
        .environmentObject(EQModel())
}
