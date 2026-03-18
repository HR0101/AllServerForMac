import SwiftUI

// ===================================
//  StorageManagerView.swift (究極の調査・自動クリーンアップ対応版)
// ===================================

struct StorageManagerView: View {
    @ObservedObject var dataManager: VideoDataManager
    @Environment(\.dismiss) var dismiss
    
    @State private var videosSize: Int64 = 0
    @State private var proxiesSize: Int64 = 0
    @State private var downloadsSize: Int64 = 0
    @State private var appTotalSize: Int64 = 0
    
    @State private var isOptimizing = false
    @State private var optimizationMessage = ""
    
    @State private var showingResultAlert = false
    @State private var resultMessage = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("究極のストレージ調査＆クリーンアップ")
                .font(.title2.bold())
                .padding(.top)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("このアプリがMac内に保存している実際のデータ容量です。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Divider()
                
                HStack {
                    Text("① 隠しフォルダのデータ:")
                    Spacer()
                    Text(formatBytes(videosSize))
                        .fontWeight(.semibold)
                }
                
                HStack {
                    Text("② 軽量版（プロキシ）動画:")
                    Spacer()
                    Text(formatBytes(proxiesSize))
                        .fontWeight(.semibold)
                }
                
                HStack {
                    Text("③ 退避された元動画:")
                        .foregroundColor(.orange)
                    Spacer()
                    Text(formatBytes(downloadsSize))
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
                
                Divider()
                
                HStack {
                    Text("【重要】アプリの総使用容量:")
                        .font(.headline)
                    Spacer()
                    Text(formatBytes(appTotalSize))
                        .font(.title3.bold())
                        .foregroundColor(appTotalSize > 10_000_000_000 ? .red : .primary)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            
            if isOptimizing {
                VStack {
                    ProgressView()
                    Text(optimizationMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
                .frame(height: 180)
            } else {
                VStack(spacing: 12) {
                    
                    // ★ 新機能：中身が同じ重複動画を自動で一掃するボタン
                    Button(action: removeDuplicates) {
                        Text("内容が完全に一致する重複動画を自動削除する（タイトル違いも認識）")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.blue)
                    }
                    .controlSize(.large)
                    
                    Button(action: {
                        dataManager.openAppRootFolderInFinder()
                    }) {
                        Text("このアプリの全データフォルダをFinderで開く")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    
                    Button(action: {
                        dataManager.openTempFolderInFinder()
                    }) {
                        Text("Macの裏の一時フォルダ（キャッシュ）をFinderで開く")
                            .frame(maxWidth: .infinity)
                            .foregroundColor(.red)
                    }
                    .controlSize(.large)
                }
                .frame(height: 150)
            }
            
            HStack {
                Text("※青いボタンを押すと、タイトルが違っても中身が同じ動画が自動で整理されます。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("閉じる") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top)
        }
        .padding()
        .frame(width: 520, height: 480)
        .onAppear(perform: calculateSizes)
        .alert("クリーンアップ完了", isPresented: $showingResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(resultMessage)
        }
    }
    
    private func calculateSizes() {
        let sizes = dataManager.getStorageUsage()
        self.videosSize = sizes.videosSize
        self.proxiesSize = sizes.proxiesSize
        self.downloadsSize = sizes.downloadsSize
        self.appTotalSize = sizes.appTotalSize
    }
    
    private func removeDuplicates() {
        isOptimizing = true
        optimizationMessage = "重複している動画を解析し、削除しています..."
        
        Task {
            let removedCount = await MainActor.run {
                dataManager.removeDuplicateVideos()
            }
            
            await MainActor.run {
                calculateSizes()
                isOptimizing = false
                resultMessage = "\(removedCount) 件の重複動画を検知し、削除しました。\n(関連するゴミファイルも同時に一掃しました)"
                showingResultAlert = true
            }
        }
    }
    
    // ★ 欠落していた formatBytes 関数を追加
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
