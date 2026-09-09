//
//  ContentView.swift
//  Dynamic Island
//
//  Created by 雪穗子 on 1/7/2026.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        IslandView(viewModel: .preview())
    }
}

#Preview {
    ContentView()
        .frame(width: 520, height: 240)
        .padding()
}
