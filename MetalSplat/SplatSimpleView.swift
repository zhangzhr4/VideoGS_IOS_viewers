//
//  SplatSimpleView.swift
//  MetalSplat
//
//  Created by CC Laan on 9/15/23.
//

import SwiftUI
import UIKit

import Metal
import MetalKit

import Forge
import Satin
import SatinCore

func loadAndExtractData(from startIndex: Int, to endIndex: Int, dataIndex: Int) -> [[Double]] {
    var minmaxPath = ""
    if dataIndex == 1 {
        minmaxPath = "viewer_min_max_ykx_380"
    }
    else {
        minmaxPath = "viewer_min_max"
    }
    guard let url = Bundle.main.url(forResource: minmaxPath, withExtension: "json") else {
        print("JSON file not found")
        return []
    }

    do {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let jsonData = try decoder.decode(Root.self, from: data)

        var allExtractedValues = [[Double]]()

        for index in startIndex...endIndex {
            if let viewer = jsonData.viewers["\(index)"] {
                let extractedValues = extractNeededValues(info: viewer.info)
                allExtractedValues.append(extractedValues)
            } else {
                print("No viewer found for index \(index)")
            }
        }

        return allExtractedValues
    } catch {
        print("Error decoding JSON: \(error)")
        return []
    }
}

func extractNeededValues(info: [Double]) -> [Double] {
    var extractedValues = [Double]()
    
    extractedValues.append(contentsOf: info[0...5])
    
    extractedValues.append(contentsOf: info[12...17])
    
    extractedValues.append(contentsOf: info.suffix(16))
    
    return extractedValues
}

func mergeToUInt16(array1: [UInt8]?, array2: [UInt8]?) -> [Float]? {
    guard let arr1 = array1, let arr2 = array2, arr1.count == arr2.count else {
        print("One of the arrays is nil or they are not of the same length")
        return nil
    }

    var mergedArray = [Float]()
    for (byte1, byte2) in zip(arr1, arr2) {
        let merged = UInt16(byte1) | (UInt16(byte2) << 8)
        mergedArray.append(Float(merged))
    }
    return mergedArray
}

func downloadFile(from urlString: String, completion: @escaping (String?) -> Void) {
    guard let url = URL(string: urlString) else {
        print("Invalid URL")
        completion(nil)
        return
    }

    let task = URLSession.shared.downloadTask(with: url) { localURL, urlResponse, error in
        guard let localURL = localURL, error == nil else {
            print("Failed to download file: \(error?.localizedDescription ?? "No error information")")
            completion(nil)
            return
        }

        let fileManager = FileManager.default
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinationURL = documentsPath.appendingPathComponent(url.lastPathComponent)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: localURL, to: destinationURL)
            completion(destinationURL.path)
        } catch {
            print("File move error: \(error.localizedDescription)")
            completion(nil)
        }
    }

    task.resume()
}

func getDocumentsDirectory() -> URL {
    let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
    return paths[0]
}

func listFilesInDocumentsDirectory() -> [String] {
    let fileManager = FileManager.default
    let documentsURL = getDocumentsDirectory()
    do {
        let fileURLs = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil)
        return fileURLs.map { $0.lastPathComponent }
    } catch {
        print("Error while enumerating files \(documentsURL.path): \(error.localizedDescription)")
        return []
    }
}

func extractFirstFrames(from videosFrames: [[UIImage]], at frameIndex: Int) -> [[Float]] {
    var firstFrames = [Any]()
    
    var finalFrame = [[Float]]()

    for (index, frames) in videosFrames.enumerated() {
        
        guard frameIndex < frames.count else {
            print("Index \(frameIndex) out of range for video at index \(index)")
            continue
        }
        let frame = frames[frameIndex]
        
        guard let currentFrameData = imageToUInt8Array(image: frame) else {
            print("Failed to convert image to UInt8 array for video at index \(index)")
            continue
        }

        if index == 1 || index == 3 || index == 5 {
            if let previousFrameData = firstFrames.last as? [UInt8] {
                guard let mergedFrame = mergeToUInt16(array1: previousFrameData, array2: currentFrameData) else {
                    print("Failed to merge frames at index \(index)")
                    continue
                }
                firstFrames.removeLast()
                finalFrame.append(mergedFrame)
            } else {
                print("Expected UInt8 array for merging, found something else.")
                continue
            }
        } else if index == 0 || index == 2 || index == 4 {
            firstFrames.append(currentFrameData)
        } else {
            let currentFrameFloats = currentFrameData.map { Float($0) }
            finalFrame.append(currentFrameFloats)
        }
    }
    return finalFrame
}

func imageToUInt8Array(image: UIImage) -> [UInt8]? {
    guard let cgImage = image.cgImage else {
        print("Can't create CGImage from UIImage")
        return nil
    }

    let width = cgImage.width
    let height = cgImage.height
    let colorSpace = CGColorSpaceCreateDeviceGray()

    let bytesPerPixel = 1
    let bitsPerComponent = 8
    let bytesPerRow = bytesPerPixel * width
    let bitmapInfo = CGImageAlphaInfo.none.rawValue

    var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    guard let context = CGContext(data: &rawData, width: width, height: height, bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo) else {
        print("Failed to create CGContext")
        return nil
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    return rawData
}

struct Root: Codable {
    var viewers: [String: Viewer]

    struct Viewer: Codable {
        let num: Int
        let info: [Double]
    }
    
    struct DynamicCodingKeys: CodingKey {
        var stringValue: String
        var intValue: Int? = nil
        
        init?(stringValue: String) {
            self.stringValue = stringValue
        }
        
        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
        
        static func key(for string: String) -> DynamicCodingKeys? {
            return DynamicCodingKeys(stringValue: string)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var tempViewers = [String: Viewer]()
        
        for key in container.allKeys {
            let viewer = try container.decode(Viewer.self, forKey: key)
            tempViewers[key.stringValue] = viewer
        }
        
        viewers = tempViewers
    }
}


class VideoProcessor {
    var urls = ["0.mp4", "1.mp4", "2.mp4", "3.mp4", "4.mp4", "5.mp4", "9.mp4", "10.mp4", "11.mp4", "12.mp4", "13.mp4", "14.mp4", "15.mp4", "16.mp4", "17.mp4", "18.mp4", "19.mp4"]
//    func processVideos(groupIndex ind: Int, dataIndex: Int) -> [[UIImage]] {
//        var allImages: [[UIImage]] = []
//        let fileManager = FileManager.default
//        
//        var urlpath = ""
//
//        if dataIndex == 1 {
//            urlpath = "ykx_boxing_long_qp15"
//        }
//        else {
//            urlpath = "jywq_qp15"
//        }
//
//        for i in 0..<17 {
//            let frameRate = 25
//            let videoURL = "http://10.15.89.67:10000/\(urlpath)/group\(ind)/\(urls[i])"
//            print(videoURL)
//            let semaphore = DispatchSemaphore(value: 0)
//            var filepath: String?
//
//            downloadFile(from: videoURL) { downloadedFilePath in
//                filepath = downloadedFilePath
//                semaphore.signal()
//            }
//
//            semaphore.wait()
//
//            if let filepath = filepath {
//                print("Downloaded file path: \(filepath)")
//                let images = OpencvTest.processVideo(filepath, frameRate: frameRate) ?? []
//                allImages.append(images)
//                do {
//                    try fileManager.removeItem(atPath: filepath)
////                    print("Deleted file at: \(filepath)")
//                } catch {
////                    print("Failed to delete file: \(error)")
//                }
//            } else {
//                print("Download failed or file path not available")
//            }
//        }
////        print("filelist")
////        print(listFilesInDocumentsDirectory())
//
//        return allImages
//    }
    
    func processVideos(groupIndex ind: Int, dataIndex: Int) -> [[UIImage]] {
        var allImages: [[UIImage]] = []
        var urlpath = ""
        
        if dataIndex == 1 {
            urlpath = "ykx_boxing_long_qp15_380"
//            urlpath = "0508"
        }
        else {
            urlpath = "coser18_qp0_new"
        }

        for i in 0..<17 {
            let frameRate = 25
            let videoURL = "\(urlpath)/group\(ind)/\(urls[i])"
            let images = OpencvTest.processVideo(videoURL, frameRate: frameRate) ?? []
            allImages.append(images)
        }
        return allImages
        
    }
}

class RendererProgress: ObservableObject {
    @Published var progressValue: Int = 0
}

class CameraControllerRenderer: Forge.Renderer {
    
    let model : SplatModelInfo
    
    var progress: RendererProgress
    
    var splatClouds: [SplatCloud?] = []
    
    var frameIndexList: [Int] = []
    
    var groupIndexList: [(Int, Int, Int)] = []
    
    var minmax: [[Double]] = []
    
    var operationQueue: OperationQueue
    
    var currentFrameNum: Int = 0
    
    var gridInterval: Float = 1.0
    
    var renderTime: Int = 0
    
    var keepWait: Int = 0
    
    var nowFrame: Int = 0
    
    var isPaused: Bool = false
    
    var loading: Int = 0
    
    var splatFinishNum: Int = 0
    
    var suspend: Bool = false
    
    var dataIndex: Int = 0
    
    var viewInd: Int = 0
    
    let stepInd: Int = 2
    
    var stopNum: Int = 0
    
    
    func togglePause(_ isPaused: Bool) {
        self.isPaused = isPaused
    }
    
    init(model: SplatModelInfo, progress: RendererProgress, dataIndex: Int) {
        self.model = model
        self.progress = progress
        self.dataIndex = dataIndex
        self.operationQueue = OperationQueue()
        self.operationQueue.maxConcurrentOperationCount = 1
        super.init()
    }
    
    func setupProcessingQueue() {
        for group in self.groupIndexList {
            if [0].contains(group.0)  {
                continue
            }
            operationQueue.addOperation {
                self.processGroup(group)
            }
        }
    }
    
    func setupProcessingQueueWithInd(groupInd: Int) {
//        print(groupInd)
        operationQueue.isSuspended = false
//        print(self.groupIndexList.count-1)
        for index in groupInd...self.groupIndexList.count-1 {
            operationQueue.addOperation {
                self.processGroup(self.groupIndexList[index])
            }
        }
//        print(operationQueue.operationCount)
    }
    
    func processGroup(_ group: (Int, Int, Int)) {
        let videoProcessor = VideoProcessor()
        let videosFrames = videoProcessor.processVideos(groupIndex: group.0, dataIndex: self.dataIndex)

        let dispatchGroup = DispatchGroup()

        DispatchQueue.concurrentPerform(iterations: group.2-group.1+1) { index in
            dispatchGroup.enter()
            do {
                let startTime = CFAbsoluteTimeGetCurrent()
                let splatCloud = try SplatCloud(model: self.model, renderDestination: self.mtkView, groupFrame: videosFrames, minmax: self.minmax[index+group.1], frameIndex: index, dataIndex: dataIndex)
                let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
//                print("Time elapsed for SplatCloud: \(timeElapsed) seconds.")
                splatCloud?.orientation = self.model.initialOrientation
                splatCloud?.scale = .init(repeating: self.model.initialScale)
                self.splatClouds[index+group.1] = splatCloud
            } catch {
                print("Failed to initialize SplatCloud with index \(index): \(error)")
            }
            dispatchGroup.leave()
        }

        dispatchGroup.wait()
        
        self.splatFinishNum += group.2-group.1+1
    }
    
    func selectFrame(chosenFrame: Double) {
        let frameInd = Int(chosenFrame / Double(stepInd))
        self.operationQueue.cancelAllOperations()
        self.operationQueue = OperationQueue()
        self.operationQueue.maxConcurrentOperationCount = 1
        self.splatFinishNum = 0
        self.suspend = false
        
        self.splatClouds = Array(repeating: nil, count: self.currentFrameNum)
        for group in groupIndexList {
            if frameInd >= group.1 && frameInd <= group.2 {
                processGroup(group)
                keepWait = 0
                let splatBefore = scene.children.last
                scene.remove(splatBefore!)
                if group.0 != self.groupIndexList.count-1 {
                    self.setupProcessingQueueWithInd(groupInd: group.0+1)
                }
                
                break
            }
        }
    }
    lazy var scene = Object("Scene", [])
    
    lazy var context: Context = .init(device, sampleCount, colorPixelFormat, depthPixelFormat, stencilPixelFormat)
    
    lazy var camera: PerspectiveCamera = {
        let pos = SIMD3<Float>(10.0, 10.0, 10.0)

        let camera = PerspectiveCamera(position: pos, near: 0.01, far: 100.0)
        camera.aspect = 0.9429056
        camera.orientation = simd_quatf(real: 1.0, imag: SIMD3<Float>(0.0, 0.0, 0.0))
        camera.fov = 45.0
        camera.viewMatrix = simd_float4x4([[-0.3292983, -0.17486514, 0.9278904, 0.0], [0.92797965, -0.24143358, 0.28383055, 0.0], [0.17439224, 0.9545303, 0.24177541, -0.0], [-0.18122181, 0.18167843, -0.97597855, 1.0000001]])
        camera.worldPosition = SIMD3<Float>(0.8776981, 0.48904794, 0.09415415)
        camera.projectionMatrix = simd_float4x4([[2.5603979, 0.0, 0.0, 0.0], [0.0, 2.4142134, 0.0, 0.0], [0.0, 0.0, 0.000100016594, -1.0], [0.0, 0.0, 0.010001, 0.0]])
        camera.scale = SIMD3<Float>(1.0000015, 1.0000017, 1.0000018)
        camera.localMatrix = simd_float4x4([[1.0000015, 0.0, 0.0, 0.0], [0.0, 1.0000017, 0.0, 0.0], [0.0, 0.0, 1.0000018, 0.0], [0.0, 0.0, 0.9759802, 1.0]])
        camera.worldMatrix = simd_float4x4([[-0.32929954, 0.92798316, 0.1743929, 0.0], [-0.17486589, -0.24143456, 0.9545341, 0.0], [0.9278944, 0.28383178, 0.24177642, 0.0], [0.8776981, 0.48904794, 0.09415415, 1.0]])
        camera.worldOrientation = simd_quatf(real: 0.409586, imag: SIMD3<Float>(0.40937737, 0.45991546, 0.67314726))

        return camera
    }()


    lazy var cameraController: PerspectiveCameraController = .init(camera: camera, view: mtkView)
    lazy var renderer: Satin.Renderer = .init(context: context)

    override func setupMtkView(_ metalKitView: MTKView) {
        
        metalKitView.depthStencilPixelFormat = .invalid
                
        metalKitView.backgroundColor = UIColor.white
        metalKitView.autoResizeDrawable = true
        metalKitView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
        metalKitView.preferredFramesPerSecond = 60
        
        metalKitView.drawableSize = mtkView.drawableSize.applying(
            CGAffineTransform(scaleX: 1.0 / CGFloat(model.rendererDownsample),
                                   y: 1.0 / CGFloat(model.rendererDownsample))
        )
        print("Drawble size; ", mtkView.drawableSize )
        
        renderer.clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
        var group_info_path = ""
        
        if self.dataIndex == 1 {
            group_info_path = "group_info_ykx_380"
//            group_info_path = "group_info_0508"
        }
        else {
            group_info_path = "group_info"
        }
        guard let url = Bundle.main.url(forResource: group_info_path, withExtension: "json") else {
            print("JSON file not found")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            
            if let jsonObject = try JSONSerialization.jsonObject(with: data, options: []) as? [String: [String: Any]],
               !jsonObject.isEmpty {
                let frameIndexes: [(Int, Int, Int)] = jsonObject
                    .sorted(by: { Int($0.key) ?? 0 < Int($1.key) ?? 0 })
                    .compactMap { key, value in
                        if let frameIndex = value["frame_index"] as? [Int], frameIndex.count == 2,
                        let keyInt = Int(key) {
                            return (keyInt, frameIndex[0], frameIndex[1])
                        }
                        return nil
                    }
                
                self.groupIndexList = frameIndexes
                
                print("Extracted frame indexes in order: \(frameIndexes)")
            } else {
                print("Failed to cast JSON or JSON is empty")
            }
        } catch {
            print("An error occurred: \(error)")
        }
//        print(self.groupIndexList)
        
        if dataIndex == 1 {
            stopNum = 100
        }
        else {
            stopNum = 220
        }
        
        self.currentFrameNum = groupIndexList.last!.2 + 1
        self.frameIndexList = Array(repeating: 0, count: self.currentFrameNum)
        print(frameIndexList.count)
        
        self.splatClouds = Array(repeating: nil, count: self.currentFrameNum)
        
        let videoProcessor = VideoProcessor()
        self.minmax = loadAndExtractData(from: 0, to: currentFrameNum-1, dataIndex: self.dataIndex)
        for i in 0..<1 {
            var group = groupIndexList[i]
            let videosFrames = videoProcessor.processVideos(groupIndex: group.0, dataIndex: self.dataIndex)
            
            let dispatchGroup = DispatchGroup()
            
            DispatchQueue.concurrentPerform(iterations: group.2-group.1+1) { index in
                dispatchGroup.enter()
                do {
                    let startTime = CFAbsoluteTimeGetCurrent()
                    let splatCloud = try SplatCloud(model: self.model, renderDestination: self.mtkView, groupFrame: videosFrames, minmax: self.minmax[index+group.1], frameIndex: index, dataIndex: dataIndex)
                    let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
                    print("Time elapsed for SplatCloud: \(timeElapsed) seconds.")
                    splatCloud?.orientation = model.initialOrientation
                    splatCloud?.scale = .init(repeating: model.initialScale)
                    self.splatClouds[index+group.1] = splatCloud!
                } catch {
                    print("Failed to initialize SplatCloud with index \(index): \(error)")
                }
                dispatchGroup.leave()
            }
            self.splatFinishNum += group.2-group.1+1
        }
        self.setupProcessingQueue()
    }

    override func setup() {
        
        print("set up")
        
        scene.attach(cameraController.target)
                
        if !self.splatClouds.isEmpty {
            let firstSplatCloud = self.splatClouds[0]!
            scene.add(firstSplatCloud)
        }
    }

    deinit {
        cameraController.disable()
    }

    override func update() {
        cameraController.update()
    }

    override func draw(_ view: MTKView, _ commandBuffer: MTLCommandBuffer) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0)
        renderer.draw(
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer,
            scene: scene,
            camera: camera
        )

        if self.progress.progressValue == (currentFrameNum -  1)*stepInd {
            self.keepWait = 1
            selectFrame(chosenFrame: 0)
            self.progress.progressValue = 0
        }

        if self.splatFinishNum > stopNum && self.suspend == false {
            self.suspend = true
            self.operationQueue.isSuspended = true
        }
        else if self.splatFinishNum < stopNum && self.suspend == true {
            self.suspend = false
            self.operationQueue.isSuspended = false
        }
        if !isPaused && (keepWait == 0) {
            progress.progressValue += 1
            if progress.progressValue == stepInd * currentFrameNum {
                progress.progressValue -= 1
            }
            else if progress.progressValue % stepInd == 0 {
                if self.splatClouds[progress.progressValue / stepInd] != nil {
                    let newSplatCloud = self.splatClouds[progress.progressValue / stepInd]!
                    if progress.progressValue != 0 {
                        scene.remove(self.splatClouds[progress.progressValue / stepInd - 1]!)
                        if self.splatClouds[progress.progressValue / stepInd - 1] != nil {
                            self.splatClouds[progress.progressValue / stepInd - 1] = nil
                        }
                    }
                    self.splatFinishNum -= 1
                    scene.add(newSplatCloud)
                }
                else {
                    progress.progressValue -= 1
                }
            }
        }
        
    }

    override func resize(_ size: (width: Float, height: Float)) {
        camera.aspect = size.width / size.height
        renderer.resize(size)
    }
}


class FPSCounter: ObservableObject {
    private var lastTime: TimeInterval = 0
    private var frameCount = 0
    @Published var fps: Int = 0

    private var displayLink: CADisplayLink?

    init() {
        displayLink = CADisplayLink(target: self, selector: #selector(update(link:)))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func update(link: CADisplayLink) {
        if lastTime == 0 {
            lastTime = link.timestamp
            return
        }

        frameCount += 1
        let elapsed = link.timestamp - lastTime

        if elapsed >= 1 {
            fps = Int(Double(frameCount) / elapsed)
            frameCount = 0
            lastTime = link.timestamp
        }
    }

    deinit {
        displayLink?.invalidate()
    }
}

struct SplatSimpleView: View {
    @SwiftUI.Environment(\.presentationMode) var presentationMode: Binding<PresentationMode>
    let model : SplatModelInfo
    let index : Int
    @StateObject var progress: RendererProgress = RendererProgress()
    @State private var renderer: CameraControllerRenderer?
    @State private var isPaused = false
    @State private var sliderValue: Double = 0
    @StateObject private var fpsCounter = FPSCounter()
    @State private var timer: Timer?
    
    var body: some View {
        VStack {
            HStack {
                Button(action: {
                    renderer?.operationQueue.cancelAllOperations()
                    self.presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "arrow.left")
                        .foregroundColor(.black)
                        .bold()
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .clipShape(Circle())
                }
                Spacer()
                Text("FPS: \(fpsCounter.fps)")
                    .foregroundColor(.blue)
                    .padding(.trailing)
                    .bold()
                    .font(.system(size: 32))
            }
            .padding()

            if let renderer = renderer {
                ForgeView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                Text("Initializing...")
            }
            
            Slider(value: $sliderValue, in: 0...sliderRange(for: index), onEditingChanged: sliderEditingChanged)
                .accentColor(.black)
                .padding()
                .background(Color.white)
                .onChange(of: progress.progressValue) { newValue in
                    sliderValue = Double(newValue)
                }

            Button(action: {
                isPaused.toggle()
                renderer?.togglePause(isPaused)
            }) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.largeTitle)
                    .foregroundColor(.black)
            }
            .buttonStyle(PlainButtonStyle())
            .padding()
            .background(Color.white)
        }
        .background(Color.white)
        .onAppear {
            sliderValue = Double(progress.progressValue / 2)
            if renderer == nil {
                renderer = CameraControllerRenderer(model: model, progress: progress, dataIndex: index)
            }
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }
        
    
    private func sliderEditingChanged(_ isEditing: Bool) {
        if !isEditing {
            renderer?.nowFrame = progress.progressValue
            progress.progressValue = Int(sliderValue)
            renderer?.keepWait = 1
            renderer?.selectFrame(chosenFrame: sliderValue)
        }
    }
    func sliderRange(for index: Int) -> Double {
        switch index {
        case 1:
            return 630 * 2
        default:
            return 885 * 2
        }
    }
    
    private func startTimer() {

        }

        private func stopTimer() {
            timer?.invalidate()
            timer = nil
        }
}
