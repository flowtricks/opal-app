// Descriptor-driven stock-UVC focus assessment. No libusb, seizure, reset,
// configuration change, interface claim, runtime upload, or vendor requests.
// Normal invocation only sends UVC GET requests. Writes require --focus/--auto
// and are gated by the selected camera's descriptor and GET_INFO responses.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/USBSpec.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

struct Terminal { uint8_t interface, entity; bool absolute, automatic; };
static uint16_t le16(const uint8_t *p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
static std::vector<Terminal> parse(const uint8_t *bytes, size_t size) {
    std::vector<Terminal> result;
    bool control = false; uint8_t interface = 0;
    for(size_t offset = 0; offset + 2 <= size;) {
        const auto *p = bytes + offset; size_t length = p[0];
        if(length < 2 || length > size - offset) throw std::runtime_error("Malformed USB configuration descriptor");
        if(p[1] == 4 && length >= 9) { interface = p[2]; control = p[5] == 0x0e && p[6] == 1 && p[3] == 0; }
        if(control && p[1] == 0x24 && length >= 15 && p[2] == 2 && le16(p + 4) == 0x0201) {
            size_t n = p[14]; if(n > length - 15) throw std::runtime_error("Truncated camera-terminal controls");
            auto bit = [&](int index) { return size_t(index / 8) < n && (p[15 + index / 8] & (1 << (index % 8))); };
            result.push_back({interface, p[3], bool(bit(5)), bool(bit(17))});
        }
        offset += length;
    }
    return result;
}
static std::string property(io_service_t service, CFStringRef key) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if(!raw) return {};
    std::string result; char value[256]{};
    if(CFGetTypeID(raw) == CFStringGetTypeID() && CFStringGetCString((CFStringRef)raw, value, sizeof value, kCFStringEncodingUTF8)) result = value;
    CFRelease(raw); return result;
}
static int number(io_service_t service, CFStringRef key) {
    CFTypeRef raw = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    int result = -1;
    if(raw) { if(CFGetTypeID(raw) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)raw, kCFNumberIntType, &result); CFRelease(raw); }
    return result;
}
static void check(IOReturn result, const char *operation) {
    if(result != kIOReturnSuccess) {
        char value[24]; snprintf(value, sizeof value, "0x%08x", unsigned(result));
        throw std::runtime_error(std::string(operation) + " failed: " + value + ". No seizure or reset will be attempted.");
    }
}
class Device {
    IOUSBDeviceInterface **usb = nullptr;
    bool opened = false;
public:
    explicit Device(const std::string &serial) {
        io_iterator_t iterator = 0;
        check(IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator), "USB registry enumeration");
        io_service_t match = 0, service;
        while((service = IOIteratorNext(iterator))) {
            int product = number(service, CFSTR("idProduct"));
            if(number(service, CFSTR("idVendor")) == 0x03e7 && (product == 0xf63d || product == 0xf63b) &&
               property(service, CFSTR("USB Product Name")) == "Opal C1" && property(service, CFSTR("USB Serial Number")) == serial) {
                if(match) { IOObjectRelease(service); IOObjectRelease(match); IOObjectRelease(iterator); throw std::runtime_error("Ambiguous selected identity"); }
                match = service;
            } else IOObjectRelease(service);
        }
        IOObjectRelease(iterator);
        if(!match) throw std::runtime_error("Selected stock Opal C1 not found");
        IOCFPlugInInterface **plugin = nullptr; SInt32 score = 0;
        IOReturn result = IOCreatePlugInInterfaceForService(match, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(match); check(result, "USB device user client");
        HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&usb);
        IODestroyPlugInInterface(plugin);
        if(query || !usb) throw std::runtime_error("USB device interface unavailable");
        // USBDeviceOpen is deliberately not USBDeviceOpenSeize. Failure is final.
        result = (*usb)->USBDeviceOpen(usb);
        if(result != kIOReturnSuccess) { (*usb)->Release(usb); usb = nullptr; check(result, "Non-seizing USB open (close camera apps first)"); }
        opened = true;
    }
    ~Device() { if(usb) { if(opened) (*usb)->USBDeviceClose(usb); (*usb)->Release(usb); } }
    Terminal terminal() {
        UInt8 count = 0, active = 0;
        check((*usb)->GetNumberOfConfigurations(usb, &count), "Read configuration count");
        check((*usb)->GetConfiguration(usb, &active), "Read active configuration");
        std::vector<Terminal> found;
        for(UInt8 i = 0; i < count; ++i) {
            IOUSBConfigurationDescriptorPtr descriptor = nullptr;
            check((*usb)->GetConfigurationDescriptorPtr(usb, i, &descriptor), "Read cached configuration descriptor");
            if(!descriptor || descriptor->bConfigurationValue != active) continue;
            const auto *bytes = reinterpret_cast<const uint8_t *>(descriptor);
            size_t size = le16(bytes + 2);
            if(size < 9 || size > 65535) throw std::runtime_error("Invalid configuration size");
            auto terminals = parse(bytes, size); found.insert(found.end(), terminals.begin(), terminals.end());
        }
        if(found.size() != 1) throw std::runtime_error("Expected one unambiguous active camera terminal; refusing guessed entity IDs");
        return found[0];
    }
    uint16_t request(Terminal t, uint8_t selector, uint8_t request, size_t length, uint16_t value = 0) {
        uint8_t bytes[2] = {uint8_t(value), uint8_t(value >> 8)};
        if(length != 1 && length != 2) throw std::runtime_error("Invalid focus transfer length");
        IOUSBDevRequest transfer{};
        transfer.bmRequestType = request == 1 ? 0x21 : 0xa1;
        transfer.bRequest = request; transfer.wValue = uint16_t(selector) << 8;
        transfer.wIndex = uint16_t(t.entity) << 8 | t.interface; transfer.wLength = UInt16(length); transfer.pData = bytes;
        check((*usb)->DeviceRequest(usb, &transfer), "UVC focus request");
        if(transfer.wLenDone != length) throw std::runtime_error("UVC focus transfer returned unexpected length");
        return length == 1 ? bytes[0] : le16(bytes);
    }
};
struct Capability { bool advertised = false; uint8_t info = 0; std::optional<uint16_t> current, min, max, resolution; };
static Capability inspect(Device &device, Terminal terminal, uint8_t selector, bool advertised) {
    Capability c; c.advertised = advertised;
    std::cout << (selector == 6 ? "focus_absolute" : "focus_auto") << ": advertised=" << advertised;
    if(!advertised) { std::cout << '\n'; return c; }
    try {
        c.info = uint8_t(device.request(terminal, selector, 0x86, 1));
        std::cout << " info=" << unsigned(c.info) << " get=" << bool(c.info & 1) << " set=" << bool(c.info & 2) << " disabled=" << bool(c.info & 4);
        if(c.info & 1) {
            c.current = device.request(terminal, selector, 0x81, selector == 6 ? 2 : 1);
            std::cout << " current=" << *c.current;
            if(selector == 6) {
                c.min = device.request(terminal, selector, 0x82, 2); c.max = device.request(terminal, selector, 0x83, 2); c.resolution = device.request(terminal, selector, 0x84, 2);
                std::cout << " min=" << *c.min << " max=" << *c.max << " resolution=" << *c.resolution;
            }
        }
    } catch(const std::exception &e) { std::cout << " error=" << e.what(); }
    std::cout << '\n'; return c;
}
static bool canWrite(const Capability &c) { return c.advertised && (c.info & 3) == 3 && !(c.info & 4) && c.current.has_value(); }
int main(int argc, char **argv) {
    try {
        if(argc == 2 && std::string(argv[1]) == "--self-test") {
            std::vector<uint8_t> bytes = {9,4,3,0,0,0x0e,1,0,0,18,0x24,2,7,1,2,0,0,0,0,0,0,0,0,3,0x20,0,2};
            auto result = parse(bytes.data(), bytes.size());
            if(result.size()!=1 || result[0].interface!=3 || result[0].entity!=7 || !result[0].absolute || !result[0].automatic) throw std::runtime_error("Descriptor fixture failed");
            bytes[23] = 4; bool rejected = false;
            try { parse(bytes.data(), bytes.size()); } catch(...) { rejected = true; }
            if(!rejected) throw std::runtime_error("Malformed descriptor was accepted");
            std::cout << "Descriptor tests passed; no hardware accessed.\n"; return 0;
        }
        std::string serial; std::optional<int> focus, automatic; bool testFocus = false, composerFocus = false;
        for(int i=1; i<argc; ++i) {
            std::string option=argv[i];
            if(option=="--probe") continue;
            if(i+1>=argc) throw std::runtime_error("Missing option value");
            if(option=="--serial") serial=argv[++i];
            else if(option=="--focus") focus=std::stoi(argv[++i]);
            else if(option=="--test-focus") { focus=std::stoi(argv[++i]); testFocus=true; }
            else if(option=="--test-composer-focus") { focus=std::stoi(argv[++i]); testFocus=true; composerFocus=true; }
            else if(option=="--auto") automatic=std::stoi(argv[++i]);
            else throw std::runtime_error("Unknown option");
        }
        if(serial.empty() || (focus && automatic)) throw std::runtime_error("Usage: c1-uvc-focus --serial EXACT_SERIAL [--probe | --focus INTEGER | --test-focus INTEGER | --test-composer-focus INTEGER | --auto 0|1]");
        if(automatic && *automatic!=0 && *automatic!=1) throw std::runtime_error("Auto value must be 0 or 1");
        Device device(serial); Terminal terminal=device.terminal();
        std::cout << "camera_terminal=" << unsigned(terminal.entity) << " interface=" << unsigned(terminal.interface) << '\n';
        auto absolute=inspect(device,terminal,6,terminal.absolute);
        auto autoFocus=inspect(device,terminal,8,terminal.automatic);
        if(automatic) {
            if(!canWrite(autoFocus)) throw std::runtime_error("Focus Auto is not verified writable; no write sent");
            device.request(terminal,8,1,1,uint16_t(*automatic));
            std::cout << "focus_auto readback=" << device.request(terminal,8,0x81,1) << '\n';
        }
        if(focus) {
            // The absolute control's own GET_INFO disabled bit is authoritative.
            // Some stock C1 firmware advertises writable/enabled absolute focus
            // while exposing a read-only autofocus switch. Never write that switch.
            if(!canWrite(absolute) || !absolute.min || !absolute.max || !absolute.resolution)
                throw std::runtime_error("Absolute focus is not verified writable and enabled; no write sent");
            if(*focus < *absolute.min || *focus > *absolute.max)
                throw std::runtime_error("Focus is outside device-advertised range; no write sent");
            if(composerFocus && (!autoFocus.advertised || !(autoFocus.info & 1) || !autoFocus.current))
                throw std::runtime_error("Composer sequence requires advertised, readable autofocus; no write sent");
            const uint16_t previous = *absolute.current;
            const uint16_t previousAuto = autoFocus.current.value_or(0);
            bool restoreAttempted = false;
            auto restore = [&] {
                restoreAttempted = true;
                // Restore the exact observed value, even if firmware reports a
                // step that does not divide its own current/default setting.
                std::string errors;
                try {
                    device.request(terminal,6,1,2,previous);
                    const auto restored = device.request(terminal,6,0x81,2);
                    std::cout << "focus_absolute restored=" << restored << " expected=" << previous << '\n';
                    if(restored != previous) throw std::runtime_error("Focus restoration readback differs from captured value");
                } catch(const std::exception &e) { errors = e.what(); }
                // Restore autofocus even when the absolute restoration fails.
                if(composerFocus) {
                    try {
                        device.request(terminal,8,1,1,previousAuto);
                        const auto restored = device.request(terminal,8,0x81,1);
                        std::cout << "focus_auto restored=" << restored << " expected=" << previousAuto << '\n';
                        if(restored != previousAuto) throw std::runtime_error("Autofocus restoration readback differs from captured value");
                    } catch(const std::exception &e) { if(!errors.empty()) errors += "; "; errors += e.what(); }
                }
                if(!errors.empty()) throw std::runtime_error(errors);
            };
            try {
                if(composerFocus) {
                    // Explicit C1-only compatibility experiment: shipped Composer
                    // UVCBoolControl writes selector 8 despite GET_INFO=1, then
                    // UVCCameraDevice::setFocus writes selector 6. Never used by
                    // the generic --auto/--focus guards or automatically.
                    device.request(terminal,8,1,1,0);
                    const auto readback = device.request(terminal,8,0x81,1);
                    std::cout << "focus_auto manual readback=" << readback << '\n';
                    if(readback != 0) throw std::runtime_error("Autofocus did not enter manual mode; absolute write not sent");
                }
                device.request(terminal,6,1,2,uint16_t(*focus));
                std::cout << "focus_absolute readback=" << device.request(terminal,6,0x81,2) << '\n';
                if(testFocus) restore();
            } catch(...) {
                if(testFocus && !restoreAttempted) {
                    try { restore(); } catch(const std::exception &e) { std::cerr << "Restoration failed: " << e.what() << '\n'; }
                }
                throw;
            }
        }
        return 0;
    } catch(const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
