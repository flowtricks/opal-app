// No USB/device calls: verifies real SDK command masks and value bounds.
#include "C1Bridge.cpp"
#include <iostream>

static void require(bool condition, const char *message) {
    if(!condition) throw std::runtime_error(message);
}
int main() {
    using Command = dai::RawCameraControl::Command;
    auto defaults = c1_default_controls();
    require(encodeControls(defaults, defaults, false)->cmdMask == 0, "Unchanged settings emitted a command");
    auto changed = defaults; changed.exposure_compensation = 2;
    auto raw = encodeControls(defaults, changed, false);
    require(raw->getCommand(Command::EXPOSURE_COMPENSATION), "Exposure delta missing");
    require(!raw->getCommand(Command::AF_MODE) && !raw->getCommand(Command::AF_TRIGGER), "Exposure restarted autofocus");
    changed = defaults; changed.manual_focus = 1; changed.lens_position = 211;
    raw = encodeControls(defaults, changed, false);
    require(raw->getCommand(Command::AF_MODE) && raw->getCommand(Command::MOVE_LENS), "Manual focus lacks mode/position");
    require(raw->autoFocusMode == dai::RawCameraControl::AutoFocusMode::OFF && raw->lensPosition == 211, "Manual focus payload incorrect");
    raw = encodeControls(changed, defaults, false);
    require(raw->getCommand(Command::AF_MODE) && !raw->getCommand(Command::MOVE_LENS), "Returning to autofocus sends stale lens position");
    changed = defaults; changed.manual_white_balance = 1; changed.white_balance_kelvin = 4200;
    raw = encodeControls(defaults, changed, false);
    require(raw->getCommand(Command::WB_COLOR_TEMP) && !raw->getCommand(Command::AF_MODE), "White balance changed autofocus");
    changed.exposure_us = 1000000; changed.iso = -1; changed.lens_position = 900; changed.white_balance_kelvin = 99;
    auto bounded = normalized(changed, 30);
    require(bounded.exposure_us == 33333 && bounded.iso == 100 && bounded.lens_position == 255 && bounded.white_balance_kelvin == 1000, "Sensor bounds failed");
    auto first = encodeControls({}, defaults, true);
    require(first->getCommand(Command::AF_MODE) && first->getCommand(Command::ANTIBANDING_MODE), "Initial sensor defaults omitted");
    dai::Pipeline pipeline;
    auto camera = pipeline.create<dai::node::ColorCamera>();
    camera->setResolution(dai::ColorCameraProperties::SensorResolution::THE_4_K);
    for(int width : {640, 1280, 1920, 2560, 3840}) {
        const int divisor = std::gcd(width, 3840);
        camera->setIspScale(width / divisor, 3840 / divisor);
        require(camera->getIspWidth() == width && camera->getIspHeight() == width * 9 / 16,
                "SDK ISP scaling changed requested resolution or aspect ratio");
    }
    std::cout << "PASS: 7 C1 control encoding/bounds regressions; no device opened\n";
    std::cout << "PASS: SDK ISP sizes 360p, 720p, 1080p, 1440p, 2160p; no device opened\n";
}
