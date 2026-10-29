import CoreImage

/// A sampled neutral point, independent of the original app's Auto policy.
/// Preserve the sample's luminance instead of making a dark picked gray white.
enum WhitePointCorrection {
    static func apply(to image: CIImage, sampleRGB: [Double]) -> CIImage {
        guard sampleRGB.count==3, sampleRGB.allSatisfy({ $0.isFinite }) else { return image }
        let linear=sampleRGB.map { value -> Double in
            let value=min(1,max(0,value))
            return value<=0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4)
        }
        let luminance=linear[0]*0.2126+linear[1]*0.7152+linear[2]*0.0722
        guard luminance>0.000001 else { return image }
        // CIWhitePointAdjust clamps its color components to the unit range.
        // Use attenuation-only gains, then restore luminance with scalar EV.
        // A clipped/black channel cannot establish a usable neutral point.
        guard let common=linear.min(), common>0.000001 else { return image }
        let gain=linear.map { min(1,common/$0) }
        let color=CIColor(red:gain[0],green:gain[1],blue:gain[2],alpha:1,
                          colorSpace:CGColorSpace(name:CGColorSpace.linearSRGB)!)!
        return image.applyingFilter("CIWhitePointAdjust",parameters:[kCIInputColorKey:color])
            .applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:log2(luminance/common)])
    }
}
