//
//  MainViewController.swift
//  MetalSplat
//
//  Created by CC Laan on 9/16/23.
//

import Foundation
import UIKit
import SwiftUI

import SwiftUI

struct CustomRoundedRectangle: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

struct SplatChoiceView: View {
    @State private var isMicActive = false
    @State private var isMicLowResActive = false
    @State private var isLegoActive = false
    @State private var isCoser = false
    @State private var isAddActive = false
    @State private var isRefreshing = false
    @State private var showNewView = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.edgesIgnoringSafeArea(.all)
                
                Color.blue
                    .frame(height: 40)
                    .edgesIgnoringSafeArea(.top)
                
                ScrollView {
                    let columns = [
                        GridItem(.flexible()), // 定义两列
                        GridItem(.flexible())
                    ]
                    
//                    let spacing: CGFloat = 20  // 根据实际间距调整
                    let columnSpacing: CGFloat = 2
                    let rowSpacing: CGFloat = 2
//                    let totalSpacing = spacing * CGFloat(columns.count - 1)
                    let totalSpacing = columnSpacing * CGFloat(columns.count - 1)
                    let screenWidth = geometry.size.width
                    let imageWidth = (screenWidth - totalSpacing) / CGFloat(columns.count) - rowSpacing
                    let images = [
                        (name: "cover2", description: "boxing"),
                    ]
                    LazyVGrid(columns: columns, spacing: rowSpacing) {
                        ForEach(images, id: \.name) { item in
                            VStack(spacing: 0) {
                                Image(item.name)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: imageWidth)
                                //                                .border(Color.black, width: 2)
                                VStack {
                                    Text(item.description) // 图片下的文字
                                        .frame(width: imageWidth, height: 30)
                                        .multilineTextAlignment(.center)
                                        .bold()
                                        .padding(.top, 4)
                                }
                                .background(Color(red: 0.1765, green: 1.0, blue: 0.84706))
                                .clipShape(CustomRoundedRectangle(radius: 15, corners: [.bottomLeft, .bottomRight]))
                                .padding(.top, -30)
                            }
                            .background(Color.white)
                            .cornerRadius(15)
                            .shadow(radius: 5)
                            .padding(.bottom, 10)
                            .onTapGesture {
                                switch item.name {
                                case "cover2":
                                    self.isMicLowResActive = true
                                default:
                                    break
                                }
                            }
                            
                        }
                    }
                }
                .padding(.top, 30)
                .frame(maxWidth: .infinity)
                .refreshable {
                    await refreshAction()
                }
            }
        }
        .fullScreenCover(isPresented: $isMicLowResActive) {
            SplatSimpleView(model: Models.MicLowRes, index: 1)
        }
    }
    func refreshAction() async {
        // 显示正在刷新的状态
        isRefreshing = true
        do {
            try await Task.sleep(nanoseconds: 3_000_000_000)
        } catch {
            print("Sleep was interrupted: \(error)")
        }
    }
}


class MainViewController : UIViewController {
    
    override func viewDidAppear(_ animated: Bool) {
        
        let view = SplatChoiceView()
        let host = UIHostingController(rootView: view)
        host.modalPresentationStyle = .fullScreen
        
        self.present(host, animated: false)
        
    }
}
