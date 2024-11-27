//
//  SplatCloud.swift
//  MetalSplat
//
//  Created by CC Laan on 9/14/23.
//

import Foundation
import Metal
import MetalKit
import Satin
import SatinCore
import UIKit



protocol RenderDestinationProvider {
    var currentRenderPassDescriptor: MTLRenderPassDescriptor? { get }
    var currentDrawable: CAMetalDrawable? { get }
    var colorPixelFormat: MTLPixelFormat { get set }
    var depthStencilPixelFormat: MTLPixelFormat { get set }
    var sampleCount: Int { get set }
}

extension MTKView: RenderDestinationProvider {
    
}


enum SplatError: Error {
    case deviceCreationFailed
    case plyParsingFailed
    case plyNonFloatPropertyFound
}

func grayPixelValue(in image: UIImage, at x: Int, y: Int) -> UInt8? {
    guard let cgImage = image.cgImage, x >= 0, y >= 0, x < cgImage.width, y < cgImage.height else {
        return nil
    }
    
    let dataProvider = cgImage.dataProvider!
    let data = dataProvider.data!
    let ptr = CFDataGetBytePtr(data)
    
    let pixelInfo = (cgImage.width * y) + x
    let pixelValue = ptr?[pixelInfo]
    return pixelValue
}

func areImagesPixelIdentical(image1: UIImage, image2: UIImage) -> Bool {
    guard let cgImage1 = image1.cgImage, let cgImage2 = image2.cgImage,
          cgImage1.width == cgImage2.width, cgImage1.height == cgImage2.height else {
        return false
    }

    let width = cgImage1.width
    let height = cgImage1.height
    let colorSpace = CGColorSpaceCreateDeviceRGB()

    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    let bitsPerComponent = 8

    var pixels1 = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    var pixels2 = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    guard let context1 = CGContext(data: &pixels1,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: bitsPerComponent,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let context2 = CGContext(data: &pixels2,
                                   width: width,
                                   height: height,
                                   bitsPerComponent: bitsPerComponent,
                                   bytesPerRow: bytesPerRow,
                                   space: colorSpace,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return false
    }

    context1.draw(cgImage1, in: CGRect(x: 0, y: 0, width: width, height: height))
    context2.draw(cgImage2, in: CGRect(x: 0, y: 0, width: width, height: height))

    return memcmp(pixels1, pixels2, pixels1.count * MemoryLayout<UInt8>.size) == 0
}

func printVideosFramesShape(videosFrames: [[UIImage]]) {
    var shapes = [(Int, Int)]()
    for frames in videosFrames {
        let numFrames = frames.count
        shapes.append((1, numFrames))
    }

    for (index, shape) in shapes.enumerated() {
        print("Video \(index + 1): \(shape.1) frames")
    }
}

func printDequantizedDataShape(dequantizedData: [[Double]]) {
    print("Total number of frames: \(dequantizedData.count)")
    for (index, frameData) in dequantizedData.enumerated() {
        print("Frame \(index): Type Double, Length \(frameData.count)")
    }
}

func dequantizeFrames(_ firstFrames: [Any], with minMaxArray: [Double]) -> [[Float]] {
    var dequantizedFrames = [[Float]]()

    for (index, frame) in firstFrames.enumerated() {
        guard minMaxArray.count > index * 2 + 1 else {
            print("Error: Insufficient min/max values for frame at index \(index).")
            continue
        }

        let minValue = Float(minMaxArray[index * 2])
        let maxValue = Float(minMaxArray[index * 2 + 1])
        var dequantizedData = [Float]()
        
        if let frameData = frame as? [Float] {
            if [0, 1, 2].contains(index) {
                let scale = (maxValue - minValue) / 65535.0
                dequantizedData = frameData.map { $0 * scale + minValue }
            } else {
                let scale = (maxValue - minValue) / 255.0
                dequantizedData = frameData.map { $0 * scale + minValue }
            }
        }


        dequantizedFrames.append(dequantizedData)
    }

    return dequantizedFrames
}

class SplatCloud : Object, Renderable {
    
    
    var splats : MetalBuffer<Splat>
    var temp_splats : MetalBuffer<Splat>
    var splat_indices : MetalBuffer<Int64>
    
    var numPoints : Int {
        return splats.count
    }
    
    private let device : MTLDevice
    private let library: MTLLibrary
    
    private let quadBuffer : MetalBuffer<packed_float2>
    
    
    private var pipelineState: MTLRenderPipelineState!
    private var depthState: MTLDepthStencilState!
    
    private var uniforms : Uniforms = Uniforms()

    private var commandQueue: MTLCommandQueue!
    private var computePipelineState: MTLComputePipelineState!
    private var isSorting = false
    
    private var generateSplatPipelineState: MTLComputePipelineState!
    
    private var frame_index : Int = 0
    
    private var dataIndex : Int = 0
    
    // MARK: PLY Init
        
    init?(model : SplatModelInfo, renderDestination : RenderDestinationProvider, groupFrame : [[UIImage]], minmax : [Double], frameIndex : Int, dataIndex: Int) throws {
                
        guard let device = MTLCreateSystemDefaultDevice(),
              let library = device.makeDefaultLibrary() else {
            throw SplatError.deviceCreationFailed
        }
        
        self.device = device
        self.library = library
        self.dataIndex = dataIndex
        
        let minmaxFloat = minmax.map { Float($0) }
        let minmaxBufferSize = minmaxFloat.count * MemoryLayout<Float>.size
        guard let minmaxBuffer = device.makeBuffer(bytes: minmaxFloat, length: minmaxBufferSize, options: .storageModeShared) else {
            fatalError("Unable to create buffer")
        }
        
        var init_pos = [Float(1.0), Float(-0.6), Float(0.5)]
        if dataIndex == 4 {
            init_pos = [Float(1.0), Float(-0.6), Float(0.5)]
        }
        else if dataIndex == 2 {
            init_pos = [Float(0.0), Float(-0.6), Float(-0.3)]
        }
        else {
            init_pos = [Float(0.0), Float(-0.6), Float(0.5)]
        }
        let initPosBufferSize = init_pos.count * MemoryLayout<Float>.size
        guard let initPosBuffer = device.makeBuffer(bytes: init_pos, length: initPosBufferSize, options: .storageModeShared) else {
            fatalError("Unable to create buffer")
        }
                        
        assert(FileManager.default.fileExists(atPath: model.plyUrl.path ))
        
        // Read header
        
        struct VertexData {
            
            var x: Float
            var y: Float
            var z: Float
            
            
            var opacity: Float
            var scale_0: Float
            
            var scale_1: Float
            var scale_2: Float
            
            var rot_0: Float
            var rot_1: Float
            var rot_2: Float
            var rot_3: Float
            
            // SH0
            var f_dc_0: Float
            var f_dc_1: Float
            var f_dc_2: Float
            
            // SH1
            var f_rest_0 : Float = 0.0
            var f_rest_1 : Float = 0.0
            var f_rest_2 : Float = 0.0
            var f_rest_3 : Float = 0.0
            var f_rest_4 : Float = 0.0
            var f_rest_5 : Float = 0.0
            var f_rest_6 : Float = 0.0
            var f_rest_7 : Float = 0.0
            var f_rest_8 : Float = 0.0
            
        }
        
        
        func createPoints(from finalArray: [[Float]]) -> [VertexData] {
            var points = [VertexData]()

            guard finalArray.count >= 14,
                  let count = finalArray.first?.count else {
                print("Invalid data structure in finalArray")
                return []
            }

            for i in 0..<count {
                let point = VertexData(
                    x: Float(finalArray[0][i]),
                    y: Float(finalArray[1][i]),
                    z: Float(finalArray[2][i]),
                    opacity: Float(finalArray[6][i]),
                    scale_0: Float(finalArray[7][i]),
                    scale_1: Float(finalArray[8][i]),
                    scale_2: Float(finalArray[9][i]),
                    rot_0: Float(finalArray[10][i]),
                    rot_1: Float(finalArray[11][i]),
                    rot_2: Float(finalArray[12][i]),
                    rot_3: Float(finalArray[13][i]),
                    f_dc_0: Float(finalArray[3][i]),
                    f_dc_1: Float(finalArray[4][i]),
                    f_dc_2: Float(finalArray[5][i])
                )
                
                let center = SIMD3<Float>(point.x, point.y, point.z)
                let dist = simd_length(center)
                
                if model.clipOutsideRadius > 0.001 && dist > model.clipOutsideRadius {
                    continue
                }

                if model.randomDownsample > 0.0 && Float.random(in: 0.0...1.0) > model.randomDownsample {
                    continue
                }

                points.append(point)
            }

            return points
        }
        
        func arrayToTexture(device: MTLDevice, array: [Float], width: Int, height: Int) -> MTLTexture? {
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: width,
                height: height,
                mipmapped: false
            )
            
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                return nil
            }
            
            let bytesPerRow = width * MemoryLayout<Float>.size
            let region = MTLRegionMake2D(0, 0, width, height)
            array.withUnsafeBytes { bufferPointer in
                texture.replace(region: region, mipmapLevel: 0, withBytes: bufferPointer.baseAddress!, bytesPerRow: bytesPerRow)
            }
            
            return texture
        }
        
        func imageToTexture(device: MTLDevice, image: UIImage) -> MTLTexture? {
            guard let cgImage = image.cgImage else { return nil }
                
            let width = cgImage.width
            let height = cgImage.height
            
            // 单通道灰度图的设置
            let colorSpace = CGColorSpaceCreateDeviceGray()
            let bytesPerPixel = 1  // 灰度图每像素1字节
            let bytesPerRow = width * bytesPerPixel
            let bitsPerComponent = 8
            
            var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
            let bitmapInfo = CGImageAlphaInfo.none.rawValue
            
            guard let context = CGContext(data: &rawData,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: bitsPerComponent,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else { return nil }
            
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            
            guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
            
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: rawData,
                            bytesPerRow: bytesPerRow)
            
            return texture
        }
        
        func createDFTexture(device: MTLDevice, image: UIImage) throws -> MTLTexture? {
            guard let cgImage = image.cgImage else {
                print("nil")
                return nil
            }

            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: cgImage.width,
                height: cgImage.height,
                mipmapped: false
            )
            textureDescriptor.usage = [.shaderRead]

            guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
                throw NSError(domain: "TextureCreationError", code: 1, userInfo: nil)
            }

            guard let pixelData = cgImage.dataProvider?.data else {
                throw NSError(domain: "TextureCreationError", code: 2, userInfo: nil)
            }

            let data: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
            let bytesPerPixel = 4

            let bytesPerRow = cgImage.bytesPerRow
            texture.replace(
                region: MTLRegionMake2D(0, 0, cgImage.width, cgImage.height),
                mipmapLevel: 0,
                slice: 0,
                withBytes: CFDataGetBytePtr(pixelData),
                bytesPerRow: bytesPerRow,
                bytesPerImage: bytesPerRow * cgImage.height
            )

            return texture
        }
        
        let width = Int(groupFrame[0][0].cgImage!.width)
        let height = Int(groupFrame[0][0].cgImage!.height)
        let numPoints = width * height
        var textures = [MTLTexture]()
        for i in 0..<17 {
            let tex = try createDFTexture(device: device, image: groupFrame[i][frameIndex])
            textures.append(tex!)
        }
        
        var splats : MetalBuffer<Splat> = MetalBuffer(device: device,
                                                      count: numPoints,
                                                      index: UInt32(1),
                                                      label: "points",
                                                      options: MTLResourceOptions.storageModeShared )
        
        var temp_splats : MetalBuffer<Splat> = MetalBuffer(device: device,
                                       count: numPoints,
                                       index: UInt32(1),
                                       label: "points2",
                                       options: MTLResourceOptions.storageModeShared )
        
        self.temp_splats = temp_splats
        self.splats = splats

        // Index buffer
        self.splat_indices = .init(device: device,
                                   count: numPoints,
                                   index: 0,
                                   label: "indices",
                                   options: MTLResourceOptions.storageModeShared)
        
        
        
        // ========================= //
        // Make fixed quad vertices
                      
        let _quads : [packed_float2] = [  [1, -1], [1,1], [-1,-1], [-1,1] ]
        
        
        self.quadBuffer = .init(device: device,
                                array: _quads,
                                index: 0,
                                options: MTLResourceOptions.storageModePrivate )
        
        super.init()
        
        self.setupShaders(renderDestination)
        
        self.setupCompute(renderDestination)
        
        self.setGenerateSplatComputeShader(width: width, height: height, textures: textures, minmaxBuffer: minmaxBuffer, initPosBuffer: initPosBuffer)
        self.copySplats()
        
//        self.temp_splats = self.splats
        
    }
    
    required init(from decoder: Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }
    
    // Uniforms
    func updateUniforms(uniforms : Uniforms) {
        self.uniforms = uniforms
    }
    
    
    func sortSplats() {
        
        if frame_index % 4 == 0 && !isSorting {
            
            isSorting = true
            
            //let d1 = Date()
            
            // ~2 ms
            self.setSplatDepthsComputeShader()
            
            //let durComputeMs = d1.timeIntervalSinceNow * -1000.0
            
            //DispatchQueue.global(qos: .userInteractive).async {
                
            
                //let d2 = Date()
                
                self._sortSplatsCpp()
                //let durCpuMs = d2.timeIntervalSinceNow * -1000
            
                //let durTotalMs = d1.timeIntervalSinceNow * -1000.0
            
                //NSLog("Sort took %6.1f ms - shader: %.1f ms ,  std::sort %.1f ms", durTotalMs, durComputeMs, durCpuMs )
                
                
                self.isSorting = false
            
            //}
            
        }
        
        
        
    }
    
    private func _sortSplatsCpp() {
        
        sort_splats(splats.buffer.contents(),
                    temp_splats.buffer.contents(),
                    splat_indices.buffer.contents(),
                    uniforms,
                    Int32(numPoints))
            
        
    }
    
    // MARK: - Render
    
    
    func render(renderEncoder: MTLRenderCommandEncoder) {
        
        self.sortSplats()
        
        
        //renderEncoder.setCullMode(.none)
        //renderEncoder.setFrontFacing(.counterClockwise)
        
        renderEncoder.setDepthStencilState(depthState)
        renderEncoder.setRenderPipelineState(pipelineState)
                
        renderEncoder.setVertexBuffer(self.quadBuffer.buffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(self.splats.buffer, offset: 0, index: 1)
        
        
        
        
        var uni : Uniforms = self.uniforms
        renderEncoder.setVertexBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
        renderEncoder.setFragmentBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
                        
        
        renderEncoder.drawPrimitives(
                                    type: .triangleStrip,
                                    vertexStart: 0,
                                    vertexCount: self.quadBuffer.count,
                                    instanceCount: self.splats.count )

                
        frame_index += 1
        
        
    }
    
    // MARK: - Metal Setup
    
    private func setupShaders( _ renderDestination : RenderDestinationProvider ) {
        
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .always
        depthStateDescriptor.isDepthWriteEnabled = false
                
        self.depthState = device.makeDepthStencilState(descriptor: depthStateDescriptor)!
        
        self.pipelineState = makePipelineState(renderDestination)!
        
    }
    
    private func makePipelineState(_ renderDestination : RenderDestinationProvider) -> MTLRenderPipelineState? {
        
        guard let vertexFunction = library.makeFunction(name: "splat_vertex"),
            let fragmentFunction = library.makeFunction(name: "splat_fragment") else {
                return nil
        }
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        
        descriptor.depthAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        descriptor.colorAttachments[0].pixelFormat = renderDestination.colorPixelFormat
        
        //descriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        //descriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        //descriptor.stencilAttachmentPixelFormat = renderDestination.depthStencilPixelFormat
        
        
        descriptor.stencilAttachmentPixelFormat = .invalid
        
        descriptor.rasterSampleCount = renderDestination.sampleCount
        
        assert(renderDestination.sampleCount == 1)
        
        
        // =========== Blending ============= //
        descriptor.colorAttachments[0].isBlendingEnabled = true
        
//        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
//        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
//        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
//        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
//        descriptor.colorAttachments[0].sourceRGBBlendFactor = .oneMinusDestinationAlpha
//        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .oneMinusDestinationAlpha
//        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
//        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        
//        descriptor.colorAttachments[0].sourceRGBBlendFactor = .oneMinusDestinationAlpha
//        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .oneMinusDestinationAlpha
//        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
//        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        
//        descriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationAlpha
//        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
//        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .destinationAlpha
//        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
//        
        
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add

        return try? device.makeRenderPipelineState(descriptor: descriptor)
        
    }
    
    
    // MARK: - Metal Compute
    
    private func setupCompute( _ renderDestination : RenderDestinationProvider ) {
                
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue.")
        }
        self.commandQueue = commandQueue
        
        let defaultLibrary = device.makeDefaultLibrary()
        
        let computeFunction = defaultLibrary?.makeFunction(name: "splat_set_depths")
        do {
            computePipelineState = try device.makeComputePipelineState(function: computeFunction!)
        } catch {
            fatalError("Failed to create compute pipeline state.")
        }
        
        let generateSplatFunction = defaultLibrary?.makeFunction(name: "generateSplats")
        do {
            generateSplatPipelineState = try device.makeComputePipelineState(function: generateSplatFunction!)
        } catch {
            fatalError("Failed to create compute pipeline state for generateSplat.")
        }
        
    }
    
    
    private func setSplatDepthsComputeShader() {
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        computeEncoder.setComputePipelineState(computePipelineState)
        
        
        computeEncoder.setBuffer(self.splat_indices.buffer, offset: 0, index: 0)
        computeEncoder.setBuffer(self.splats.buffer, offset: 0, index: 1)
        
        var uni : Uniforms = self.uniforms
        computeEncoder.setBytes(&uni, length: MemoryLayout<Uniforms>.stride, index: 2)
                                        
        let threadPerGrid = MTLSize(width: numPoints, height: 1, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 1, height: 1, depth: 1)
        computeEncoder.dispatchThreads(threadPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        
    }
    
    private func setGenerateSplatComputeShader(width: Int, height: Int, textures: [MTLTexture], minmaxBuffer: MTLBuffer, initPosBuffer: MTLBuffer) {
        
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        computeEncoder.setComputePipelineState(generateSplatPipelineState)
        
        computeEncoder.setTexture(textures[0], index: 0)
        computeEncoder.setTexture(textures[1], index: 1)
        computeEncoder.setTexture(textures[2], index: 2)
        computeEncoder.setTexture(textures[3], index: 3)
        computeEncoder.setTexture(textures[4], index: 4)
        computeEncoder.setTexture(textures[5], index: 5)
        computeEncoder.setTexture(textures[6], index: 6)
        computeEncoder.setTexture(textures[7], index: 7)
        computeEncoder.setTexture(textures[8], index: 8)
        computeEncoder.setTexture(textures[9], index: 9)
        computeEncoder.setTexture(textures[10], index: 10)
        computeEncoder.setTexture(textures[11], index: 11)
        computeEncoder.setTexture(textures[12], index: 12)
        computeEncoder.setTexture(textures[13], index: 13)
        computeEncoder.setTexture(textures[14], index: 14)
        computeEncoder.setTexture(textures[15], index: 15)
        computeEncoder.setTexture(textures[16], index: 16)
        
        computeEncoder.setBuffer(self.splats.buffer, offset: 0, index: 0)
//        computeEncoder.setBuffer(self.minmaxArray, offset: 0, index: 0)
        computeEncoder.setBuffer(minmaxBuffer, offset: 0, index: 1)
        computeEncoder.setBuffer(initPosBuffer, offset: 0, index: 2)
        
        let threadsPerGrid = MTLSize(width: width, height: height, depth: 1)
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        
        computeEncoder.dispatchThreads(threadsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        
        computeEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
    }
    
    private func copySplats() {
        let commandBuffer: MTLCommandBuffer = commandQueue.makeCommandBuffer()!
        let blitEncoder: MTLBlitCommandEncoder = commandBuffer.makeBlitCommandEncoder()!
        blitEncoder.copy(from: self.splats.buffer,
                         sourceOffset: 0,
                         to: self.temp_splats.buffer,
                         destinationOffset: 0,
                         size: self.splats.buffer.length)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    // MARK: - Satin : Object + Renderable
        
    var renderOrder: Int {
        return 0
    }
    
    var receiveShadow: Bool {
        return false
    }
    
    var castShadow: Bool {
        return false
    }
    
    var drawable: Bool {
        return true
    }
    
    var cullMode: MTLCullMode {
        get {
            return .none
        }
        set(newValue) {
            
        }
    }
    
    var opaque: Bool {
        return true
    }
    
    //let _material = BasicColorMaterial(simd_make_float4(1.0, 1.0, 1.0, 1.0))
    
    var material: Satin.Material? {
        get {
            return nil
        }
        set(newValue) {
                
        }
    }
    
    var materials: [Satin.Material] {
        return []
    }
    
    private var dragAlpha : Float = 0.0 // tween this value
    private var _dragAlpha : Float = 0.0
    
    var isDragging : Bool = false {
        didSet {
            _dragAlpha = isDragging ? 1.0 : 0.0
        }
    }
    
    override func update(camera: Satin.Camera, viewport: simd_float4) {
        
        let modelMatrix = self.worldMatrix
        
        let modelViewMatrix = simd_mul(camera.viewMatrix, modelMatrix)
        
        let width = viewport.z
        let height = viewport.w

        // Extracting tangent of half-angles of the FoVs
        let tan_fovx = 1.0 / camera.projectionMatrix[0][0];
        let tan_fovy = 1.0 / camera.projectionMatrix[1][1];
            
        let focal_y = height / (2.0 * tan_fovy)
        let focal_x = width / (2.0 * tan_fovx)
        
        let time : Double = CACurrentMediaTime()
        
        let cameraPos = simd_float4(camera.worldPosition, 1.0)
        //let cameraPosOrig = simd_mul( cameraPos, simd_inverse(modelMatrix) );
        let cameraPosOrig = simd_mul( simd_inverse(modelMatrix) , cameraPos );
        
        let uni = Uniforms(projection_matrix: camera.projectionMatrix,
                           model_matrix: modelMatrix,
                           model_view_matrix: modelViewMatrix,
                           inv_model_view_matrix: simd_inverse(modelViewMatrix),
                           camera_pos: cameraPos,
                           camera_pos_orig: cameraPosOrig,
                           viewport_width: viewport.z,
                           viewport_height: viewport.w,
                           focal_x: focal_x,
                           focal_y: focal_y,
                           tan_fovx: tan_fovx,
                           tan_fovy: tan_fovy,
                           drag_alpha: dragAlpha,
                           time: Float(time) )
        
        self.updateUniforms(uniforms: uni)
                        
        dragAlpha = dragAlpha - (dragAlpha - _dragAlpha) * 0.1;
        
        
    }
    
    func draw(renderEncoder: MTLRenderCommandEncoder, shadow: Bool) {
        
        self.render(renderEncoder: renderEncoder)
        
    }
    
    
}


/*
extension SplatCloud : Renderable {
    
    var label: String {
        return "SplatCloud"
    }
    
    var renderOrder: Int {
        return 10
    }
    
    var receiveShadow: Bool {
        return false
    }
    
    var castShadow: Bool {
        return false
    }
    
    var drawable: Bool {
        return true
    }
    
    var cullMode: MTLCullMode {
        get {
            return .none
        }
        set(newValue) {
            
        }
    }
    
    var opaque: Bool {
        return true
    }
    
    var material: Satin.Material? {
        get {
            return nil
        }
        set(newValue) {
                
        }
    }
    
    var materials: [Satin.Material] {
        return []
    }
    
    func update(camera: Satin.Camera, viewport: simd_float4) {
        
        var uni : Uniforms = Uniforms(projectionMatrix: camera.projectionMatrix,
                                      modelViewMatrix: camera.viewMatrix,
                                      viewport_width: viewport.x, viewport_height: viewport.y)
        
        self.updateUniforms(uniforms: uni)
        
    }
    
    func draw(renderEncoder: MTLRenderCommandEncoder, shadow: Bool) {
        self.render(renderEncoder: renderEncoder)
        
    }
    
    
}
*/
