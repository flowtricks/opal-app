import Foundation
import Metal
import CoreImage
import XCTest
@testable import OpalCore

final class ComposerToneSyncNativeOracleTests: XCTestCase {
func testFullToneSyncMatchesNativeExtractionCalibrationFaceBalanceAndR8Blend() throws {

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let resources = try ComposerNativeShaders.resources(for:device)
let vendor = resources.library
let vertexLibrary = try device.makeLibrary(source: """
#include <metal_stdlib>
using namespace metal;
struct Raster { float4 position [[position]]; float2 textureCoordinate; };
vertex Raster oracleVertex(uint i [[vertex_id]]) {
    float2 positions[4] = {float2(-1,1),float2(-1,-1),float2(1,1),float2(1,-1)};
    float2 uv[4] = {float2(0,0),float2(0,1),float2(1,0),float2(1,1)};
    return {float4(positions[i],0,1),uv[i]};
}
""", options:nil)
let vertex = vertexLibrary.makeFunction(name:"oracleVertex")!
let options = MTLCompileOptions(); options.preprocessorMacros = ["TARGET_OS_SIMULATOR":NSNumber(value:0)]
let embedded = try resources.embeddedLibrary()
let w = 256, h = 192
let region = MTLRegionMake2D(0,0,w,h)
let bounds = CGRect(x:0,y:0,width:w,height:h)
let samplerDescriptor = MTLSamplerDescriptor()
samplerDescriptor.minFilter = .linear; samplerDescriptor.magFilter = .linear
samplerDescriptor.sAddressMode = .clampToEdge; samplerDescriptor.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor:samplerDescriptor)!
func texture(_ format: MTLPixelFormat = .rgba8Unorm) -> MTLTexture {
 let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:w,height:h,mipmapped:false)
 d.usage=[.shaderRead,.renderTarget];d.storageMode = .shared
 return device.makeTexture(descriptor:d)!
}
func data<T>(_ v:T)->Data { var x=v; return withUnsafeBytes(of:&x){Data($0)} }
func render(_ name:String, inputs:[MTLTexture], buffers:[Data], format:MTLPixelFormat = .rgba8Unorm) throws -> MTLTexture {
 guard let fragment=vendor.makeFunction(name:name) ?? embedded.makeFunction(name:name) else { fatalError("Missing \(name). Available \(vendor.functionNames)") }
 let d=MTLRenderPipelineDescriptor();d.vertexFunction=vertex;d.fragmentFunction=fragment;d.colorAttachments[0].pixelFormat=format
 let pipeline=try device.makeRenderPipelineState(descriptor:d)
 let out=texture(format);let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=out;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
 let command=queue.makeCommandBuffer()!;let e=command.makeRenderCommandEncoder(descriptor:pass)!
 e.setRenderPipelineState(pipeline)
 for (i,t) in inputs.enumerated(){ e.setFragmentTexture(t,index:i);e.setFragmentSamplerState(sampler,index:i) }
 for(i,b) in buffers.enumerated(){ b.withUnsafeBytes{ e.setFragmentBytes($0.baseAddress!,length:$0.count,index:i) } }
 e.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4);e.endEncoding();command.commit();command.waitUntilCompleted()
 if let error=command.error {throw error};return out
}
func bytes(_ t:MTLTexture)->[UInt8] { var b=[UInt8](repeating:0,count:w*h*4);t.getBytes(&b,bytesPerRow:w*4,from:region,mipmapLevel:0);return b }

let space=CGColorSpaceCreateDeviceRGB()
let nativeContext=CIContext(mtlDevice:device,options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.BGRA8,.cacheIntermediates:false])
let linearContext=CIContext(mtlDevice:device,options:[.cacheIntermediates:false])
func ci(_ input:[UInt8])->CIImage { CIImage(bitmapData:Data(input),bytesPerRow:w*4,size:bounds.size,format:.RGBA8,colorSpace:space) }
func pixels(_ image:CIImage,_ context:CIContext)->[UInt8] {var b=[UInt8](repeating:0,count:w*h*4);context.render(image,toBitmap:&b,rowBytes:w*4,bounds:bounds,format:.RGBA8,colorSpace:space);return b}
func pixels(_ image:CIImage)->[UInt8] { pixels(image,nativeContext) }
func report(_ name:String,_ reference:[UInt8],_ actual:[UInt8]) {
 let errors=zip(reference,actual).map{abs(Int($0)-Int($1))}; XCTAssertEqual(errors.filter{$0>0}.count,0,name); print("\(name): changed=\(errors.filter{$0>0}.count)/\(errors.count) max=\(errors.max()!) mean=\(Double(errors.reduce(0,+))/Double(errors.count))")
}
var input=[UInt8](repeating:255,count:w*h*4), maskValues=[UInt8](repeating:0,count:w*h)
for y in 0..<h {for x in 0..<w {
 let i=(y*w+x)*4
 input[i]=UInt8(100+(x*3+y*7)%140);input[i+1]=UInt8(70+(x*7+y*11)%110);input[i+2]=UInt8(40+(x*13+y*5)%70)
 maskValues[y*w+x]=UInt8((Float(x)/Float(w-1)*255).rounded())
}}
let source=texture(), mask=texture(.r8Unorm)
source.replace(region:region,mipmapLevel:0,withBytes:input,bytesPerRow:w*4)
mask.replace(region:region,mipmapLevel:0,withBytes:maskValues,bytesPerRow:w)
let sourceCI=ci(input),maskCI=CIImage(bitmapData:maskValues.withUnsafeBytes{Data($0)},bytesPerRow:w,size:bounds.size,format:.R8,colorSpace:nil)
let nativeSkin=try render("metalpetal::skintoneadjustment::extractSkin",inputs:[source,mask],buffers:[])
let ciSkin=SkinEffects.extractSkin!.apply(extent:bounds,arguments:[sourceCI,maskCI])!
report("Skin extraction",bytes(nativeSkin),pixels(ciSkin))
let face=CGRect(x:30,y:20,width:190,height:140)
let crop=face.insetBy(dx:face.width*0.075,dy:face.height*0.15).intersection(bounds)
func average(_ image:CIImage)->[UInt8] {
 let filter=CIFilter(name:"CIKMeans")!
 filter.setValue(image.cropped(to:crop),forKey:kCIInputImageKey)
 filter.setValue(CIVector(cgRect:crop),forKey:"inputExtent")
 filter.setValue(1,forKey:"inputCount");filter.setValue(10,forKey:"inputPasses");filter.setValue(false,forKey:"inputPerceptual")
 filter.setValue(CIImage(color:CIColor(red:0.6,green:0.5,blue:0.4)).cropped(to:CGRect(x:0,y:0,width:1,height:1)),forKey:"inputMeans")
 var b=[UInt8](repeating:0,count:4);nativeContext.render(filter.outputImage!,toBitmap:&b,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:space);return b
}
let averageNative=average(ci(bytes(nativeSkin))),averageCI=average(ciSkin)
XCTAssertEqual(averageNative,averageCI)
let r=Double(averageNative[0]),g=Double(averageNative[1]),b=Double(averageNative[2])
let chroma=(i:(r*0.5959)/255+(g*(-0.2746))/255-(b*0.3213)/255,q:(r*0.2115)/255+(g*(-0.5227))/255+(b*0.3112)/255)
let actualCalibration=try SkinEffects().calibrate(sourceCI,personMask:maskCI,face:face,context:linearContext)
XCTAssertEqual(try XCTUnwrap(actualCalibration).i,chroma.i,accuracy:1e-15)
XCTAssertEqual(try XCTUnwrap(actualCalibration).q,chroma.q,accuracy:1e-15)
for (amount,warmth) in [(0.5,0.5),(1.0,0.0),(1.0,1.0)] {
 let filter=CIFilter(name:"CIFaceBalance")!
 filter.setValue(sourceCI,forKey:kCIInputImageKey);filter.setValue(amount*2,forKey:"inputStrength");filter.setValue(warmth,forKey:"inputWarmth")
 filter.setValue(chroma.i,forKey:"inputOrigI");filter.setValue(chroma.q,forKey:"inputOrigQ")
 let balancedBytes=pixels(filter.outputImage!),balanced=texture()
 balanced.replace(region:region,mipmapLevel:0,withBytes:balancedBytes,bytesPerRow:w*4)
 let native=try render("metalpetal::blendWithMask",inputs:[balanced,mask,source],buffers:[data(Int32(0)),data(UInt8(0))])
 let calibrationQueue=DispatchQueue(label:"test.native.tonesync")
 let effect=SkinEffects(calibrationQueue:calibrationQueue)
 _ = try effect.toneSync(sourceCI,personMask:maskCI,face:face,amount:amount,warmth:warmth,revision:0,context:linearContext)
 calibrationQueue.sync {}
 let actual=try effect.toneSync(sourceCI,personMask:maskCI,face:face,amount:amount,warmth:warmth,revision:0,context:linearContext)
 let actualBytes=pixels(actual,linearContext), nativeBytes=bytes(native)
 report("ToneSync amount\(amount) warmth\(warmth)",nativeBytes,actualBytes)
 for rect in [CGRect(x:37,y:11,width:47,height:29)] {
  let rw=Int(rect.width),rh=Int(rect.height)
  var actualCrop=[UInt8](repeating:0,count:rw*rh*4)
  linearContext.render(actual,toBitmap:&actualCrop,rowBytes:rw*4,bounds:rect,format:.RGBA8,colorSpace:space)
  let expected=(h-Int(rect.maxY)..<h-Int(rect.minY)).flatMap { y in Array(nativeBytes[(y*w+Int(rect.minX))*4..<(y*w+Int(rect.maxX))*4]) }
  XCTAssertEqual(zip(actualCrop,expected).filter{$0 != $1}.count,0,"Cropped ToneSync native oracle")
 }
}
}
}
