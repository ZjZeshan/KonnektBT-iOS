import SwiftUI
import UIKit

struct DialerView: View {
    @EnvironmentObject var appState: AppState
    @State private var dialString: String = ""
    @State private var showingAlert = false
    @State private var alertMessage = ""
    
    private let rows: [[DialButton]] = [
        [.init(main: "1", sub: ""), .init(main: "2", sub: "ABC"), .init(main: "3", sub: "DEF")],
        [.init(main: "4", sub: "GHI"), .init(main: "5", sub: "JKL"), .init(main: "6", sub: "MNO")],
        [.init(main: "7", sub: "PQRS"), .init(main: "8", sub: "TUV"), .init(main: "9", sub: "WXYZ")],
        [.init(main: "*", sub: ""), .init(main: "0", sub: "+"), .init(main: "#", sub: "")]
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#0a0c10").ignoresSafeArea()
                VStack(spacing: 24) {
                    Text(dialString.isEmpty ? "Enter number" : dialString)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.top, 40)
                        .padding(.horizontal)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    VStack(spacing: 18) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 18) {
                                ForEach(row) { button in
                                    Button {
                                        tapHaptic()
                                        append(button.main)
                                    } label: {
                                        DialerButtonView(button: button)
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: 40) {
                        Button {
                            deleteDigit()
                            tapHaptic()
                        } label: {
                            Image(systemName: "delete.left")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white.opacity(dialString.isEmpty ? 0.3 : 1))
                        }
                        Button(action: placeCall) {
                            Circle()
                                .fill(appState.bridge.isConnected ? Color(hex: "#00e5a0") : Color.gray)
                                .frame(width: 78, height: 78)
                                .overlay(
                                    Image(systemName: "phone.fill")
                                        .font(.system(size: 32, weight: .bold))
                                        .foregroundColor(.black)
                                )
                        }
                        .disabled(!canCall)
                        Spacer().frame(width: 44)
                    }
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Dialer")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Call Failed", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
        }
    }
    
    private var canCall: Bool {
        !dialString.isEmpty && appState.bridge.isConnected
    }
    
    private func append(_ digit: String) {
        dialString.append(contentsOf: digit)
    }
    
    private func deleteDigit() {
        guard !dialString.isEmpty else { return }
        dialString.removeLast()
    }
    
    private func placeCall() {
        guard canCall else {
            alertMessage = appState.bridge.isConnected ? "Enter a number" : "Connect to Android first"
            showingAlert = true
            return
        }
        tapHaptic(strong: true)
        appState.bridge.startOutgoingCall(number: dialString)
    }
    
    private func tapHaptic(strong: Bool = false) {
        let generator = strong ? UIImpactFeedbackGenerator(style: .heavy) : UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }
}

private struct DialButton: Identifiable {
    let id = UUID()
    let main: String
    let sub: String
}

private struct DialerButtonView: View {
    let button: DialButton
    var body: some View {
        Circle()
            .fill(Color(hex: "#12151c"))
            .frame(width: 78, height: 78)
            .overlay(
                VStack(spacing: 2) {
                    Text(button.main)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    if !button.sub.isEmpty {
                        Text(button.sub)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.gray)
                    }
                }
            )
    }
}
