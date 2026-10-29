// Original bridge implementation against the public MIT-licensed Luxonis SDK.
#include "C1Bridge.h"
#include <depthai/depthai.hpp>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <mutex>
#include <numeric>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

struct C1Session {
    std::unique_ptr<dai::Device> device;
    std::shared_ptr<dai::DataOutputQueue> video;
    std::shared_ptr<dai::DataInputQueue> commands;
    std::thread worker;
    std::atomic<bool> stopping{false};
    std::mutex commandMutex;
    C1Controls controls{};
    bool hasControls = false;
    int fps = 30;
    C1FrameCallback frameCallback = nullptr;
    C1StatusCallback statusCallback = nullptr;
    void *context = nullptr;
};

namespace {
using Clock = std::chrono::steady_clock;
void copyText(char *destination, size_t capacity, const std::string &text) {
    if(!destination || capacity == 0) return;
    const auto n = std::min(capacity - 1, text.size());
    std::memcpy(destination, text.data(), n);
    destination[n] = 0;
}

// Registry properties are cached by macOS. Never open USB device handles while
// listing: even libusb's descriptor-only path uses USBDeviceOpenSeize on Darwin.
std::vector<C1Device> stockCameras() {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) != KERN_SUCCESS)
        throw std::runtime_error("Cannot read the USB device registry");
    std::vector<C1Device> result;
    io_service_t service;
    while((service = IOIteratorNext(iterator))) {
        CFMutableDictionaryRef properties = nullptr;
        if(IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties) {
            auto number = [&](CFStringRef key) -> int {
                CFTypeRef value = CFDictionaryGetValue(properties, key);
                int n = -1;
                if(value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &n);
                return n;
            };
            auto string = [&](CFStringRef key) -> std::string {
                CFTypeRef value = CFDictionaryGetValue(properties, key);
                char text[256]{};
                if(value && CFGetTypeID(value) == CFStringGetTypeID() && CFStringGetCString(static_cast<CFStringRef>(value), text, sizeof(text), kCFStringEncodingUTF8)) return text;
                return {};
            };
            const int vendor = number(CFSTR("idVendor")), product = number(CFSTR("idProduct"));
            const auto name = string(CFSTR("USB Product Name"));
            const auto serial = string(CFSTR("USB Serial Number"));
            if(vendor == 0x03e7 && (product == 0xf63d || product == 0xf63b) && name == "Opal C1" && !serial.empty() && serial.size() < sizeof(C1Device::identifier)) {
                C1Device item{};
                copyText(item.identifier, sizeof(item.identifier), serial);
                copyText(item.name, sizeof(item.name), name);
                item.product_id = static_cast<uint16_t>(product);
                result.push_back(item);
            }
            CFRelease(properties);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return result;
}

void status(C1Session *s, const std::string &text, bool error = false) {
    if(s->statusCallback) s->statusCallback(text.c_str(), error ? 1 : 0, s->context);
}

dai::DeviceInfo findExact(const std::string &identifier, XLinkDeviceState_t wanted, double timeoutSeconds) {
    const auto deadline = Clock::now() + std::chrono::milliseconds(int(timeoutSeconds * 1000));
    std::string lastObserved = "no USB/XLink devices";
    do {
        // Preserve rejected-device status in the failure evidence. The SDK's
        // default skips BUSY/ACCESS/error entries and hides why identity fails.
        const auto devices = dai::XLinkConnection::getAllConnectedDevices(X_LINK_ANY_STATE, false);
        std::string observed;
        for(const auto &device : devices) {
            if(device.protocol != X_LINK_USB_VSC) continue;
            if(!observed.empty()) observed += "; ";
            observed += device.toString();
            if(device.getMxId() == identifier && device.state == wanted && device.status == X_LINK_SUCCESS) return device;
        }
        if(!observed.empty()) lastObserved = observed;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    } while(Clock::now() < deadline);
    throw std::runtime_error("Selected C1 did not reappear in the expected USB state; no other device will be used. Last SDK observation: " + lastObserved);
}

C1Controls normalized(C1Controls c, int fps) {
    c.manual_focus = !!c.manual_focus; c.manual_exposure = !!c.manual_exposure;
    c.manual_white_balance = !!c.manual_white_balance;
    c.exposure_lock = !!c.exposure_lock; c.white_balance_lock = !!c.white_balance_lock;
    c.lens_position = std::clamp(c.lens_position, 0, 255);
    c.exposure_us = std::clamp(c.exposure_us, 1, 1000000 / fps);
    c.iso = std::clamp(c.iso, 100, 1600);
    c.exposure_compensation = std::clamp(c.exposure_compensation, -9, 9);
    c.white_balance_kelvin = std::clamp(c.white_balance_kelvin, 1000, 12000);
    c.antibanding = std::clamp(c.antibanding, 0, 3);
    c.sharpness = std::clamp(c.sharpness, 0, 4);
    c.luma_denoise = std::clamp(c.luma_denoise, 0, 4);
    c.chroma_denoise = std::clamp(c.chroma_denoise, 0, 4);
    return c;
}

std::shared_ptr<dai::RawCameraControl> encodeControls(const C1Controls &old, const C1Controls &next, bool all) {
    bool changed = false;
    auto raw = std::make_shared<dai::RawCameraControl>();
    dai::CameraControl command(raw);
    if(all || next.manual_focus != old.manual_focus) {
        command.setAutoFocusMode(next.manual_focus ? dai::CameraControl::AutoFocusMode::OFF : dai::CameraControl::AutoFocusMode::CONTINUOUS_VIDEO);
        changed = true;
    }
    if(next.manual_focus && (all || !old.manual_focus || next.lens_position != old.lens_position)) {
        command.setManualFocus(next.lens_position); changed = true;
    }
    if(next.manual_exposure) {
        if(all || !old.manual_exposure || next.exposure_us != old.exposure_us || next.iso != old.iso) {
            command.setManualExposure(next.exposure_us, next.iso); changed = true;
        }
    } else {
        if(all || old.manual_exposure) { command.setAutoExposureEnable(); changed = true; }
        if(all || old.manual_exposure || next.exposure_compensation != old.exposure_compensation) {
            command.setAutoExposureCompensation(next.exposure_compensation); changed = true;
        }
        if(all || old.manual_exposure || next.exposure_lock != old.exposure_lock) {
            command.setAutoExposureLock(next.exposure_lock); changed = true;
        }
    }
    if(next.manual_white_balance) {
        if(all || !old.manual_white_balance || next.white_balance_kelvin != old.white_balance_kelvin) {
            command.setManualWhiteBalance(next.white_balance_kelvin); changed = true;
        }
    } else {
        if(all || old.manual_white_balance) { command.setAutoWhiteBalanceMode(dai::CameraControl::AutoWhiteBalanceMode::AUTO); changed = true; }
        if(all || old.manual_white_balance || next.white_balance_lock != old.white_balance_lock) {
            command.setAutoWhiteBalanceLock(next.white_balance_lock); changed = true;
        }
    }
    if(all || next.antibanding != old.antibanding) {
        const dai::CameraControl::AntiBandingMode modes[] = {dai::CameraControl::AntiBandingMode::OFF, dai::CameraControl::AntiBandingMode::MAINS_50_HZ, dai::CameraControl::AntiBandingMode::MAINS_60_HZ, dai::CameraControl::AntiBandingMode::AUTO};
        command.setAntiBandingMode(modes[next.antibanding]); changed = true;
    }
    if(all || next.sharpness != old.sharpness) { command.setSharpness(next.sharpness); changed = true; }
    if(all || next.luma_denoise != old.luma_denoise) { command.setLumaDenoise(next.luma_denoise); changed = true; }
    if(all || next.chroma_denoise != old.chroma_denoise) { command.setChromaDenoise(next.chroma_denoise); changed = true; }
    (void)changed;
    return raw;
}

void applyControls(C1Session *s, C1Controls next) {
    std::lock_guard<std::mutex> lock(s->commandMutex);
    if(s->stopping || !s->commands) throw std::runtime_error("C1 session is stopping");
    next = normalized(next, s->fps);
    auto raw = encodeControls(s->controls, next, !s->hasControls);
    if(raw->cmdMask) s->commands->send(dai::CameraControl(raw));
    s->controls = next;
    s->hasControls = true;
}

uint64_t hostNanoseconds() {
    static const mach_timebase_info_data_t scale = [] { mach_timebase_info_data_t value; mach_timebase_info(&value); return value; }();
    return uint64_t((__uint128_t(mach_absolute_time()) * scale.numer) / scale.denom);
}

void frameLoop(C1Session *s) {
    auto lastFrame = Clock::now();
    bool stalled = false;
    try {
        while(!s->stopping) {
            auto image = s->video->tryGet<dai::ImgFrame>();
            if(!image) {
                if(!stalled && Clock::now() - lastFrame > std::chrono::seconds(3)) {
                    status(s, "C1 has not delivered a frame for 3 seconds", true); stalled = true;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
                continue;
            }
            const int width = image->getWidth(), height = image->getHeight();
            const auto &bytes = image->getData();
            if(width < 1 || height < 1 || width > 3840 || height > 2160 || width % 2 || height % 2 ||
               image->getType() != dai::ImgFrame::Type::NV12 || bytes.size() < size_t(width) * height * 3 / 2) {
                status(s, "Rejected malformed or unexpected C1 frame", true); continue;
            }
            if(stalled) status(s, "C1 frames resumed");
            stalled = false; lastFrame = Clock::now();
            C1Frame frame{};
            frame.y = bytes.data(); frame.uv = bytes.data() + size_t(width) * height;
            frame.y_stride = width; frame.uv_stride = width;
            frame.width = width; frame.height = height;
            // Arrival on the CoreMedia host clock, never wall time or a camera
            // oscillator with an unrelated epoch.
            frame.host_time_ns = hostNanoseconds();
            frame.exposure_us = int32_t(image->getExposureTime().count());
            frame.iso = image->getSensitivity(); frame.lens_position = image->getLensPosition();
            frame.white_balance_kelvin = image->getColorTemperature();
            if(s->frameCallback) s->frameCallback(&frame, s->context);
        }
    } catch(const std::exception &e) {
        if(!s->stopping) status(s, std::string("C1 capture stopped: ") + e.what(), true);
    } catch(...) {
        if(!s->stopping) status(s, "C1 capture stopped unexpectedly", true);
    }
}
} // namespace

extern "C" {
int32_t c1_list_devices(C1Device *devices, int32_t capacity, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    if(!devices || capacity < 1) { copyText(error, errorSize, "Device array/capacity is invalid"); return -1; }
    try {
        auto found = stockCameras();
        int count = std::min<int>(int(found.size()), capacity);
        std::copy_n(found.begin(), count, devices);
        return count;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return -1; }
}

C1Controls c1_default_controls(void) {
    C1Controls c{};
    c.lens_position = 128; c.exposure_us = 10000; c.iso = 200;
    c.white_balance_kelvin = 5000; c.antibanding = 3; c.sharpness = 1;
    c.luma_denoise = 1; c.chroma_denoise = 1;
    return c;
}

C1Session *c1_open(const char *identifier, C1Configuration cfg, C1Controls controls,
                   C1FrameCallback frameCallback, C1StatusCallback statusCallback,
                   void *context, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    if(!identifier || !identifier[0] || !frameCallback ||
       (cfg.width != 640 && cfg.width != 1280 && cfg.width != 1920 && cfg.width != 2560 && cfg.width != 3840) || cfg.height != cfg.width * 9 / 16 || cfg.fps < 1 || cfg.fps > 30) {
        copyText(error, errorSize, "Explicit C1 identity, callback and supported 16:9 configuration required"); return nullptr;
    }
    auto session = std::make_unique<C1Session>();
    session->fps = cfg.fps; session->frameCallback = frameCallback;
    session->statusCallback = statusCallback; session->context = context;
    std::string stage = "validating selected C1";
    try {
        const std::string selected(identifier);
        auto known = stockCameras();
        if(std::none_of(known.begin(), known.end(), [&](const C1Device &d) { return selected == d.identifier; })) {
            throw std::runtime_error("Selected C1 is not identifiable in stock camera mode. Close other camera controllers and reconnect it");
        }
        dai::Pipeline pipeline;
        auto camera = pipeline.create<dai::node::ColorCamera>();
        camera->setBoardSocket(dai::CameraBoardSocket::CAM_A);
        camera->setResolution(dai::ColorCameraProperties::SensorResolution::THE_4_K);
        camera->setFps(cfg.fps);
        camera->setImageOrientation(dai::CameraImageOrientation::ROTATE_180_DEG);
        camera->setInterleaved(false);
        // Keep the requested field of view at every size, including 1440p's
        // non-integer divisor. Integer division would crop a 4K ISP image.
        const int scaleDivisor = std::gcd(cfg.width, 3840);
        camera->setIspScale(cfg.width / scaleDivisor, 3840 / scaleDivisor);
        camera->setVideoSize(cfg.width, cfg.height);
        auto output = pipeline.create<dai::node::XLinkOut>(); output->setStreamName("c1-video");
        output->input.setQueueSize(1); output->input.setBlocking(false);
        camera->video.link(output->input);
        auto input = pipeline.create<dai::node::XLinkIn>(); input->setStreamName("c1-controls"); input->out.link(camera->inputControl);
        // Decompress/cache the SDK resources and create the graph before the
        // camera leaves stock mode: the USB ROM handoff window is short.
        stage = "preparing the public runtime";
        status(session.get(), "Preparing public DepthAI runtime before camera handoff");
        const auto firmware = dai::Device::getEmbeddedDeviceBinary(false);
        if(firmware.empty()) throw std::runtime_error("Embedded runtime is empty");
        const auto bootloaderFirmware = dai::DeviceBootloader::getEmbeddedBootloaderBinary();
        if(bootloaderFirmware.empty()) throw std::runtime_error("Embedded bootloader resource is empty");

        stage = "locating the selected stock C1 through USB";
        auto connected = dai::XLinkConnection::getAllConnectedDevices();
        auto found = std::find_if(connected.begin(), connected.end(), [&](const dai::DeviceInfo &d) { return d.getMxId() == selected && d.protocol == X_LINK_USB_VSC; });
        if(found == connected.end()) throw std::runtime_error("Selected C1 is not available through USB/XLink");
        dai::DeviceInfo device = *found;
        if(device.state != X_LINK_BOOTED && device.state != X_LINK_FLASH_BOOTED)
            throw std::runtime_error("C1 is not running recognizable stock firmware; refusing takeover");

        // Handle both stock states explicitly. DeviceBase's FLASH_BOOTED path
        // hides this transition and can reuse a descriptor across USB changes.
        stage = "entering the selected C1 bootloader";
        status(session.get(), "Entering C1 bootloader; stock camera and microphone disconnect");
        dai::XLinkConnection::bootBootloader(device);
        device = findExact(selected, X_LINK_BOOTLOADER, 15);
        // Let DeviceBase own the complete version-aware handoff and configured
        // firmware: bootMemory for loaders >=0.0.12, USB ROM for older loaders.
        // Forcing every loader through ROM adds an unnecessary transition and
        // separates the short ROM window from its firmware upload.
        // Match only the already verified hardware ID during reconnect. The
        // SDK's legacy ROM search otherwise treats a saved USB path as strict;
        // USB2/USB3 re-enumeration can change that path on the same camera.
        device.name.clear();
        stage = "starting the selected C1 through the SDK RAM handoff";
        status(session.get(), "Loading C1 RAM runtime through its version-aware bootloader; stock microphone is unavailable");
        session->device = std::make_unique<dai::Device>(pipeline, device, dai::UsbSpeed::SUPER);
        session->video = session->device->getOutputQueue("c1-video", 1, false);
        session->commands = session->device->getInputQueue("c1-controls", 4, false);
        applyControls(session.get(), controls);
        status(session.get(), "C1 sensor controls connected");
        session->worker = std::thread(frameLoop, session.get());
        return session.release();
    } catch(const std::exception &e) {
        copyText(error, errorSize, "C1 failed while " + stage + ": " + e.what()
                 + ". No flash write was requested. Wait for the stock camera to return; reconnect USB if it does not.");
    }
    catch(...) { copyText(error, errorSize, "Unexpected C1 initialization failure while " + stage); }
    // unique_ptr cleanup releases any partially constructed device; it never
    // requests a firmware flash. No worker exists before successful setup.
    return nullptr;
}

int32_t c1_set_controls(C1Session *session, C1Controls controls, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    if(!session) { copyText(error, errorSize, "C1 is not connected"); return 0; }
    try { applyControls(session, controls); return 1; }
    catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}

int32_t c1_trigger_autofocus(C1Session *session, char *error, size_t errorSize) {
    copyText(error, errorSize, "");
    if(!session) { copyText(error, errorSize, "C1 is not connected"); return 0; }
    try {
        std::lock_guard<std::mutex> lock(session->commandMutex);
        if(session->stopping || !session->commands) throw std::runtime_error("C1 session is stopping");
        if(session->controls.manual_focus) throw std::runtime_error("Enable automatic focus before refocusing");
        dai::CameraControl command; command.setAutoFocusTrigger(); session->commands->send(command);
        return 1;
    } catch(const std::exception &e) { copyText(error, errorSize, e.what()); return 0; }
}

void c1_close(C1Session *session) {
    if(!session) return;
    session->stopping = true;
    if(session->worker.joinable()) session->worker.join();
    { std::lock_guard<std::mutex> lock(session->commandMutex);
      session->commands.reset(); session->video.reset();
      if(session->device) { try { session->device->close(); } catch(...) {} session->device.reset(); }
    }
    delete session;
}
} // extern C
