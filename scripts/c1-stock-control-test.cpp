// Explicit diagnostic for the production standard-UVC control channel.
// Default is read-only. --test-wb restores captured temperature and auto mode.
#include "StockC1Control.h"
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
int main(int argc, char **argv) {
    try {
        if(argc != 3 && argc != 5) throw std::runtime_error("Usage: c1-stock-control-test --serial EXACT [--test-wb KELVIN]");
        if(std::string(argv[1]) != "--serial" || (argc == 5 && std::string(argv[3]) != "--test-wb")) throw std::runtime_error("Unknown arguments");
        char error[512]{}; StockC1FocusState focus{};
        std::unique_ptr<StockC1Control, decltype(&stock_c1_close)> control(stock_c1_open(argv[2], &focus, error, sizeof error), stock_c1_close);
        if(!control) throw std::runtime_error(error);
        std::cout << "focus=" << focus.position << " auto=" << focus.automatic << '\n';
        StockC1WhiteBalanceState before{}, state{};
        if(!stock_c1_read_white_balance(control.get(), &before, error, sizeof error)) throw std::runtime_error(error);
        std::cout << "white_balance=" << before.temperature << " min=" << before.minimum << " max=" << before.maximum << " auto=" << before.automatic << " temperature_info=" << before.temperature_info << " auto_info=" << before.automatic_info << '\n';
        if(argc == 3) return 0;
        const int target = std::stoi(argv[4]);
        bool okay = stock_c1_set_white_balance(control.get(), target, &state, error, sizeof error);
        const std::string operationError = okay ? "" : error;
        if(okay) std::cout << "white_balance readback=" << state.temperature << " auto=" << state.automatic << '\n';
        // Both restoration steps run even when the tested operation fails.
        bool temperatureRestored = stock_c1_set_white_balance(control.get(), before.temperature, &state, error, sizeof error);
        if(temperatureRestored) std::cout << "white_balance restored=" << state.temperature << " expected=" << before.temperature << '\n';
        else std::cerr << "Temperature restore failed: " << error << '\n';
        bool autoRestored = stock_c1_set_auto_white_balance(control.get(), before.automatic, &state, error, sizeof error);
        if(autoRestored) std::cout << "white_balance_auto restored=" << state.automatic << " expected=" << before.automatic << '\n';
        else std::cerr << "Automatic-mode restore failed: " << error << '\n';
        if(!okay) throw std::runtime_error(operationError);
        if(!temperatureRestored || !autoRestored) throw std::runtime_error("White balance restoration was not confirmed");
        return 0;
    } catch(const std::exception &e) { std::cerr << e.what() << '\n'; return 1; }
}
